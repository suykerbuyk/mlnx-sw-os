#!/bin/bash
# S5 + S6 -- growth configuration, cloud residue strip, generalize and export.
#
# HOST-SIDE entry point. It drives the guest over plain ssh exactly as
# scripts/vm.sh does, and finishes with a host-side `qemu-img convert -O raw`
# once the guest is down. That split is the reason this is one script and not
# two: the export operates on $WORK/work.qcow2, which only exists on the host.
#
# Usage: stage-generalize.sh [prepare|strip|verify|finish|export|all]
#
#   prepare  install the growth configuration and the first-boot identity unit
#   strip    purge cloud-init, netplan and growroot; regenerate initramfs+GRUB
#   verify   assert the resulting state, guest still reachable
#   finish   🔴 DESTRUCTIVE -- generalize and power off in ONE ssh call
#   export   qemu-img convert -O raw, guest must already be down
#   all      the five above, in order (default)
#
# ---------------------------------------------------------------- what owns what
#
# | Concern                | Owner                                              |
# |------------------------|----------------------------------------------------|
# | root PARTITION growth  | systemd-repart  (/etc/repart.d/50-root.conf)       |
# | root FILESYSTEM growth | x-systemd.growfs on the root fstab entry           |
# | network configuration  | the shipped /etc/systemd/network units, exclusively |
# | hostname / identity    | switch-firstboot.service (DMI serial, AD-5)        |
# | swap                   | switch-swapfile.service -- a 2 GiB FILE, created    |
# |                        | at first boot AFTER both halves of growth (AD-4)    |
# | bootloader             | grub-cloud-amd64, ALREADY in the base -- asserted,  |
# |                        | never installed                                     |
#
# cloud-init, netplan and cloud-initramfs-growroot are all PURGED. cloud-init
# was never the grower (it logs NOCHANGE); growroot did the partition half and
# it is Debian-only -- it hooks initramfs-tools, which Arch does not have at
# all. systemd-repart and x-systemd.growfs are systemd-native on both distros,
# which is the founding constraint: no distro-specific bootstrapper dependency
# in this layer.
#
# ---------------------------------------------------------------- ordering
#
# This stage runs LAST, and it runs alone:
#
#   1. vm.sh up + provision                    (build environment)
#   2. stage-runtime-contract.sh               🔴 MUST precede this stage: it
#      installs the systemd-networkd units -- the replacement for the netplan
#      configuration `strip` deletes -- the operator user model, and the
#      systemd-repart PACKAGE (a separate package on Debian, not in the base;
#      inside systemd on Arch). This stage owns only its CONFIGURATION.
#   3. stage-grub-fallback.sh                  🔴 MUST precede `strip`: its
#      /etc/default/grub.d/25_switch-boot-policy.cfg has to exist before the
#      GRUB regeneration below, or the policy is in the input and absent from
#      the output.
#   4. THIS SCRIPT.
#
# Nothing may run in the guest after `finish` -- it removes the builder user,
# and vm.sh's ssh_vm (vm.sh:95) connects as that user, so `vm.sh ssh|down|
# provision|probe|audit` all die with it. That is also why poweroff is issued
# inside the same ssh call that removes the user: after that call there is no
# way back in to power the guest down gracefully.
#
# 🔴 There is NO reboot after `strip`. The purge removes the guest's only
# netplan-rendered network configuration, and the shipped switch units match on
# switch hardware, not on the build VM's virtual NIC -- the running link
# survives only because networkd already configured it. A reboot here loses the
# guest.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$HERE")"
ASSETS="$ROOT/assets"

# ---------------------------------------------------------------- config
# MIRRORED from scripts/vm.sh, deliberately, with identical environment
# variable names so an override applies to both. vm.sh cannot be sourced: its
# dispatch `case` runs at the bottom of the file and would print usage and exit.
# Editing vm.sh is forbidden for this member; the orchestrator adds its one
# dispatch line at integration.
DISTRO="${DISTRO:-debian}"
WORK="${WORK:-/var/tmp/mlnx-sw-os-vm}"
SSH_PORT="${SSH_PORT:-2222}"
BUILD_USER="${BUILD_USER:-builder}"

IMG="$WORK/work.qcow2"
KEY="$WORK/id_ed25519"
PIDFILE="$WORK/qemu.pid"
SERIAL="$WORK/serial.log"

# How long to wait for the guest to finish powering itself off. Reaching this
# is a FAILURE of the export, never a fallback: killing qemu ships a dirty
# filesystem.
POWEROFF_TIMEOUT="${POWEROFF_TIMEOUT:-120}"

# auto   -- use the shipped systemd-repart.service if the guest proves it will
#           run, otherwise install assets/etc.systemd.system/switch-growroot.service
# shipped/custom -- force one path, for a deliberate experiment
GROW_UNIT="${GROW_UNIT:-auto}"

# 1 (default): a failed precondition aborts. 0: preconditions WARN instead, and
# the exported artifact is renamed NON-REPRESENTATIVE so a weakened run can
# never be mistaken for a shippable one.
PREFLIGHT_STRICT="${PREFLIGHT_STRICT:-1}"

SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-o ConnectTimeout=5
	-i "$KEY"
	-p "$SSH_PORT"
)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null || die "missing build-host dependency: $1"; }

# Liveness is the PIDFILE and nothing else. A process-table pattern match would
# also match this very script's own command line and has already produced a
# false "still running" in this project.
vm_running() {
	[ -r "$PIDFILE" ] || return 1
	kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

ssh_vm() { ssh "${SSH_OPTS[@]}" "$BUILD_USER@127.0.0.1" "$@"; }

require_guest() {
	vm_running || die "guest is not running -- run: scripts/vm.sh up"
	ssh_vm true 2>/dev/null || die "guest is running but ssh as '$BUILD_USER' fails -- \
has this stage's 'finish' phase already run? It is not repeatable against the same guest."
}

# The distro seam. The growth mechanism is distro-neutral by design; the PURGE
# list is not -- it is apt and Debian package names. Adding Arch means writing
# the arch) arm, not rewriting the stage.
require_debian() {
	case "$DISTRO" in
	debian) ;;
	*) die "DISTRO=$DISTRO: the package strip is Debian-only so far. The growth \
design (systemd-repart + x-systemd.growfs) is distro-neutral; this arm of the \
seam is what still needs writing." ;;
	esac
}

# Copy an asset into the guest, as root, without needing scp or an agent --
# same pipe-over-ssh shape vm.sh uses for the audit payload (vm.sh:362).
push_file() { # <local asset> <guest path> <mode>
	local src="$1" dst="$2" mode="$3"
	[ -r "$src" ] || die "missing asset: $src"
	ssh_vm "sudo mkdir -p '$(dirname "$dst")' && sudo tee '$dst' >/dev/null && sudo chmod $mode '$dst'" \
		< "$src" || die "failed to install $dst"
	info "installed $dst (from ${src#"$ROOT"/})"
}

# ---------------------------------------------------------------- preflight
# Everything this stage depends on but does not own. Collect ALL failures and
# report them together: a preflight that dies on the first one costs a whole
# VM slot per missing precondition, and this stage gets exactly one.
do_preflight() {
	require_guest
	require_debian
	info "preflight: preconditions owned by other stages"

	local out rc=0
	out=$(ssh_vm 'sudo sh -s' <<-'GUEST'
	set -u
	fail() { echo "MISSING: $*"; }

	# stage-runtime-contract: the replacement network authority. Without it,
	# `strip` deletes the only network configuration in the image.
	set -- /etc/systemd/network/*.network
	[ -e "$1" ] || fail "/etc/systemd/network/*.network -- the netplan replacement (stage-runtime-contract)"
	systemctl is-enabled systemd-networkd.service >/dev/null 2>&1 \
		|| fail "systemd-networkd is not enabled (stage-runtime-contract)"

	# stage-runtime-contract owns the systemd-repart MANIFEST; this stage
	# owns only its configuration. It is a SEPARATE package on Debian.
	command -v systemd-repart >/dev/null 2>&1 \
		|| fail "systemd-repart binary -- 'apt-get install systemd-repart' belongs to stage-runtime-contract"

	# R-G: the boot-policy drop-in must exist BEFORE this stage regenerates
	# grub.cfg, or the policy is in the input and absent from the output.
	[ -f /etc/default/grub.d/25_switch-boot-policy.cfg ] \
		|| fail "/etc/default/grub.d/25_switch-boot-policy.cfg (stage-grub-fallback)"
	[ -f /etc/default/grub.d/20_switch-cmdline.cfg ] \
		|| fail "/etc/default/grub.d/20_switch-cmdline.cfg (stage-runtime-contract)"

	# The bootloader is asserted, never installed.
	dpkg-query -W -f='${db:Status-Status}' grub-cloud-amd64 2>/dev/null | grep -q '^installed$' \
		|| fail "grub-cloud-amd64 is not installed -- it is supposed to be in the base"
	[ -e /etc/grub.d/enable_cloud ] \
		|| fail "/etc/grub.d/enable_cloud -- without it grub-cloud's postinst is a no-op"

	# An image nobody can log into is a failure mode this project has
	# already written down. The builder user is about to be deleted, so
	# something else must be able to log in.
	awk -F: '$3>=1000 && $3<65534 && $1!="builder" && $7 !~ /(nologin|false)$/ {n++} END{exit !n}' /etc/passwd \
		|| fail "no non-system login account other than 'builder' -- the artifact would ship with no way in (stage-runtime-contract)"

	# AD-4's binding precondition, re-checked here because everything below
	# is pointless if it does not hold. BY START SECTOR, not by number.
	R=$(findmnt -no SOURCE / | sed 's|.*/||')
	D=$(lsblk -no PKNAME "/dev/$R" 2>/dev/null | head -1)
	L=$(partx -o NR,START -g "/dev/$D" | sort -k2 -n | tail -1 | awk '{print $1}')
	RN=$(printf '%s' "$R" | sed 's|.*[^0-9]||')
	[ "$RN" = "$L" ] || fail "root is partition $RN of /dev/$D but partition $L starts last -- AD-4 VIOLATED, growth would silently decline"
	echo "PREFLIGHT-DONE root=/dev/$R disk=/dev/$D"
	GUEST
	) || rc=$?
	printf '%s\n' "$out"
	[ "$rc" -eq 0 ] || die "preflight payload failed to run (ssh rc=$rc)"

	if printf '%s' "$out" | grep -q '^MISSING:'; then
		if [ "$PREFLIGHT_STRICT" = "1" ]; then
			die "preconditions are not met -- see MISSING above. Run the missing \
stage first, or re-run with PREFLIGHT_STRICT=0 for a deliberately weakened, \
NON-REPRESENTATIVE experiment."
		fi
		warn "PREFLIGHT_STRICT=0 -- continuing with unmet preconditions. This run is NON-REPRESENTATIVE."
	else
		info "preflight: all preconditions met"
	fi
}

# ---------------------------------------------------------------- prepare
do_prepare() {
	require_guest
	info "prepare: growth configuration and the first-boot identity unit"

	push_file "$ASSETS/etc.repart.d/50-root.conf"                  /etc/repart.d/50-root.conf         0644
	push_file "$ASSETS/usr.local.sbin/switch-firstboot"            /usr/local/sbin/switch-firstboot   0755
	push_file "$ASSETS/etc.systemd.system/switch-firstboot.service" /etc/systemd/system/switch-firstboot.service 0644
	# Swap is NOT identity, so it is a second unit rather than a branch of the
	# first one: switch-firstboot.service is identity-only by ruling, and it
	# has no business waiting on the growth chain.
	push_file "$ASSETS/usr.local.sbin/switch-swapfile"             /usr/local/sbin/switch-swapfile    0755
	push_file "$ASSETS/etc.systemd.system/switch-swapfile.service"  /etc/systemd/system/switch-swapfile.service 0644

	# fstab: the FILESYSTEM half of growth. Rewrites only the options field of
	# the row whose mountpoint is /, and only when the option is absent.
	info "ensuring x-systemd.growfs on the root fstab entry"
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	F=/etc/fstab
	if awk 'NF>=6 && $2=="/" && $4 ~ /(^|,)x-systemd\.growfs(,|$)/ {found=1} END{exit !found}' "$F"; then
		echo "x-systemd.growfs: already present"
	else
		awk 'BEGIN{OFS="\t"}
		     /^[[:space:]]*#/ {print; next}
		     NF>=6 && $2=="/" {$4=$4",x-systemd.growfs"; print; next}
		     {print}' "$F" > /tmp/fstab.new
		# Refuse to install a table that lost the root row or a field.
		awk 'NF>=6 && $2=="/" {n++} END{exit !(n==1)}' /tmp/fstab.new \
			|| { echo "FAIL: rewritten fstab has no single root row" >&2; exit 1; }
		cp -a "$F" "$F.pre-generalize"
		cat /tmp/fstab.new > "$F"
		rm -f /tmp/fstab.new
		echo "x-systemd.growfs: added"
	fi
	grep -E '^[^#].*[[:space:]]/[[:space:]]' "$F" || true
	# Generators must re-run before systemd-growfs-root.service can be
	# inspected -- it is generated FROM this fstab entry.
	systemctl daemon-reload
	GUEST

	# resume: still binding. A stale RESUME= pointing at a swap device that no
	# longer exists cost a hand-fixed initramfs on the 2410. This layout has no
	# swap partition at all.
	# ⚠ initramfs-tools is DEBIAN-ONLY; guarded so it is a no-op elsewhere and
	# never becomes a dependency of the growth path.
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	[ -d /etc/initramfs-tools/conf.d ] || { echo "no initramfs-tools -- skipping RESUME"; exit 0; }
	printf 'RESUME=none\n' > /etc/initramfs-tools/conf.d/resume
	echo "RESUME=none written"
	GUEST

	decide_grow_unit
	info "enabling the first-boot units (identity, swapfile)"
	ssh_vm 'sudo sh -c "systemctl daemon-reload && systemctl enable switch-firstboot.service switch-swapfile.service"'

	# The swapfile's only real precondition, asserted here rather than
	# discovered at first boot on a switch: a plain swapfile is INVALID on
	# btrfs (copy-on-write, no stable extents -- swapon refuses it unless the
	# file was created with chattr +C). The base is expected to be ext4; the
	# guest is what proves it.
	info "root filesystem type (swapfile precondition)"
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	T=$(findmnt -no FSTYPE /)
	echo "root filesystem: $T"
	case "$T" in
	ext2|ext3|ext4|xfs) echo "swapfile supported on $T" ;;
	btrfs) echo "FAIL: root is btrfs -- switch-swapfile refuses to create a plain swapfile there" >&2; exit 1 ;;
	*) echo "FAIL: unrecognised root filesystem '$T'" >&2; exit 1 ;;
	esac
	GUEST
}

# Open question, ruled by evidence rather than assumption: is a custom unit
# needed at all, or does the shipped systemd-repart.service suffice?
#
# Offline evidence (systemd 261 on the build host, /usr/lib/systemd/system):
#   systemd-growfs@.service      After=systemd-repart.service %i.mount
#   systemd-growfs-root.service  After=systemd-repart.service systemd-remount-fs.service
#   sysinit.target.wants/systemd-repart.service   (static wants symlink)
# So upstream already orders the filesystem grow after the partition grow, on
# the same boot, and already queues the partition grow at boot. The custom
# unit's whole purpose -- Before=systemd-growfs-root.service -- is redundant if
# Debian's systemd 257 ships the same edges. That is what this probe checks,
# IN the guest, instead of assuming either way.
decide_grow_unit() {
	local verdict
	verdict=$(ssh_vm 'sudo sh -s' <<-'GUEST'
	set -u
	ok=1
	command -v systemd-repart >/dev/null 2>&1 || { echo "no systemd-repart binary"; ok=0; }
	state=$(systemctl is-enabled systemd-repart.service 2>/dev/null || echo unknown)
	echo "systemd-repart.service is-enabled: $state"
	[ "$state" = masked ] && { echo "shipped unit is MASKED"; ok=0; }
	if systemctl show -p WantedBy --value systemd-repart.service 2>/dev/null | grep -q 'sysinit.target'; then
		echo "shipped unit is wanted by sysinit.target"
	else
		echo "shipped unit is NOT wanted by sysinit.target"; ok=0
	fi
	if systemctl cat systemd-growfs-root.service 2>/dev/null | grep -q 'After=.*systemd-repart\.service'; then
		echo "systemd-growfs-root.service orders itself After=systemd-repart.service"
	else
		echo "systemd-growfs-root.service does NOT order after systemd-repart.service"; ok=0
	fi
	[ "$ok" = 1 ] && echo "VERDICT=shipped" || echo "VERDICT=custom"
	GUEST
	)
	printf '%s\n' "$verdict"

	local chosen
	case "$GROW_UNIT" in
	auto)    chosen=$(printf '%s' "$verdict" | sed -n 's/^VERDICT=//p') ;;
	shipped|custom) chosen="$GROW_UNIT"; info "GROW_UNIT=$GROW_UNIT forces the '$chosen' path" ;;
	*)       die "GROW_UNIT must be auto, shipped or custom (got '$GROW_UNIT')" ;;
	esac
	[ -n "$chosen" ] || die "could not read a verdict from the grow-unit probe"

	if [ "$chosen" = shipped ]; then
		info "growth unit: SHIPPED systemd-repart.service (no custom unit installed)"
		ssh_vm 'sudo sh -s' <<-'GUEST'
		set -eu
		# Idempotency: a previous run may have installed the fallback.
		if [ -e /etc/systemd/system/switch-growroot.service ]; then
			systemctl disable switch-growroot.service 2>/dev/null || true
			rm -f /etc/systemd/system/switch-growroot.service
			systemctl daemon-reload
			echo "removed a stale switch-growroot.service"
		fi
		GUEST
	else
		warn "growth unit: CUSTOM switch-growroot.service -- the shipped unit did not \
qualify. This path is UNVERIFIED: boot the guest once and assert the journal has no \
'Found ordering cycle' before anything built this way is shipped."
		push_file "$ASSETS/etc.systemd.system/switch-growroot.service" \
			/etc/systemd/system/switch-growroot.service 0644
		ssh_vm 'sudo sh -c "systemctl daemon-reload && systemctl enable switch-growroot.service"'
	fi
}

# ---------------------------------------------------------------- strip
do_strip() {
	require_guest
	require_debian
	info "strip: purging cloud-init, netplan and growroot"

	# 🔴 LAST apt operation of the build. Nothing below needs the network, and
	# nothing after this may reboot.
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	export DEBIAN_FRONTEND=noninteractive

	# Insurance, taken BEFORE the purge and removed again during generalize.
	# The builder user's NOPASSWD rule lives in a file cloud-init wrote at
	# runtime, and this payload is the last one that is guaranteed to be
	# running as root. If the purge were to take that file with it, `verify`
	# and `finish` would both fail with no way to recover the guest -- and
	# `finish` is the only graceful poweroff path.
	if [ -f /etc/sudoers.d/90-cloud-init-users ] && [ ! -f /etc/sudoers.d/00-build-generalize ]; then
		cp /etc/sudoers.d/90-cloud-init-users /etc/sudoers.d/00-build-generalize
		chmod 0440 /etc/sudoers.d/00-build-generalize
		visudo -c -f /etc/sudoers.d/00-build-generalize >/dev/null \
			|| { rm -f /etc/sudoers.d/00-build-generalize; echo "WARNING: sudoers copy did not validate; not installed"; }
	fi

	# netplan.io is only the CLI. Purging it alone leaves netplan-generator
	# installed with /usr/lib/systemd/system-generators/netplan still active
	# and still rendering into /run/systemd/network -- .link files as well as
	# .network, so an assertion that inspects only .network passes with live
	# configuration in place. All four netplan packages, or none.
	CANDIDATES="cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot"
	TODO=""
	for p in $CANDIDATES; do
		case "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || echo none)" in
		installed|config-files) TODO="$TODO $p" ;;
		esac
	done
	if [ -n "$TODO" ]; then
		echo "purging:$TODO"
		apt-get purge -y -qq $TODO
	else
		echo "nothing to purge -- already stripped"
	fi

	rm -rf /etc/netplan /etc/cloud /var/lib/cloud
	echo "removed /etc/netplan /etc/cloud /var/lib/cloud"
	GUEST

	# Purging cloud-initramfs-growroot triggers an initramfs regeneration that
	# drops scripts/local-bottom/growroot -- verify the trigger fired, do not
	# assume it. The RESUME=none written in `prepare` needs the same rebuild.
	info "regenerating the initramfs and verifying the growroot hook is gone"
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	command -v update-initramfs >/dev/null 2>&1 || { echo "no update-initramfs -- skipping"; exit 0; }
	update-initramfs -u -k all
	I="/boot/initrd.img-$(uname -r)"
	[ -r "$I" ] || { echo "FAIL: no $I" >&2; exit 1; }
	if lsinitramfs "$I" | grep -i growroot; then
		echo "FAIL: the growroot hook is STILL in $I" >&2
		exit 1
	fi
	echo "growroot hook absent from $I"
	GUEST

	# GRUB LAST, so grub.cfg reflects the final drop-in set (R-G) and the final
	# initramfs. Installs nothing: grub-cloud-amd64's postinst re-runs
	# grub-install for BOTH targets with --no-nvram --force-extra-removable and
	# then update-grub. A hand-rolled pair would lose exactly those flags.
	info "regenerating GRUB via grub-cloud-amd64 (installs no bootloader)"
	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	export DEBIAN_FRONTEND=noninteractive
	dpkg-reconfigure -f noninteractive grub-cloud-amd64
	GUEST
}

# ---------------------------------------------------------------- verify
# Runs with the guest still reachable, because after `finish` there is no way
# back in. Everything asserted here is state that SHIPS.
do_verify() {
	require_guest
	info "verify: asserting the state that ships"

	local out rc=0
	out=$(ssh_vm 'sudo sh -s' <<-'GUEST'
	set -u
	fail=0
	bad() { echo "  FAIL $*"; fail=$((fail+1)); }
	ok()  { echo "  ok   $*"; }
	note(){ echo "  NOTE $*"; }

	echo "== cloud residue =="
	for p in cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot; do
		s=$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || echo none)
		case "$s" in
		none|not-installed) ok "$p: $s" ;;
		*) bad "$p is still '$s'" ;;
		esac
	done
	[ -e /usr/lib/systemd/system-generators/netplan ] \
		&& bad "the netplan systemd generator is still present" \
		|| ok "netplan generator gone"
	[ -e /etc/netplan ] && bad "/etc/netplan still exists" || ok "/etc/netplan gone"
	[ -e /etc/cloud ]   && bad "/etc/cloud still exists"   || ok "/etc/cloud gone"

	echo "== network authority =="
	set -- /etc/systemd/network/*.network
	[ -e "$1" ] && ok "/etc/systemd/network: $(ls /etc/systemd/network | wc -l) file(s)" \
	            || bad "/etc/systemd/network has no .network unit -- the image would ship with NO network configuration"
	# /run is tmpfs: it never ships. Leftovers here are stale state from the
	# pre-purge boot, not artifact content -- so they are reported, and they
	# only fail the run if the generator that produces them still exists.
	stale=$(ls -A /run/systemd/network 2>/dev/null || true)
	if [ -n "$stale" ]; then
		note "/run/systemd/network is not empty (tmpfs, does not ship):"
		ls -l /run/systemd/network | sed 's/^/       /'
		[ -e /usr/lib/systemd/system-generators/netplan ] && bad "and the generator is still installed"
	else
		ok "/run/systemd/network is empty"
	fi

	echo "== growth =="
	command -v systemd-repart >/dev/null 2>&1 && ok "systemd-repart: $(command -v systemd-repart)" \
		|| bad "systemd-repart is not installed"
	[ -f /etc/repart.d/50-root.conf ] && ok "/etc/repart.d/50-root.conf present" \
		|| bad "/etc/repart.d/50-root.conf missing"
	grep -q '^Type=root$' /etc/repart.d/50-root.conf 2>/dev/null && ok "repart config selects Type=root" \
		|| bad "repart config does not select Type=root"
	awk 'NF>=6 && $2=="/" && $4 ~ /(^|,)x-systemd\.growfs(,|$)/ {f=1} END{exit !f}' /etc/fstab \
		&& ok "x-systemd.growfs on the root fstab entry" \
		|| bad "root fstab entry has no x-systemd.growfs -- the partition would grow and the filesystem would not"
	if [ -e /etc/systemd/system/switch-growroot.service ]; then
		note "growth unit: CUSTOM switch-growroot.service (UNVERIFIED path)"
		systemctl is-enabled switch-growroot.service || bad "switch-growroot.service is not enabled"
	else
		note "growth unit: shipped systemd-repart.service"
		systemctl show -p WantedBy --value systemd-repart.service | grep -q sysinit.target \
			&& ok "systemd-repart.service is wanted by sysinit.target" \
			|| bad "systemd-repart.service is not wanted by sysinit.target -- it would never run"
		systemctl cat systemd-growfs-root.service 2>/dev/null | grep -q 'After=.*systemd-repart\.service' \
			&& ok "systemd-growfs-root.service orders after systemd-repart.service" \
			|| bad "systemd-growfs-root.service does not order after systemd-repart.service -- the filesystem would grow one boot late"
	fi
	# A dry run proves the configuration parses and the disk is understood.
	# systemd-repart exits 0 on no-change, so this is a clean assertion --
	# there is no exit-1-means-two-things ambiguity here; that was growpart.
	echo "  -- systemd-repart --dry-run=yes --"
	if systemd-repart --dry-run=yes > /tmp/repart.dryrun 2>&1; then
		sed 's/^/       /' /tmp/repart.dryrun
		ok "systemd-repart parses the configuration and understands the disk"
	else
		sed 's/^/       /' /tmp/repart.dryrun
		bad "systemd-repart --dry-run=yes exited non-zero"
	fi
	rm -f /tmp/repart.dryrun

	echo "== identity =="
	[ -x /usr/local/sbin/switch-firstboot ] && ok "/usr/local/sbin/switch-firstboot present" \
		|| bad "/usr/local/sbin/switch-firstboot missing"
	systemctl is-enabled switch-firstboot.service >/dev/null 2>&1 \
		&& ok "switch-firstboot.service enabled" || bad "switch-firstboot.service is not enabled"

	echo "== swap (AD-4: a FILE, never a partition) =="
	[ -x /usr/local/sbin/switch-swapfile ] && ok "/usr/local/sbin/switch-swapfile present" \
		|| bad "/usr/local/sbin/switch-swapfile missing"
	systemctl is-enabled switch-swapfile.service >/dev/null 2>&1 \
		&& ok "switch-swapfile.service enabled" || bad "switch-swapfile.service is not enabled"
	T=$(findmnt -no FSTYPE /)
	case "$T" in
	ext2|ext3|ext4|xfs) ok "root filesystem is $T -- a plain swapfile is valid" ;;
	btrfs) bad "root is btrfs -- a plain swapfile is invalid there and switch-swapfile refuses" ;;
	*) bad "unrecognised root filesystem '$T'" ;;
	esac
	# A swap PARTITION is the layout AD-4 exists to eliminate: it sits after
	# root and makes root non-growable in place.
	lsblk -no FSTYPE 2>/dev/null | grep -qx swap \
		&& bad "a swap PARTITION exists -- AD-4 forbids it" || ok "no swap partition"
	# The unit ships; the 2 GiB file must NOT. `finish` removes it, so this is
	# a NOTE here and an offline-tier assertion on the finished artifact.
	[ -e /swapfile ] && note "/swapfile exists in the guest (a build reboot created it); finish removes it" \
		|| ok "no /swapfile baked into the image"
	awk 'NF>=6 && $3=="swap" {n++} END{exit !n}' /etc/fstab \
		&& note "an fstab swap entry exists; finish strips it" \
		|| ok "no swap entry in /etc/fstab"

	echo "== initramfs =="
	I="/boot/initrd.img-$(uname -r)"
	if [ -r "$I" ]; then
		lsinitramfs "$I" | grep -qi growroot && bad "growroot hook still in $I" || ok "no growroot hook in $I"
	fi
	[ -f /etc/initramfs-tools/conf.d/resume ] && ok "resume: $(cat /etc/initramfs-tools/conf.d/resume)" \
		|| note "no /etc/initramfs-tools/conf.d/resume (not Debian?)"

	echo "== bootloader (asserted, never installed) =="
	dpkg-query -W -f='${db:Status-Status}\n' grub-cloud-amd64 2>/dev/null | grep -q '^installed$' \
		&& ok "grub-cloud-amd64 installed" || bad "grub-cloud-amd64 is NOT installed"
	[ -e /boot/efi/EFI/BOOT/BOOTX64.EFI ] && ok "ESP removable path populated" \
		|| bad "/boot/efi/EFI/BOOT/BOOTX64.EFI missing -- a freshly imaged UEFI switch would not boot"
	echo "  -- /etc/default/grub.d --"
	ls -1 /etc/default/grub.d/ 2>/dev/null | sed 's/^/       /'
	# 10_cloud.cfg RULING: KEPT. GRUB_DISABLE_LINUX_UUID=true makes grub emit
	# root= by PARTUUID. Neither systemd-repart (which extends the partition
	# in place, preserving its GPT UUID) nor x-systemd.growfs (which never
	# touches the filesystem UUID) changes either identifier, so both
	# spellings are stable across growth -- but PARTUUID is also independent
	# of the device NAME, and this artifact moves from /dev/vda in the build
	# VM to /dev/sda or /dev/nvme0n1 on a switch. Keeping it costs nothing and
	# changes nothing about the base's proven boot path. What is NOT tolerable
	# is inheriting it unexamined, so the inheritance is converted into an
	# assertion: the generated grub.cfg must name the root by PARTUUID, and
	# must never name it by device path.
	echo "  -- root= as generated --"
	grep -ho 'root=[^ ]*' /boot/grub/grub.cfg 2>/dev/null | sort -u | sed 's/^/       /'
	if grep -q 'root=PARTUUID=' /boot/grub/grub.cfg 2>/dev/null; then
		ok "grub.cfg names root by PARTUUID (10_cloud.cfg kept, deliberately)"
	elif grep -q 'root=UUID=' /boot/grub/grub.cfg 2>/dev/null; then
		note "grub.cfg names root by filesystem UUID -- also stable across growth, but 10_cloud.cfg is then not doing what it claims"
	else
		bad "grub.cfg names root by DEVICE PATH -- the artifact would not boot once dd'd to a disk with a different device name. DELETE /etc/default/grub.d/10_cloud.cfg"
	fi

	echo "== not ours, must survive =="
	# stage-grub-fallback owns this path's format, writer and creation. This
	# stage's only obligation is not to delete it.
	[ -d /var/lib/mlxsw-fallback ] && ok "/var/lib/mlxsw-fallback present" \
		|| note "/var/lib/mlxsw-fallback absent (stage-grub-fallback creates it; not this stage's job)"

	echo "== units =="
	systemctl --failed --no-legend | sed 's/^/       /'
	[ "$(systemctl --failed --no-legend | wc -l)" -eq 0 ] && ok "0 failed units" || bad "failed units present"

	echo
	echo "VERIFY-FAILURES=$fail"
	GUEST
	) || rc=$?
	printf '%s\n' "$out"
	[ "$rc" -eq 0 ] || die "verify payload failed to run (ssh rc=$rc)"

	local n
	n=$(printf '%s' "$out" | sed -n 's/^VERIFY-FAILURES=//p')
	[ -n "$n" ] || die "verify produced no verdict"
	if [ "$n" != "0" ]; then
		[ "$PREFLIGHT_STRICT" = "1" ] && die "$n verification failure(s) -- fix them \
BEFORE 'finish', which ends all guest access"
		warn "$n verification failure(s), tolerated only because PREFLIGHT_STRICT=0. \
This run is NON-REPRESENTATIVE and its artifact is not shippable."
	else
		info "verify: clean"
	fi
}

# ---------------------------------------------------------------- finish
# 🔴 ONE ssh invocation, and it is the last one. Generalization removes the
# builder user, and vm.sh's ssh_vm connects as that user -- so a design that
# generalizes first and powers off second cannot reconnect to issue the
# poweroff, times out, and gets a SIGTERM'd qemu: a hard kill that ships a
# dirty filesystem. Both halves therefore travel in the same payload, with a
# sentinel printed between them so a generalize failure is distinguishable from
# the connection dying on poweroff (which is normal and expected).
do_finish() {
	require_guest
	info "finish: generalize and power off -- this ends all access to the guest"

	local out rc=0
	out=$(ssh_vm 'sudo sh -s' 2>&1 <<-'GUEST'
	set -eu
	# Our own shell's cwd is /home/builder, which is about to be removed.
	cd /

	# --- identity ------------------------------------------------------
	# TRUNCATED, not deleted: machine-id(5) makes an empty file the documented
	# "not yet provisioned" state, and it is what makes ConditionFirstBoot=yes
	# fire for switch-firstboot.service on the artifact's first boot.
	: > /etc/machine-id
	rm -f /var/lib/dbus/machine-id
	rm -f /etc/ssh/ssh_host_*
	# Regenerated per machine by switch-firstboot; a fleet sharing one of
	# these is a fleet sharing an identity.
	rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
	rm -f /etc/hostname
	if [ -f /etc/hosts ]; then
		grep -v '^127\.0\.1\.1[[:space:]]' /etc/hosts > /tmp/hosts.new || true
		cat /tmp/hosts.new > /etc/hosts; rm -f /tmp/hosts.new
	fi

	# --- cloud-init leftovers that a package purge does not own ---------
	# Runtime-generated, so they are not conffiles and survive `apt purge`.
	rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
	rm -f /etc/sudoers.d/90-cloud-init-users
	# The build-time sudo insurance `strip` took out. It grants the builder
	# user NOPASSWD root; it must not reach a switch.
	rm -f /etc/sudoers.d/00-build-generalize
	rm -rf /var/lib/cloud

	# --- swap: the UNIT ships, the FILE does not ------------------------
	# switch-swapfile.service is enabled and creates /swapfile at first boot,
	# after growth. If a reboot during the build fired it, undo that here: a
	# 2 GiB file inflates every build and every dd, and it would have been
	# allocated against the un-grown 8 GB root rather than the switch's real
	# disk. The unit's ConditionPathExists=!/swapfile then fires correctly on
	# the artifact's first boot.
	swapoff -a 2>/dev/null || true
	rm -f /swapfile /swapfile.partial
	if [ -f /etc/fstab ]; then
		awk 'NF>=6 && $3=="swap" {next} {print}' /etc/fstab > /tmp/fstab.noswap
		cat /tmp/fstab.noswap > /etc/fstab; rm -f /tmp/fstab.noswap
	fi

	# --- the build seed user -------------------------------------------
	# -f because the account is logged in right now: this very session. That
	# is fine, we are already root. -r takes /home/builder with its
	# authorized_keys, which is the throwaway key vm.sh generated.
	# Assert the OUTCOME, never the exit status: userdel returns 12 when it
	# removed the account but could not remove the home directory, and a
	# second attempt would then fail with "user does not exist" and abort a
	# generalization that had actually succeeded.
	if id builder >/dev/null 2>&1; then
		userdel -f -r builder || true
		rm -rf /home/builder
		if id builder >/dev/null 2>&1; then
			echo "FAIL: the builder user still exists after userdel" >&2
			exit 1
		fi
	fi
	[ -e /home/builder ] && { echo "FAIL: /home/builder survives" >&2; exit 1; } || true

	# --- logs and caches -------------------------------------------------
	# 🔴 Targeted removals only. /var/lib/mlxsw-fallback/ belongs to
	# stage-grub-fallback and must survive generalization untouched.
	journalctl --rotate >/dev/null 2>&1 || true
	journalctl --vacuum-time=1s >/dev/null 2>&1 || true
	rm -rf /var/log/journal/* /var/log/installer
	find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true
	find /var/log -type f -name '*.log' -exec truncate -s0 {} + 2>/dev/null || true
	: > /var/log/wtmp 2>/dev/null || true
	: > /var/log/btmp 2>/dev/null || true
	: > /var/log/lastlog 2>/dev/null || true
	rm -f /root/.bash_history /root/.ssh/known_hosts
	rm -f /home/*/.bash_history 2>/dev/null || true
	# Build-time only: `prepare` keeps a pre-edit copy of fstab for debugging.
	# It must not ship -- two fstabs in an image is a second authority.
	rm -f /etc/fstab.pre-generalize
	apt-get clean
	rm -rf /var/lib/apt/lists/*
	rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

	[ -d /var/lib/mlxsw-fallback ] && echo "preserved: /var/lib/mlxsw-fallback" || true

	sync
	echo "__GENERALIZE_OK__"
	# The connection dies here. systemctl queues the job and returns; the ssh
	# exit status after this point is not meaningful, which is what the
	# sentinel above is for.
	systemctl poweroff
	GUEST
	) || rc=$?
	printf '%s\n' "$out"

	printf '%s' "$out" | grep -q '__GENERALIZE_OK__' \
		|| die "generalization did not reach its sentinel (ssh rc=$rc) -- the guest was NOT generalized; do not export"
	info "generalize complete; waiting for the guest to power itself off"

	local waited=0
	while vm_running; do
		[ "$waited" -lt "$POWEROFF_TIMEOUT" ] || {
			[ -r "$SERIAL" ] && tail -20 "$SERIAL" >&2 || true
			# Deliberately NOT killing it. A forced kill here is a hard
			# power cut on a filesystem that is mid-shutdown, and the
			# artifact would ship dirty.
			die "guest still running after ${POWEROFF_TIMEOUT}s. NOT killing it: a \
forced kill ships a dirty filesystem. Investigate $SERIAL; the working image is \
$IMG and there is no longer any ssh access to the guest."
		}
		sleep 2; waited=$((waited + 2))
	done
	info "guest down after ${waited}s"
	rm -f "$PIDFILE"
}

# ---------------------------------------------------------------- export
do_export() {
	need qemu-img
	[ -f "$IMG" ] || die "no working image at $IMG"
	if vm_running; then
		die "the guest is still running (pidfile $PIDFILE) -- converting a live \
image would capture a torn filesystem. Run the 'finish' phase first."
	fi

	local stamp out
	stamp="$(date -u +%Y%m%d)"
	out="${OUT:-$WORK/mlnx-sw-os-$DISTRO-$stamp.raw}"
	[ "$PREFLIGHT_STRICT" = "1" ] || out="${out%.raw}-NON-REPRESENTATIVE.raw"

	info "converting $IMG -> $out"
	qemu-img convert -p -O raw "$IMG" "$out"

	info "checksumming"
	( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

	printf '\n'
	info "artifact:  $out"
	info "apparent:  $(du -h --apparent-size "$out" | cut -f1)   on disk: $(du -h "$out" | cut -f1)"
	info "sha256:    $(cut -d' ' -f1 "$out.sha256")"
	info "dd it with: dd if=$out of=/dev/<disk> bs=4M status=progress conv=fsync"
	[ "$PREFLIGHT_STRICT" = "1" ] || warn "this artifact was built with unmet preconditions and is NOT shippable"
}

# ---------------------------------------------------------------- dispatch
case "${1:-all}" in
preflight) do_preflight ;;
prepare)   do_preflight; do_prepare ;;
strip)     do_strip ;;
verify)    do_verify ;;
finish)    do_finish ;;
export)    do_export ;;
all)       do_preflight; do_prepare; do_strip; do_verify; do_finish; do_export ;;
*)
	sed -n '2,20p' "$0" | sed 's/^# \?//'
	printf '\nUsage: %s [prepare|strip|verify|finish|export|all]\n' "$0"
	exit 1 ;;
esac
