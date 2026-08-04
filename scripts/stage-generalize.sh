#!/bin/bash
# S5 + S6 -- growth configuration, cloud residue strip, generalize and export.
#
# HOST-SIDE entry point. It drives the guest over plain ssh exactly as
# scripts/vm.sh does, and finishes with a host-side `qemu-img convert -O raw`
# once the guest is down. That split is the reason this is one script and not
# two: the export operates on $WORK/work.qcow2, which only exists on the host.
#
# Usage: stage-generalize.sh [preflight|prepare|strip|verify|finish|export|all|selftest]
#
#   preflight assert every precondition this stage depends on but does not own
#   prepare  install the growth configuration and the first-boot identity unit
#   strip    purge cloud-init, netplan and growroot; regenerate initramfs+GRUB
#   verify   assert the resulting state, guest still reachable
#   finish   🔴 DESTRUCTIVE -- generalize and power off in ONE ssh call
#   export   qemu-img convert -O raw, guest must already be down
#   all      the five above, in order (default)
#   selftest offline proof: no VM, no root, no network -- and that claim is
#            proven by outcome, with every network-reaching binary shimmed
#
# `prepare` and `strip` both run `preflight` first. `strip` especially: it is
# the phase the ordering contract below binds, and a bare `strip` that skipped
# its preconditions would regenerate GRUB with stage-grub-fallback's boot policy
# absent from the input.
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

# 🔴 THE SHIPPED-vs-CUSTOM CHOICE IS GONE, and so is GROW_UNIT. The custom unit
# is always installed and the shipped systemd-repart.service is always masked.
#
# There used to be an `auto` probe choosing between them on four wiring facts,
# and it chose `shipped` on this guest. The wiring facts were right and the
# choice was wrong, because the disqualifying property is not wiring: on a disk
# with no free space `systemd-repart` EXITS 1, so the shipped unit fails on
# every boot of an already-grown switch. Measured 2026-08-03.
#
# The choice cannot be restored as a probe, either. Whether there is free space
# is a property of THE DISK THE ARTIFACT LANDS ON, not of the build guest -- one
# image boots on a 512 G SSD with room to grow and on the boot-test's 8 G file
# with none, and both are correct. A build-time measurement cannot answer a
# runtime question, so the tolerance lives at runtime in
# /usr/local/sbin/switch-growroot and the decision here is unconditional.
#
# A `GROW_UNIT=shipped` escape hatch was NOT kept. Config that reads as live and
# is known-broken is the shape this epic calls Critical everywhere else.

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
	# 🔴 A DELETION is an artifact too, and this one is the artifact with a
	# shipping consequence. The base image's 15_timeout.cfg sets GRUB_TIMEOUT=0,
	# which displays NO MENU AT ALL on the serial console. stage-grub-fallback
	# DELETES it rather than shadowing it from 25_. It sorts before 25_, so on a
	# correctly staged guest 25_ wins and the timeout is 5 -- but a surviving
	# 15_ is proof that stage-grub-fallback has not run, and then 25_ is not
	# there to win. Checking the file that must be GONE catches a half-applied
	# boot policy that checking only the file that must be PRESENT does not.
	[ -e /etc/default/grub.d/15_timeout.cfg ] \
		&& fail "/etc/default/grub.d/15_timeout.cfg still exists -- stage-grub-fallback DELETES it (it forces GRUB_TIMEOUT=0: no menu at all). That stage has not run."
	# The drop-in on its own proves only that a FILE exists; it could have been
	# hand-copied. This state file is written by stage-grub-fallback and by
	# nothing else, so it is what proves the STAGE ran. `finish` is already
	# required to preserve it, so asserting it here costs nothing new.
	[ -f /var/lib/mlxsw-fallback/last-known-good ] \
		|| fail "/var/lib/mlxsw-fallback/last-known-good (stage-grub-fallback) -- the boot-policy stage has not run"

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
#
# 🔴 grow_unit_verdict() WAS DELETED, along with GROW_FACT_KEYS. It was a pure,
# well-tested predicate that decided between the shipped unit and the custom one
# on four wiring facts -- and it was correct about the wiring and wrong about the
# outcome, because the disqualifying property of the shipped unit is its EXIT
# STATUS on a full disk, which no wiring fact can see. It chose `shipped` on this
# guest and the artifact got a permanently failed unit.
#
# It is deleted rather than left with one branch unreachable: a well-tested
# function nothing calls reads as live decision-making to the next person, and
# its selftest assertions would keep passing while proving nothing about the
# stage's actual behaviour.
#
# The probe below survives as DIAGNOSTICS ONLY. Its facts are printed and they
# document the guest an artifact was built on; they decide nothing. The real
# decision now lives at runtime in /usr/local/sbin/switch-growroot, which is
# where a runtime question belongs -- and it is still a pure predicate over
# text, so `selftest` still exercises it in both polarities.

decide_grow_unit() {
	local probe
	probe=$(ssh_vm 'sudo sh -s' <<-'GUEST'
	set -u
	# GROW-PROBE -- facts only. The verdict is computed on the host.
	if command -v systemd-repart >/dev/null 2>&1; then echo "REPART_BINARY=yes"; else echo "REPART_BINARY=no"; fi
	state=$(systemctl is-enabled systemd-repart.service 2>/dev/null || echo unknown)
	echo "REPART_ENABLED=$state"
	if [ "$state" = masked ]; then echo "REPART_MASKED=yes"; else echo "REPART_MASKED=no"; fi
	if systemctl show -p WantedBy --value systemd-repart.service 2>/dev/null | grep -q 'sysinit.target'; then
		echo "REPART_WANTEDBY_SYSINIT=yes"
	else
		echo "REPART_WANTEDBY_SYSINIT=no"
	fi
	if systemctl cat systemd-growfs-root.service 2>/dev/null | grep -q 'After=.*systemd-repart\.service'; then
		echo "GROWFS_AFTER_REPART=yes"
	else
		echo "GROWFS_AFTER_REPART=no"
	fi
	GUEST
	)
	printf '%s\n' "$probe" | sed 's/^/       /'

	# The probe's facts are still printed above: they are useful diagnostics and
	# they document the guest this artifact was built on. They no longer DECIDE
	# anything -- see the GROW_UNIT note at the top of this file.
	info "growth unit: CUSTOM switch-growroot.service (the shipped unit is masked)"

	push_file "$ASSETS/usr.local.sbin/switch-growroot" \
		/usr/local/sbin/switch-growroot 0755
	push_file "$ASSETS/etc.systemd.system/switch-growroot.service" \
		/etc/systemd/system/switch-growroot.service 0644

	ssh_vm 'sudo sh -s' <<-'GUEST'
	set -eu
	systemctl daemon-reload
	systemctl enable switch-growroot.service

	# 🔴 MASK, not disable. systemd-repart.service is `static` -- it has no
	# [Install] section, so `disable` is a no-op on it: it is pulled in by a
	# static wants symlink under /usr/lib, which only masking overrides. It
	# would otherwise keep running alongside our unit, keep exiting 1 on a full
	# disk, and keep the artifact permanently in `systemctl --failed`.
	systemctl mask systemd-repart.service
	echo "systemd-repart.service is now: $(systemctl is-enabled systemd-repart.service 2>&1)"
	GUEST
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
	#
	# 🔴 cloud-guest-utils is purged BY NAME (operator ruling, iter 13), and the
	# by-name part is the whole point. It ships IN THE BASE IMAGE -- this stage
	# never installs it -- and it is MANUALLY marked, so purging cloud-init does
	# NOT autoremove it. Measured on a pristine trixie guest:
	#
	#     cloud-guest-utils 0.33-1 install ok installed
	#     Reverse Depends: cloud-init, cloud-utils
	#
	# Leaving it would ship a cloud-* package the image is defined as not
	# carrying, and would leave the boot-test's "no cloud-init/netplan packages"
	# assertion unable to see it. Its only content of interest was growpart, and
	# growth is systemd-repart now, so nothing depends on it. Both reverse-deps
	# are safe: cloud-init is in this very list, and cloud-utils is not installed.
	CANDIDATES="cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot cloud-guest-utils"
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
	for p in cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot cloud-guest-utils; do
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
	# 🔴 THIS COMMENT USED TO SAY "systemd-repart exits 0 on no-change, so this
	# is a clean assertion -- there is no exit-1-means-two-things ambiguity
	# here; that was growpart." It is FALSE. Measured 2026-08-03: on a disk with
	# no free space it exits 1 with "Can't fit requested partitions into
	# available free space (0B), refusing." The ambiguity was never growpart's
	# alone, and this check asserted the false half of it.
	#
	# What a dry run can still prove is that the CONFIGURATION PARSES and the
	# disk is understood. So the tolerated outcome is named explicitly, exactly
	# as the wrapper names it, and anything else is still a failure.
	echo "  -- systemd-repart --dry-run=yes --"
	if systemd-repart --dry-run=yes > /tmp/repart.dryrun 2>&1; then
		sed 's/^/       /' /tmp/repart.dryrun
		ok "systemd-repart parses the configuration and understands the disk"
	elif grep -q "Can't fit requested partitions into available free space" /tmp/repart.dryrun; then
		sed 's/^/       /' /tmp/repart.dryrun
		ok "systemd-repart parses the configuration; nothing to grow on this disk (the wrapper tolerates exactly this)"
	else
		sed 's/^/       /' /tmp/repart.dryrun
		bad "systemd-repart --dry-run=yes failed for a reason that is NOT 'no free space'"
	fi
	rm -f /tmp/repart.dryrun

	# The growth unit contract: ours enabled, systemd's masked, wrapper present.
	[ -x /usr/local/sbin/switch-growroot ] && ok "/usr/local/sbin/switch-growroot present" \
		|| bad "/usr/local/sbin/switch-growroot missing (the growth unit has no ExecStart)"
	[ "$(systemctl is-enabled switch-growroot.service 2>/dev/null)" = enabled ] \
		&& ok "switch-growroot.service is enabled" || bad "switch-growroot.service is not enabled"
	[ "$(systemctl is-enabled systemd-repart.service 2>/dev/null)" = masked ] \
		&& ok "systemd-repart.service is MASKED (it exits 1 on a full disk and would fail every boot)" \
		|| bad "systemd-repart.service is not masked -- it will run alongside ours and fail"
	# 🔴 The unit asset's own header calls this shape UNVERIFIED:
	# Before=local-fs-pre.target plus WantedBy=sysinit.target can produce an
	# ordering cycle. This assertion is the gate the comment defers to.
	if journalctl -b --no-pager 2>/dev/null | grep -q 'Found ordering cycle'; then
		journalctl -b --no-pager 2>/dev/null | grep -A3 'Found ordering cycle' | sed 's/^/       /'
		bad "the boot journal contains 'Found ordering cycle' -- switch-growroot's ordering is wrong"
	else
		ok "no ordering cycle in the boot journal (switch-growroot's edges are safe)"
	fi

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

# ---------------------------------------------------------------- selftest
# 🔴 NO VM, NO ROOT, NO NETWORK -- and that is proven by OUTCOME rather than
# claimed. Every network-reaching binary is shimmed onto the front of PATH and
# records its argv and its stdin, so a phase that reached a guest leaves
# evidence; SSH_PORT is forced to 1 for the duration as well, so even a shim
# that failed to intercept could not land on the build VM's 2222.
#
# This stage is a HOST-SIDE DRIVER: its work happens inside a guest, over ssh,
# as heredoc payloads. There is therefore no `--root` staging discipline
# available the way there is in stage-grub-fallback. What IS honestly testable
# offline is exactly four things, and this file tests all four:
#
#   1. every claim the six owned assets make about themselves;
#   2. grow_unit_verdict(), the one real decision, as a pure predicate over
#      text, in both polarities;
#   3. WHAT EACH PHASE SENDS AND DOES NOT SEND, read off the shim ledger --
#      which is how the safety invariants (one ssh call for finish, no reboot
#      after strip, networkd never touched) are provable with no guest;
#   4. forbidden idioms, over this script's own source AND over the exact
#      payload bytes the guest would receive.
#
# 🔴 EVERY ASSERTION BELOW HAS BEEN WATCHED TO FAIL. A guard nobody has seen go
# red is not evidence; this project has now shipped five checks that silently
# never ran.
t_pass=0
t_fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; t_pass=$((t_pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; t_fail=$((t_fail + 1)); }
inf() { printf '  \033[36mNOTE\033[0m %s\n' "$*"; }
hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Forbidden-idiom grep over a file, with COMMENTS EXEMPT so a file can document
# what it refuses to do.
#
# ⚠ The comment is STRIPPED from each line rather than anchored around with
# '^[^#]*'. That costs nothing here and buys the patterns the right to use ^ and
# $ against the code part of a line -- which is what makes a bare `reboot`
# statement distinguishable from the word "reboot" inside a message string. This
# file has exactly one such string and the naive pattern flagged it.
#
# ⚠ Every pattern passed to this function is assembled from adjacent quoted
# fragments ('a''b') so the literal never appears contiguously in this file and
# the guard cannot match its own definition. Same bug class as `pkill -f`
# matching its own shell.
forbid_in() { # $1 = file, $2 = ERE, $3 = description
	local hits
	hits="$(sed 's/#.*//' "$1" | grep -nE "$2" || true)"
	if [ -z "$hits" ]; then ok "never $3"
	else bad "$3 -- found:"; printf '%s\n' "$hits" | sed 's/^/       /'; fi
}

SELFTEST_WORK=""
SELFTEST_GUEST_PID=""
cleanup_selftest() {
	[ -n "${SELFTEST_GUEST_PID:-}" ] && kill "$SELFTEST_GUEST_PID" 2>/dev/null
	[ -n "${SELFTEST_WORK:-}" ] && rm -rf "$SELFTEST_WORK"
	return 0
}

# ------------------------------------------------------------ the shim harness
#
# 🔴 NOT declared at file scope, and that is load-bearing. `run_phase` re-enters
# THIS SCRIPT as a child process, so every file-scope assignment here runs again
# in the child -- and an unconditional `SHIM_DIR=""` at file scope silently
# blanked the exported SHIM_DIR the shims read, in the child, every time. The
# shims then aborted before writing anything, and the first draft of this
# harness recorded an empty ledger. That is the project's recurring defect
# exactly: not a check that fails, a check that never runs. Every one of these
# lives as a `local` inside do_selftest instead, where bash's dynamic scope
# makes it visible to the helpers below and invisible to the child.
#
# The vacuity guard in assert_no_forbidden_traffic() is what caught it, and is
# what keeps it caught: an empty ledger makes every "never sends X" assertion
# below trivially true.

write_shims() { # $1 = bin dir
	local d="$1" g
	mkdir -p "$d"
	cat > "$d/.recorder" <<-'SHIM'
	#!/bin/sh
	# Recorded stand-in. It logs its argv and its stdin, and answers ONLY the
	# sentinel each payload asks for -- so what the caller parses is the shape
	# of a real reply and nothing else is simulated.
	d="${SHIM_DIR:?SHIM_DIR unset -- a shim escaped its harness}"
	n=$(cat "$d/seq" 2>/dev/null || echo 0)
	n=$((n + 1))
	printf '%s\n' "$n" > "$d/seq"
	prog=${0##*/}
	printf '%s %s\n' "$prog" "$*" >> "$d/ledger"
	printf '%s\n' "$prog" > "$d/prog.$n"
	: > "$d/argv.$n"
	for a in "$@"; do printf '%s\n' "$a" >> "$d/argv.$n"; done
	: > "$d/stdin.$n"
	cat >> "$d/stdin.$n"
	p="$d/stdin.$n"
	case "$prog" in
	ssh)
		if grep -q '__GENERALIZE_OK__' "$p"; then
			[ "${SHIM_NO_SENTINEL:-0}" = 1 ] || echo "__GENERALIZE_OK__"
			# The guest powers itself off: from here on the pidfile names a
			# process that is gone. Simulated, because it is the transition
			# `finish` waits on and `export` depends on.
			if [ -n "${SHIM_POWEROFF_PIDFILE:-}" ]; then
				printf '%s\n' "${SHIM_DEAD_PID:-1}" > "$SHIM_POWEROFF_PIDFILE"
			fi
		elif grep -q 'PREFLIGHT-DONE' "$p"; then
			[ -n "${SHIM_PREFLIGHT_MISSING:-}" ] && echo "MISSING: $SHIM_PREFLIGHT_MISSING"
			echo "PREFLIGHT-DONE root=/dev/vda1 disk=/dev/vda"
		elif grep -q 'GROW-PROBE' "$p"; then
			[ -n "${SHIM_FACTS:-}" ] && cat "$SHIM_FACTS"
		elif grep -q 'VERIFY-FAILURES' "$p"; then
			# SHIM_NO_VERDICT=1 answers the verify payload with SILENCE, which
			# is not the same as answering 0 -- an unparsed verdict must not
			# read as a pass.
			[ "${SHIM_NO_VERDICT:-0}" = 1 ] || echo "VERIFY-FAILURES=${SHIM_VERIFY_FAILURES:-0}"
		fi
		;;
	qemu-img)
		# Produce the output file so the real sha256sum/du downstream have
		# something to read. The bytes are irrelevant; the argv is the assertion.
		out=
		for a in "$@"; do out=$a; done
		case "$out" in "" | -*) ;; *) printf 'fake-raw-image\n' > "$out" ;; esac
		;;
	esac
	exit 0
	SHIM
	chmod 0755 "$d/.recorder"
	# Everything that reaches a guest, a network, the host's package state or
	# the host's power state. If the driver invokes any of them outside the
	# handful of calls asserted below, the ledger says so.
	for g in ssh scp sftp rsync qemu-img qemu"-system"-x86_64 curl wget nc ncat telnet \
	         apt apt-get apt-cache dpkg dpkg-query dpkg-reconfigure update-initramfs \
	         systemctl networkctl journalctl update-grub grub"-install" grub-mkconfig \
	         userdel useradd passwd sudo mount umount swapon swapoff \
	         re"boot" poweroff shutdown halt kill pkill; do
		cp "$d/.recorder" "$d/$g"
	done
}

guest_up()   { printf '%s\n' "$SELFTEST_GUEST_PID" > "$FAKE_WORK/qemu.pid"; }
guest_down() { printf '%s\n' "${SELFTEST_DEAD_PID:-1}" > "$FAKE_WORK/qemu.pid"; }

# Run ONE phase of this very script in a subprocess, with the shims first on
# PATH. Env overrides for the run are passed as trailing VAR=VALUE arguments.
run_phase() { # $1 = phase, $2.. = VAR=VALUE
	local phase="$1"; shift
	rm -rf "$SHIM_DIR"; mkdir -p "$SHIM_DIR"
	printf '0\n' > "$SHIM_DIR/seq"; : > "$SHIM_DIR/ledger"
	PHASE_RC=0
	# </dev/null matters: a shim reading stdin with nothing redirected into it
	# would block on the caller's terminal forever.
	PHASE_OUT="$(env PATH="$SHIM_BIN:$PATH" SHIM_DIR="$SHIM_DIR" \
		WORK="$FAKE_WORK" DISTRO=debian SSH_PORT=1 POWEROFF_TIMEOUT=0 \
		SHIM_FACTS="$FACTS_HEALTHY" "$@" \
		bash "$SELF_PATH" "$phase" </dev/null 2>&1)" || PHASE_RC=$?
}

calls_total()      { cat "$SHIM_DIR/seq" 2>/dev/null || echo 0; }
prog_calls()       { grep -c "^$1 " "$SHIM_DIR/ledger" 2>/dev/null || true; }
is_shell_payload() { grep -qx 'sudo sh -s' "$SHIM_DIR/argv.$1" 2>/dev/null; }

shell_payload_count() {
	local n t c=0; t="$(calls_total)"; n=1
	while [ "$n" -le "$t" ]; do is_shell_payload "$n" && c=$((c + 1)); n=$((n + 1)); done
	printf '%s\n' "$c"
}

# Every payload the run sent, concatenated IN ORDER (the stdin.N glob would sort
# stdin.10 before stdin.2, and the ordering assertions depend on this).
all_payloads() {
	local n t; t="$(calls_total)"; n=1
	while [ "$n" -le "$t" ]; do cat "$SHIM_DIR/stdin.$n" 2>/dev/null; n=$((n + 1)); done
	return 0
}

# 🔴 SHELL PAYLOADS ONLY. push_file's stdin is an ASSET, not a script, and the
# assets contain many of the same strings the guest payloads do -- the swapfile
# helper alone has both `findmnt -no FSTYPE` and a `btrfs)` case arm. Without
# this filter, an assertion about what `prepare` ASKS THE GUEST happily matched
# the file it was uploading, and a mutation that broke the guest payload was
# still reported green.
payload_index() { # $1 = ERE. Prints the call number of the FIRST shell payload matching.
	local n t; t="$(calls_total)"; n=1
	while [ "$n" -le "$t" ]; do
		if is_shell_payload "$n" && [ -s "$SHIM_DIR/stdin.$n" ] && grep -qE "$1" "$SHIM_DIR/stdin.$n"; then
			printf '%s\n' "$n"; return 0
		fi
		n=$((n + 1))
	done
	return 1
}

# 🔴 COMMENTS STRIPPED. A guest payload is a shell script with its own comments,
# and those comments name the very paths the assertions look for. Three of the
# content assertions below passed against nothing but a comment when the code
# they were about had been deleted -- the same defect as the `grep -q NOPASSWD`
# that passed on a file whose only rule demanded a password. Line numbering is
# preserved so the ordering assertions still line up.
code_of()      { sed 's/#.*//' "$1"; }
payload_code() { code_of "$SHIM_DIR/stdin.$1"; }

pushed_call() { # $1 = guest path. Prints the call number push_file used for it.
	local n t; t="$(calls_total)"; n=1
	while [ "$n" -le "$t" ]; do
		if grep -qF -- "tee '$1'" "$SHIM_DIR/argv.$n" 2>/dev/null; then
			printf '%s\n' "$n"; return 0
		fi
		n=$((n + 1))
	done
	return 1
}

assert_pushed() { # $1 = asset relpath, $2 = guest path, $3 = mode
	local n
	if n="$(pushed_call "$2")"; then
		cmp -s "$ASSETS/$1" "$SHIM_DIR/stdin.$n" \
			&& ok "$2 receives assets/$1 byte for byte" \
			|| bad "$2 was sent something that is not assets/$1"
		grep -qF -- "chmod $3 '$2'" "$SHIM_DIR/argv.$n" \
			&& ok "$2 is installed mode $3" || bad "$2 is not installed mode $3"
	else
		bad "$2 was never pushed to the guest"
		bad "$2 mode was therefore never asserted either"
	fi
}

# Assertions every phase owes, run against whatever the last run_phase sent.
assert_no_forbidden_traffic() { # $1 = phase label
	local P="$SHIM_DIR/payloads"
	# 🔴 THE VACUITY GUARD, FIRST. Every assertion in this function is of the
	# form "X does not appear in what was sent". If nothing was sent -- a shim
	# that did not run, a phase that died early, a blanked SHIM_DIR -- they all
	# pass and prove nothing. This one fails instead.
	if [ "$(calls_total)" -gt 0 ]; then
		ok "$1 was recorded reaching a guest $(calls_total) time(s), so the assertions below are about real traffic"
	else
		bad "$1 recorded NO calls at all -- every 'never sends' assertion below would be vacuously true"
	fi
	all_payloads > "$P"
	forbid_in "$P" '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"reboot"'([[:space:]]|;|$)' \
		"$1 sends a bare reboot to the guest (the purge removed its only network configuration)"
	forbid_in "$P" 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(reboot|kexec)" \
		"$1 sends a reboot to the guest through systemctl"
	forbid_in "$P" 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(restart|reload|try-restart|start)[[:space:]]+systemd-networkd" \
		"$1 restarts systemd-networkd in the guest (it would sever the control channel)"
	forbid_in "$P" 'networkctl'"[[:space:]]+(reload|reconfigure|up|down)" \
		"$1 reloads networkd via networkctl (the same forbidden action, renamed)"
	forbid_in "$P" 'shut''down'"[[:space:]]+-r" \
		"$1 sends a reboot via the shutdown command's -r flag"
	forbid_in "$P" 'rm'"[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*/var/lib/mlxsw-fallback" \
		"$1 deletes /var/lib/mlxsw-fallback (stage-grub-fallback owns it and it must survive)"
	local n
	n="$(prog_calls qemu"-system"-x86_64)"
	[ "$n" = 0 ] && ok "$1 started no virtual machine" || bad "$1 invoked a qemu system emulator $n time(s)"
	for n in curl wget nc rsync scp sftp; do
		if [ "$(prog_calls "$n")" != 0 ]; then bad "$1 invoked $n -- this stage reaches a guest only over ssh"; return 0; fi
	done
	ok "$1 invoked none of curl/wget/nc/rsync/scp/sftp"
	for n in apt apt-get dpkg systemctl networkctl userdel reboot poweroff shutdown kill pkill; do
		if [ "$(prog_calls "$n")" != 0 ]; then
			bad "$1 ran '$n' ON THE BUILD HOST -- every one of those belongs inside a guest payload"; return 0
		fi
	done
	ok "$1 ran none of apt/dpkg/systemctl/networkctl/userdel/reboot/poweroff/kill on the build host"
}

do_selftest() {
	local W n
	# 🔴 local, never file-scope: see the note above write_shims(). Dynamic scope
	# makes every helper called from here see them; the child process does not.
	local SHIM_BIN SHIM_DIR FAKE_WORK SELF_PATH
	local FACTS_HEALTHY FACTS_MASKED FACTS_TRUNCATED
	local PHASE_OUT PHASE_RC=0
	SELFTEST_WORK="$(mktemp -d)"
	W="$SELFTEST_WORK"
	trap cleanup_selftest EXIT

	SHIM_BIN="$W/shim"; SHIM_DIR="$W/log"; FAKE_WORK="$W/work"
	mkdir -p "$FAKE_WORK" "$SHIM_DIR"
	write_shims "$SHIM_BIN"

	hdr "S0  the harness itself"
	if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
		SELF_PATH="${BASH_SOURCE[0]}"
		ok "this script is readable as a file, so the phases can be re-entered under shims"
	else
		bad "this script is not readable as a file -- selftest cannot run"; return 1
	fi
	[ -d "$ASSETS" ] && ok "assets/ is visible at $ASSETS" || { bad "no assets/ directory -- cannot assert the six owned assets"; return 1; }
	# The fake guest: a real process this script owns, so `finish` can be watched
	# NOT to kill it. Never the build VM's pid, which this file must never touch.
	sleep 600 & SELFTEST_GUEST_PID=$!
	kill -0 "$SELFTEST_GUEST_PID" 2>/dev/null \
		&& ok "the fake guest process ($SELFTEST_GUEST_PID) is alive" || bad "the fake guest process did not start"
	( exit 0 ) & SELFTEST_DEAD_PID=$!
	wait "$SELFTEST_DEAD_PID" 2>/dev/null || true
	kill -0 "$SELFTEST_DEAD_PID" 2>/dev/null \
		&& bad "the dead-pid fixture ($SELFTEST_DEAD_PID) is still alive -- the down-guest tests would be meaningless" \
		|| ok "the dead-pid fixture ($SELFTEST_DEAD_PID) really is dead"
	printf 'not-a-real-qcow2\n' > "$FAKE_WORK/work.qcow2"
	printf 'fake serial log\n'   > "$FAKE_WORK/serial.log"

	FACTS_HEALTHY="$W/facts.healthy"; FACTS_MASKED="$W/facts.masked"; FACTS_TRUNCATED="$W/facts.truncated"
	printf 'REPART_BINARY=yes\nREPART_ENABLED=enabled\nREPART_MASKED=no\nREPART_WANTEDBY_SYSINIT=yes\nGROWFS_AFTER_REPART=yes\n' > "$FACTS_HEALTHY"
	printf 'REPART_BINARY=yes\nREPART_ENABLED=masked\nREPART_MASKED=yes\nREPART_WANTEDBY_SYSINIT=yes\nGROWFS_AFTER_REPART=yes\n' > "$FACTS_MASKED"
	printf 'REPART_BINARY=yes\nREPART_ENABLED=enabled\n' > "$FACTS_TRUNCATED"

	# ------------------------------------------------------------------ S1
	hdr "S1  forbidden idioms, over this script's own source"
	# 🔴 ONE TABLE, TWO USES. S1 greps this file with every pattern and must find
	# NOTHING; S1c feeds every pattern a line that really does contain the idiom
	# and must find it. A pattern that matches nothing anywhere is
	# indistinguishable from a pattern that is simply wrong, and fifteen guards
	# that have only ever been observed to pass are exactly this project's
	# recurring defect.
	#
	# 🔴 AND IT IS THE SAFE WAY TO PROVE THEM. The obvious alternative -- insert
	# the idiom into the script and run it -- is how I destroyed the build VM
	# while writing this file: one such mutation was `pkill -f qemu-system` at
	# file scope, the harness executed the mutated script, and the pattern
	# matched the real qemu. The bait lines below are written to files and never
	# executed by anything.
	#
	# ⚠ Every pattern AND every bait is assembled from adjacent quoted fragments
	# ('a''b'), so no idiom appears contiguously in this file and S1 cannot flag
	# its own test data.
	local -a F_PAT=() F_DESC=() F_BAIT=()
	fadd() { F_PAT+=("$1"); F_DESC+=("$2"); F_BAIT+=("$3"); }
	fadd 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(restart|reload|try-restart|start)[[:space:]]+systemd-networkd" \
		"restarts systemd-networkd (configuring the network over the network severs it)" \
		"$(printf '%s restart systemd-networkd' 'systemct''l')"
	fadd 'networkctl'"[[:space:]]+(reload|reconfigure|up|down)" \
		"reloads networkd via networkctl (the same forbidden action, renamed)" \
		"$(printf '%s reload' 'networkct''l')"
	fadd '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"reboot"'([[:space:]]|;|$)' \
		"issues a bare reboot" \
		"$(printf 'true || %s' 're''boot')"
	fadd 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(reboot|kexec)" \
		"issues a reboot through systemctl (there is NO reboot after strip -- the purge took the guest's network configuration)" \
		"$(printf '%s --no-block %s' 'systemct''l' 're''boot')"
	fadd 'shut''down'"[[:space:]]+-r" \
		"reboots via the shutdown command's -r flag" \
		"$(printf '%s -r now' 'shut''down')"
	fadd '(pkill|pgrep)'"[[:space:]]+-f" \
		"uses a -f process match (it matches its own invoking shell; this has already produced a false 'VM still running' here, and it is what killed the build VM while this file was being written)" \
		"$(printf '%s -f qemu' 'pki''ll')"
	fadd 'kill'"[[:space:]]+-(9|KILL|SIGKILL)" \
		"hard-kills a process (killing qemu mid-shutdown ships a dirty filesystem)" \
		"$(printf '%s -9 1234' 'ki''ll')"
	# ⚠ COMMAND POSITION, not just the words. do_preflight's payload tells the
	# operator to run the apt command inside a message string; that is advice,
	# not an invocation, and the first draft of this pattern flagged it.
	fadd '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"apt-get"'[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(install|upgrade|dist-upgrade|full-upgrade)' \
		"installs a package (this stage only PURGES; the bootloader is asserted, never installed)" \
		"$(printf '%s install -y foo' 'apt-''get')"
	fadd 'grub'"-install" \
		"hand-rolls the low-level GRUB installer (grub-cloud-amd64's postinst carries --no-nvram --force-extra-removable, which a hand-rolled pair loses)" \
		"$(printf '%s --target=i386-pc /dev/vda' 'grub-''install')"
	fadd 'dpkg'"[[:space:]]+-i([[:space:]]|$)" \
		"installs a .deb with the low-level dpkg installer" \
		"$(printf '%s -i /tmp/x.deb' 'dpk''g')"
	fadd 'chpass''wd' "pipes a password into a system" \
		"$(printf 'echo x | %s' 'chpass''wd')"
	fadd 'NOPASS''WD' "writes a passwordless-sudo rule" \
		"$(printf 'op ALL=(ALL) %s: ALL' 'NOPASS''WD')"
	fadd 'PRIVATE'" KEY" "carries private key material" \
		"$(printf -- '-----BEGIN OPENSSH %s KEY-----' 'PRIVATE')"
	fadd 'rm'"[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*/var/lib/mlxsw-fallback" \
		"deletes /var/lib/mlxsw-fallback (stage-grub-fallback owns it; finish must preserve it)" \
		"$(printf '%s -rf /var/lib/mlxsw-fallback' 'r''m')"
	fadd 'qemu'"-system" "starts a virtual machine (vm.sh owns that)" \
		"$(printf '%s-x86_64 -m 2048' 'qemu''-system')"

	local fi_
	for fi_ in "${!F_PAT[@]}"; do
		forbid_in "$SELF_PATH" "${F_PAT[$fi_]}" "${F_DESC[$fi_]}"
	done

	hdr "S1b every one of those ${#F_PAT[@]} patterns, proven to FIRE"
	mkdir -p "$W/forbid"
	local fb
	for fi_ in "${!F_PAT[@]}"; do
		printf '%s\n' "${F_BAIT[$fi_]}" > "$W/forbid/bait.$fi_"
		fb="$( t_pass=0; t_fail=0
		       forbid_in "$W/forbid/bait.$fi_" "${F_PAT[$fi_]}" "x"; printf 't_fail=%s' "$t_fail" )"
		case "$fb" in
		*"t_fail=1"*) ok "pattern FIRES on a real instance: ${F_DESC[$fi_]%% (*}" ;;
		*)            bad "pattern NEVER FIRES -- that S1 guard is decorative: ${F_DESC[$fi_]}" ;;
		esac
		# And the same bait, commented out, must NOT fire.
		printf '# %s\n' "${F_BAIT[$fi_]}" > "$W/forbid/bait.$fi_.c"
		fb="$( t_pass=0; t_fail=0
		       forbid_in "$W/forbid/bait.$fi_.c" "${F_PAT[$fi_]}" "x"; printf 't_fail=%s' "$t_fail" )"
		case "$fb" in
		*"t_fail=0"*) ;;
		*) bad "pattern fires on the SAME line commented out: ${F_DESC[$fi_]}" ;;
		esac
	done
	ok "and none of the ${#F_PAT[@]} patterns fires on the same line commented out"

	# ------------------------------------------------------------------ S1c
	hdr "S1c forbid_in() ITSELF, watched to fail"
	# 🔴 S1b proves each PATTERN can fire; this proves the MECHANISM can report.
	# Every call in S1 runs against a file that correctly contains none of the
	# idioms, so without this section forbid_in()'s reporting branch would never
	# have executed and S1 would be fifteen decorative greps. That is this
	# project's recurring defect, five times over.
	#
	# ⚠ Split literals again: written contiguously, these fixtures would be
	# forbidden idioms in this file's OWN source and S1 would flag its own test.
	local fb
	mkdir -p "$W/forbid"
	printf 'x=1\n%s reboot\n' 'systemct''l' > "$W/forbid/bait"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/bait" 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(reboot|kexec)" \
	                 "issues a reboot through systemctl"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=1"*) ok "forbid_in() REPORTS an idiom that really is present (its failure branch is executable)" ;;
	*)            bad "forbid_in() did NOT report an idiom present in its input -- S1 is decorative: $fb" ;;
	esac
	printf '%s\n' "$fb" | grep -q 'reboot' \
		&& ok "forbid_in() prints the offending line, so the failure is actionable" \
		|| bad "forbid_in() reported a hit without showing the line"
	# MUST NOT FIRE: the idiom in a whole-line comment.
	printf '# %s reboot is exactly what this stage must never do\n' 'systemct''l' > "$W/forbid/comment"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/comment" 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(reboot|kexec)" \
	                 "issues a reboot through systemctl"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=0"*) ok "forbid_in() does NOT fire on the idiom inside a comment (this file can name what it forbids)" ;;
	*)            bad "forbid_in() fired on a commented-out idiom: $fb" ;;
	esac
	# MUST NOT FIRE: the idiom in a TRAILING comment. '^[^#]*' would have caught
	# this one and reported it; stripping the comment is what makes it exempt.
	printf 'x=1   # %s reboot would be wrong here\n' 'systemct''l' > "$W/forbid/trailing"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/trailing" 'systemctl'"[[:space:]]+(--[a-z-]+[[:space:]]+)*(reboot|kexec)" \
	                 "issues a reboot through systemctl"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=0"*) ok "forbid_in() does NOT fire on an idiom in a TRAILING comment" ;;
	*)            bad "forbid_in() fired on a trailing comment: $fb" ;;
	esac
	# 🔴 THE ONE THAT MATTERS: the note string on the /swapfile line contains the
	# word "reboot", and the first draft of the bare-reboot pattern flagged it.
	# A guard that cries wolf on its own source gets deleted, so the pattern
	# demands a COMMAND position. Prove it still catches a real one.
	printf 'echo hello\n%s\n' 'reboot' > "$W/forbid/bare"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/bare" '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"reboot"'([[:space:]]|;|$)' \
	                 "issues a bare reboot"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=1"*) ok "the bare-reboot pattern catches 'reboot' standing alone as a statement" ;;
	*)            bad "the bare-reboot pattern missed a bare reboot: $fb" ;;
	esac
	printf 'true || %s\n' 'reboot' > "$W/forbid/orreboot"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/orreboot" '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"reboot"'([[:space:]]|;|$)' \
	                 "issues a bare reboot"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=1"*) ok "the bare-reboot pattern catches '|| reboot' (the fallback spelling)" ;;
	*)            bad "the bare-reboot pattern missed '|| reboot': $fb" ;;
	esac
	printf 'note "a build %s created it"\n' 'reboot' > "$W/forbid/prose"
	fb="$( t_pass=0; t_fail=0
	       forbid_in "$W/forbid/prose" '(^[[:space:]]*|[;&|][[:space:]]*)(sudo[[:space:]]+)?'"reboot"'([[:space:]]|;|$)' \
	                 "issues a bare reboot"; printf 't_fail=%s' "$t_fail" )"
	case "$fb" in
	*"t_fail=0"*) ok "the bare-reboot pattern does NOT fire on the word 'reboot' inside a message string" ;;
	*)            bad "the bare-reboot pattern flagged prose -- it would cry wolf on this file: $fb" ;;
	esac

	# ------------------------------------------------------------------ S2
	#
	# 🔴 THIS SECTION REPLACES the grow_unit_verdict() tests. That function chose
	# between the shipped systemd-repart.service and our custom unit on four
	# WIRING facts, and it was deleted: the shipped unit's disqualifying property
	# is its EXIT STATUS on a full disk, which no wiring fact can see. It chose
	# `shipped` on a real guest and the artifact got a permanently failed unit.
	#
	# The decision moved to RUNTIME, so its test moves with it. The wrapper is
	# still a pure predicate over text -- systemd-repart's message and status in,
	# a verdict out -- so it is still exercised here in both polarities, with no
	# VM, no root and no network. SWITCH_REPART exists precisely so this is
	# testable without filling a real disk.
	hdr "S2  switch-growroot: tolerate 'nothing to grow', and NOTHING else"
	local GR="$ASSETS/usr.local.sbin/switch-growroot" FR="$W/fakerepart"
	mkdir -p "$W/gr"
	[ -x "$GR" ] || chmod +x "$GR" 2>/dev/null || true

	# $1 = exit status the stand-in returns, $2 = what it prints
	mk_repart() {
		printf '#!/bin/sh\nprintf "%%s\\n" %s\nexit %s\n' "$(printf '%q' "$2")" "$1" > "$FR"
		chmod 0755 "$FR"
	}

	mk_repart 0 'Growing existing partition 0.'
	if out="$(SWITCH_REPART="$FR" sh "$GR" 2>&1)"; then
		ok "systemd-repart exit 0 -> wrapper exit 0 (the grow happened)"
	else bad "wrapper failed on a SUCCESSFUL repart"; fi
	case "$out" in *"Growing existing partition"*)
		ok "and repart's own output is passed through, not swallowed" ;;
	*) bad "the wrapper hid repart's output" ;; esac

	# 🔴 THE CASE THE EPIC SAID COULD NOT HAPPEN. Verbatim from the guest.
	mk_repart 1 "Can't fit requested partitions into available free space (0B), refusing."
	if out="$(SWITCH_REPART="$FR" sh "$GR" 2>&1)"; then
		ok "exit 1 + 'Can't fit ... available free space' -> wrapper exit 0 (nothing to grow)"
	else
		bad "the wrapper FAILED on the no-free-space case -- this is the whole reason it exists"
	fi
	case "$out" in *"nothing to grow"*) ok "and it says why, rather than passing silently" ;;
	*) bad "the tolerated case is silent -- indistinguishable from a real grow" ;; esac

	# Everything else must still fail, or a real growth failure ships silently.
	mk_repart 1 'Failed to open device /dev/vda: No such file or directory'
	if SWITCH_REPART="$FR" sh "$GR" >/dev/null 2>&1; then
		bad "a DIFFERENT exit-1 failure was tolerated -- the wrapper is a blanket ignore"
	else ok "exit 1 for any other reason still FAILS (not a blanket ignore)"; fi

	mk_repart 2 'Something else went wrong entirely'
	if SWITCH_REPART="$FR" sh "$GR" >/dev/null 2>&1; then
		bad "exit 2 was tolerated -- the epic's 'exit 2 is a genuine error' rule is broken"
	else ok "exit 2 still FAILS loudly (the epic's rule for the identical growpart trap)"; fi
	out="$(SWITCH_REPART="$FR" sh "$GR" 2>&1 || true)"
	case "$out" in *"real growth failure"*) ok "and a real failure says AD-4's guarantee does not hold" ;;
	*) bad "a real growth failure is not explained" ;; esac

	# The status is PROPAGATED, not flattened to 1 -- a caller reading it can
	# still tell 2 from 1.
	mk_repart 2 'boom'
	# 🔴 `cmd; rc=$?` would never reach the assignment: under `set -e` the
	# failing command aborts the shell first, and this whole section is ABOUT
	# commands that fail. The && / || form keeps the status reachable.
	local rc=0
	SWITCH_REPART="$FR" sh "$GR" >/dev/null 2>&1 || rc=$?
	[ "$rc" = 2 ] && ok "the original exit status is propagated ($rc), not flattened" \
	              || bad "exit status was rewritten to $rc"

	# 🔴 The message match must not be so loose that any 'refusing' passes.
	mk_repart 1 'refusing to proceed for some other reason'
	if SWITCH_REPART="$FR" sh "$GR" >/dev/null 2>&1; then
		bad "the tolerance matched on a loose substring -- unrelated refusals pass"
	else ok "the tolerance matches the FULL message, not just 'refusing'"; fi

	# The unit must actually invoke the wrapper, or none of the above is reached.
	grep -q '^ExecStart=/usr/local/sbin/switch-growroot$' \
		"$ASSETS/etc.systemd.system/switch-growroot.service" \
		&& ok "the unit's ExecStart is the wrapper, not systemd-repart directly" \
		|| bad "the unit bypasses the wrapper -- the tolerance would never run"
	# ⚠ Anchored, so the header's EXPLANATION of why SuccessExitStatus is absent
	# does not read as its presence. The unanchored form failed on first run.
	grep -qE '^[[:space:]]*SuccessExitStatus' "$ASSETS/etc.systemd.system/switch-growroot.service" \
		&& bad "the unit carries SuccessExitStatus -- that is a blanket ignore in unit form" \
		|| ok "the unit carries no SuccessExitStatus (76/77 stay real failures)"
	grep -q '^ExecStart=-' "$ASSETS/etc.systemd.system/switch-growroot.service" \
		&& bad "the unit uses a '-' ExecStart prefix, which the epic rejected for growpart" \
		|| ok "the unit uses no '-' ExecStart prefix"

	# ------------------------------------------------------------------ S3
	hdr "S3  preflight: what it asks the guest, and what it does with the answer"
	guest_up; run_phase preflight
	[ "$PHASE_RC" = 0 ] && ok "preflight exits 0 when the guest reports no MISSING lines" \
	                    || { bad "preflight failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | sed 's/^/       /'; }
	[ "$(shell_payload_count)" = 1 ] && ok "preflight sends exactly one shell payload" \
	                                 || bad "preflight sent $(shell_payload_count) shell payloads"
	n="$(payload_index 'PREFLIGHT-DONE')" && ok "the preflight payload reached the guest" || bad "no preflight payload was sent"
	local PF="$W/preflight.code"
	code_of "$SHIM_DIR/stdin.${n:-1}" > "$PF"
	# 🔴 THE ORDERING CONTRACT, asserted as text -- and text is the honest limit
	# here. This payload runs in a guest (findmnt, lsblk, dpkg-query, /etc/passwd),
	# so what can be proven with no guest is that each precondition's TEST and its
	# FAILURE REPORT both travel to it. Asserting only one of the two is not
	# enough: a mutation that replaced `fail` with `true` left every path name
	# standing in the test, and the first draft of these checks passed on that.
	assert_precondition() { # $1 = test fragment, $2 = report fragment, $3 = what
		local t=GONE r=GONE
		grep -qF -- "$1" "$PF" && t=present
		grep -qF -- "$2" "$PF" && r=present
		if [ "$t" = present ] && [ "$r" = present ]; then ok "preflight requires $3"
		else bad "preflight does not require $3 (test: $t, failure report: $r)"; fi
	}
	assert_precondition '[ -f /etc/default/grub.d/25_switch-boot-policy.cfg ]' \
		'fail "/etc/default/grub.d/25_switch-boot-policy.cfg (stage-grub-fallback)' \
		"stage-grub-fallback's 25_switch-boot-policy.cfg -- without it GRUB is regenerated with no boot policy"
	assert_precondition '[ -e /etc/default/grub.d/15_timeout.cfg ]' \
		'fail "/etc/default/grub.d/15_timeout.cfg still exists' \
		"15_timeout.cfg to be GONE (grub-fallback DELETES it; it forces GRUB_TIMEOUT=0, which displays no menu at all)"
	assert_precondition '[ -f /var/lib/mlxsw-fallback/last-known-good ]' \
		'fail "/var/lib/mlxsw-fallback/last-known-good' \
		"grub-fallback's state file -- the only proof that the STAGE ran rather than that a file was copied"
	assert_precondition '[ -f /etc/default/grub.d/20_switch-cmdline.cfg ]' \
		'fail "/etc/default/grub.d/20_switch-cmdline.cfg' \
		"stage-runtime-contract's cmdline drop-in"
	assert_precondition 'set -- /etc/systemd/network/*.network' \
		'fail "/etc/systemd/network/*.network' \
		"the networkd units -- the netplan replacement that strip is about to delete"
	assert_precondition 'systemctl is-enabled systemd-networkd.service' \
		'fail "systemd-networkd is not enabled' \
		"systemd-networkd to be ENABLED, not merely configured"
	assert_precondition 'command -v systemd-repart' \
		'fail "systemd-repart binary' \
		"the systemd-repart binary (a separate package on Debian, inside systemd on Arch)"
	assert_precondition "dpkg-query -W -f='\${db:Status-Status}' grub-cloud-amd64" \
		'fail "grub-cloud-amd64 is not installed' \
		"grub-cloud-amd64 to be present -- the bootloader is ASSERTED, never installed"
	assert_precondition '[ -e /etc/grub.d/enable_cloud ]' \
		'fail "/etc/grub.d/enable_cloud' \
		"/etc/grub.d/enable_cloud, without which grub-cloud's postinst is a no-op"
	assert_precondition "awk -F: '\$3>=1000" \
		'fail "no non-system login account' \
		"a login account other than builder -- the artifact would otherwise ship with no way in"
	assert_precondition '[ "$RN" = "$L" ]' 'AD-4 VIOLATED' \
		"root to be the LAST partition BY START SECTOR (AD-4; growth would silently decline otherwise)"
	# MUST FAIL -- a precondition that is not met must stop the stage.
	guest_up; run_phase preflight SHIM_PREFLIGHT_MISSING="/etc/default/grub.d/25_switch-boot-policy.cfg (stage-grub-fallback)"
	[ "$PHASE_RC" != 0 ] && ok "a MISSING precondition ABORTS preflight (PREFLIGHT_STRICT=1)" \
	                     || bad "preflight passed with a MISSING precondition -- the guard cannot fail"
	printf '%s\n' "$PHASE_OUT" | grep -q 'preconditions are not met' \
		&& ok "the abort names the unmet preconditions" || bad "the abort message does not mention the preconditions"
	guest_up; run_phase preflight SHIM_PREFLIGHT_MISSING="anything" PREFLIGHT_STRICT=0
	[ "$PHASE_RC" = 0 ] && ok "PREFLIGHT_STRICT=0 downgrades the abort to a warning" || bad "PREFLIGHT_STRICT=0 still aborted"
	printf '%s\n' "$PHASE_OUT" | grep -q 'NON-REPRESENTATIVE' \
		&& ok "a weakened run is labelled NON-REPRESENTATIVE" || bad "a weakened run is not labelled"
	assert_no_forbidden_traffic preflight

	# ------------------------------------------------------------------ S4
	hdr "S4  prepare: the six assets, the fstab edit, and the growth decision"
	guest_up; run_phase prepare
	[ "$PHASE_RC" = 0 ] && ok "prepare exits 0 against a healthy guest" \
	                    || { bad "prepare failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | sed 's/^/       /'; }
	assert_pushed etc.repart.d/50-root.conf                   /etc/repart.d/50-root.conf                   0644
	assert_pushed usr.local.sbin/switch-firstboot             /usr/local/sbin/switch-firstboot             0755
	assert_pushed etc.systemd.system/switch-firstboot.service /etc/systemd/system/switch-firstboot.service 0644
	assert_pushed usr.local.sbin/switch-swapfile              /usr/local/sbin/switch-swapfile              0755
	assert_pushed etc.systemd.system/switch-swapfile.service  /etc/systemd/system/switch-swapfile.service  0644
	# 🔴 preflight FIRST. `prepare` that ran before its preconditions were met
	# would push assets into a guest the stage is about to refuse.
	[ "$(payload_index 'PREFLIGHT-DONE')" -lt "$(pushed_call /etc/repart.d/50-root.conf)" ] \
		&& ok "preflight runs BEFORE the first asset is pushed" || bad "assets are pushed before preflight"
	# ⚠ The EDIT, not the word: the payload names x-systemd.growfs three times,
	# and a mutation that deleted the assignment left two of them standing.
	local FT; FT="$W/fstab.code"; payload_code "$(payload_index 'fstab.new')" > "$FT"
	grep -qF '$4=$4",x-systemd.growfs"' "$FT" \
		&& ok "the fstab payload APPENDS x-systemd.growfs to the root row's options (the FILESYSTEM half of growth)" \
		|| bad "the fstab payload does not append x-systemd.growfs"
	grep -qF 'x-systemd\.growfs(,|$)' "$FT" \
		&& ok "and it detects the option already being there, so a re-run is a no-op" \
		|| bad "the fstab payload is not idempotent"
	grep -q 'rewritten fstab has no single root row' "$FT" \
		&& ok "the fstab payload refuses to install a table that lost its root row" || bad "the fstab rewrite has no safety check"
	# ⚠ The WRITE, not the word: a mutation that replaced the printf with `true`
	# left the string standing in its own argument list.
	payload_code "$(payload_index 'RESUME=none' || echo 0)" 2>/dev/null \
		| grep -qF "printf 'RESUME=none\\n' > /etc/initramfs-tools/conf.d/resume" \
		&& ok "prepare WRITES RESUME=none (a stale RESUME= cost a hand-fixed initramfs on the 2410)" \
		|| bad "RESUME=none is never written"
	grep -qF 'systemctl enable switch-firstboot.service switch-swapfile.service' "$SHIM_DIR/ledger" \
		&& ok "both first-boot units are enabled, in one call" || bad "the first-boot units are not enabled together"
	payload_code "$(payload_index 'findmnt -no FSTYPE' || echo 0)" 2>/dev/null | grep -qE '^[[:space:]]*btrfs\)' \
		&& ok "prepare asserts the root filesystem can carry a plain swapfile (a btrfs case arm that refuses)" \
		|| bad "the swapfile filesystem precondition is not checked"
	# 🔴 THE GROWTH UNIT IS UNCONDITIONAL NOW. The eight assertions that used to
	# live here tested GROW_UNIT=auto/shipped/custom and the truncated-probe
	# refusal -- a decision that has been deleted, because it chose `shipped` on
	# healthy wiring facts and the artifact got a permanently failed unit. What
	# replaces them is stricter: the custom unit and its wrapper go in ALWAYS,
	# and the shipped unit is masked ALWAYS, whatever the probe says.
	assert_pushed usr.local.sbin/switch-growroot /usr/local/sbin/switch-growroot 0755
	assert_pushed etc.systemd.system/switch-growroot.service /etc/systemd/system/switch-growroot.service 0644
	# ⚠ These two go to the guest inside a `sudo sh -s` HEREDOC, so they are in
	# the payload, not in the ledger's argv -- and comments are stripped, because
	# the payload documents its own reasoning and a whole-text grep would match
	# the explanation instead of the command.
	all_payloads | sed 's/#.*//' | grep -q 'systemctl enable switch-growroot.service' \
		&& ok "switch-growroot.service is enabled" || bad "switch-growroot.service is never enabled"
	all_payloads | sed 's/#.*//' | grep -q 'systemctl mask systemd-repart.service' \
		&& ok "the shipped systemd-repart.service is MASKED (disable is a no-op: it is a static unit)" \
		|| bad "the shipped unit is not masked -- it would run alongside ours and fail on a full disk"
	printf '%s\n' "$PHASE_OUT" | grep -q 'growth unit: CUSTOM' \
		&& ok "the growth-unit choice is reported to the operator" || bad "the growth-unit choice is not reported"
	# The probe still runs, and its facts are still printed -- as diagnostics.
	printf '%s\n' "$PHASE_OUT" | grep -q 'REPART_BINARY=' \
		&& ok "the probe facts are still recorded (diagnostics, deciding nothing)" \
		|| bad "the probe facts are no longer reported at all"
	assert_no_forbidden_traffic prepare
	# 🔴 AND THE DECISION DOES NOT MOVE WITH THE FACTS. This is the assertion the
	# deleted verdict function could never make: unhealthy facts, healthy facts
	# and a truncated probe must all produce the SAME install.
	for f in "$FACTS_MASKED" "$FACTS_TRUNCATED"; do
		guest_up; run_phase prepare SHIM_FACTS="$f"
		[ "$PHASE_RC" = 0 ] && ok "prepare still exits 0 with a different probe result" \
		                    || bad "prepare failed on a differing probe result: rc=$PHASE_RC"
		pushed_call /usr/local/sbin/switch-growroot >/dev/null 2>&1 \
			&& ok "and the wrapper is installed regardless of what the probe said" \
			|| bad "the probe result changed whether the wrapper was installed"
		all_payloads | sed 's/#.*//' | grep -q 'systemctl mask systemd-repart.service' \
			&& ok "and the shipped unit is masked regardless" || bad "masking depended on the probe"
	done
	# 🔴 MUST FAIL: an unmet precondition must stop prepare BEFORE anything is
	# installed. A stage that pushes five files and then refuses has already
	# changed the guest.
	guest_up; run_phase prepare SHIM_PREFLIGHT_MISSING="/var/lib/mlxsw-fallback/last-known-good (stage-grub-fallback)"
	[ "$PHASE_RC" != 0 ] && ok "an unmet precondition aborts prepare" || bad "prepare ran with an unmet precondition"
	pushed_call /etc/repart.d/50-root.conf >/dev/null 2>&1 \
		&& bad "prepare pushed assets into a guest it then refused" \
		|| ok "NOTHING was pushed to the guest before the refusal"

	# ------------------------------------------------------------------ S5
	hdr "S5  strip: the purge list, and the two regenerations after it"
	guest_up; run_phase strip
	[ "$PHASE_RC" = 0 ] && ok "strip exits 0" || { bad "strip failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | sed 's/^/       /'; }
	# 🔴 THE FIX. `strip` regenerates GRUB, and the ordering contract at the top
	# of this file makes stage-grub-fallback its precondition. Before this, the
	# dispatch ran do_strip with no preflight at all.
	payload_index 'PREFLIGHT-DONE' >/dev/null \
		&& ok "strip runs preflight first (grub-fallback MUST precede it -- the header says so)" \
		|| bad "strip runs with NO precondition check: the boot policy could be absent from the regenerated grub.cfg"
	local SP; SP="$W/strip.code"; payload_code "$(payload_index 'CANDIDATES=')" > "$SP"
	for n in cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot cloud-guest-utils; do
		grep -q "CANDIDATES=.*[\" ]$n[\" ]" "$SP" && ok "the purge list names $n" || bad "the purge list is missing $n"
	done
	[ "$(sed -n 's/^CANDIDATES="\(.*\)"$/\1/p' "$SP" | wc -w)" = 7 ] \
		&& ok "the purge list is exactly 7 packages, no more" \
		|| bad "the purge list has $(sed -n 's/^CANDIDATES="\(.*\)"$/\1/p' "$SP" | wc -w) entries, expected 7"
	# 🔴 CLOSED iter 13 by operator ruling. cloud-guest-utils ships in the BASE
	# IMAGE and is MANUALLY marked, so purging cloud-init does NOT autoremove it
	# -- it has to be named, and now is. The `verify` phase must check it too, or
	# the purge is unasserted; that pairing is what this asserts.
	grep -q 'cloud-guest-utils' "$SP" \
		&& ok "cloud-guest-utils is purged BY NAME (autoremove would never take it -- it is manually marked)" \
		|| bad "cloud-guest-utils is not purged: a cloud-* package would ship in an image defined as not carrying one"
	# 🔴 ANCHORED AT LINE START ON PURPOSE. Without `^[[:space:]]*for p in` this
	# pattern matches THIS VERY LINE -- the assertion's own source -- and can
	# therefore never fail. Caught by mutation testing: deleting the package from
	# verify's loop left the selftest green. The anchor excludes the `if [ ... ]`
	# line while still matching the loop it is about.
	if [ -n "${SELF_PATH:-}" ] && grep -qE '^[[:space:]]*for p in cloud-init.*cloud-guest-utils' "$SELF_PATH"; then
		ok "verify's cloud-residue loop checks cloud-guest-utils too (purged AND asserted, not just purged)"
	else bad "verify does not check cloud-guest-utils -- the purge would be unasserted"; fi
	grep -q 'apt-get purge -y' "$SP" && ok "the purge is a PURGE, not a remove (conffiles go too)" || bad "the strip payload does not purge"
	grep -q 'rm -rf /etc/netplan /etc/cloud /var/lib/cloud' "$SP" \
		&& ok "the netplan and cloud-init state directories are removed" || bad "the cloud state directories survive"
	grep -qF 'cp /etc/sudoers.d/90-cloud-init-users /etc/sudoers.d/00-build-generalize' "$SP" \
		&& ok "strip COPIES the sudo insurance before the purge (the passwordless-sudo rule lives in a cloud-init-written file)" \
		|| bad "strip does not preserve sudo access across the purge"
	# ⚠ `|| echo 0` on every index: a missing payload must report as a FAILED
	# ordering assertion, not abort the selftest with 'integer expected'.
	local I G C
	C="$(payload_index 'CANDIDATES=' || echo 0)"
	I="$(payload_index 'lsinitramfs' || echo 0)"
	G="$(payload_index 'dpkg-reconfigure' || echo 0)"
	[ "$I" -gt 0 ] && [ "$I" -gt "$C" ] && ok "the initramfs is regenerated AFTER the purge" \
	                                   || bad "the initramfs is not regenerated after the purge (purge=$C, initramfs=$I)"
	[ "$G" -gt 0 ] && [ "$G" -gt "$I" ] && ok "GRUB is regenerated LAST, so grub.cfg reflects the final drop-in set and the final initramfs" \
	                                   || bad "GRUB is not regenerated last (initramfs=$I, grub=$G)"
	payload_code "$G" 2>/dev/null | grep -q 'grub-cloud-amd64' \
		&& ok "GRUB is regenerated via grub-cloud-amd64's own postinst (it carries --no-nvram --force-extra-removable)" \
		|| bad "GRUB regeneration does not go through grub-cloud-amd64"
	payload_code "$I" 2>/dev/null | grep -q 'FAIL: the growroot hook is STILL in' \
		&& ok "the growroot initramfs hook is asserted GONE, not assumed gone" || bad "the growroot hook removal is assumed"
	# 🔴 THE SAFETY INVARIANT. The purge deleted the guest's only netplan-rendered
	# network configuration; a reboot here loses the guest for good.
	assert_no_forbidden_traffic strip

	# ------------------------------------------------------------------ S6
	hdr "S6  verify: the verdict is read from the guest, not assumed"
	guest_up; run_phase verify
	[ "$PHASE_RC" = 0 ] && ok "verify exits 0 on VERIFY-FAILURES=0" || bad "verify failed on a clean guest: rc=$PHASE_RC"
	guest_up; run_phase verify SHIM_VERIFY_FAILURES=3
	[ "$PHASE_RC" != 0 ] && ok "verify ABORTS on VERIFY-FAILURES=3 (before finish, which ends all access)" \
	                     || bad "verify passed with 3 reported failures -- the verdict is decorative"
	printf '%s\n' "$PHASE_OUT" | grep -q '3 verification failure' \
		&& ok "the abort reports the count it actually read" || bad "the verify abort does not report the count"
	guest_up; run_phase verify SHIM_VERIFY_FAILURES=3 PREFLIGHT_STRICT=0
	[ "$PHASE_RC" = 0 ] && ok "PREFLIGHT_STRICT=0 tolerates verification failures and says the artifact is not shippable" \
	                    || bad "PREFLIGHT_STRICT=0 did not tolerate verification failures"
	guest_up; run_phase verify SHIM_NO_VERDICT=1
	[ "$PHASE_RC" != 0 ] && ok "verify with no readable verdict aborts (an unparsed verdict is not a pass)" \
	                     || bad "verify accepted an empty verdict"
	assert_no_forbidden_traffic verify

	# ------------------------------------------------------------------ S7
	hdr "S7  finish: ONE ssh call, and nothing after it"
	guest_up; run_phase finish SHIM_POWEROFF_PIDFILE="$FAKE_WORK/qemu.pid" SHIM_DEAD_PID="$SELFTEST_DEAD_PID"
	[ "$PHASE_RC" = 0 ] && ok "finish exits 0 once the guest is down" \
	                    || { bad "finish failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | sed 's/^/       /'; }
	# 🔴 THE INVARIANT THIS PHASE EXISTS FOR. Removing the builder user and
	# powering off must travel in the SAME payload: after the user is gone there
	# is no way back in, and a second ssh call would find the door locked. A
	# guest that cannot be powered down gracefully is a stranded VM and a dirty
	# artifact.
	[ "$(shell_payload_count)" = 1 ] && ok "finish sends EXACTLY ONE shell payload" \
	                                 || bad "finish sent $(shell_payload_count) shell payloads -- the guest is unreachable between them"
	[ "$(prog_calls ssh)" = 2 ] && ok "finish makes exactly 2 ssh calls: the liveness probe, then the one payload" \
	                            || bad "finish made $(prog_calls ssh) ssh calls"
	local FIN; FIN="$W/finish.code"; payload_code "$(payload_index '__GENERALIZE_OK__')" > "$FIN"
	# ⚠ COMMAND POSITION for userdel. The payload also says "still exists after
	# userdel" in an error message, and a bare grep passed on that alone once the
	# call itself had been replaced.
	grep -qE '^[[:space:]]*userdel[[:space:]]+-f[[:space:]]+-r[[:space:]]' "$FIN" && grep -q 'systemctl poweroff' "$FIN" \
		&& ok "the ONE payload carries BOTH the builder-user removal and the poweroff" \
		|| bad "the payload does not carry both halves -- the guest would be stranded"
	grep -q 'still exists after userdel' "$FIN" \
		&& ok "and it asserts the OUTCOME of the removal, not userdel's exit status (12 means 'removed, home survived')" \
		|| bad "the removal is trusted to its exit status"
	[ "$(grep -c 'systemctl poweroff' "$FIN")" = 1 ] && ok "the poweroff is issued exactly once" || bad "the poweroff appears more than once"
	grep -n 'systemctl poweroff' "$FIN" | cut -d: -f1 | { read -r n; [ "$n" -gt "$(grep -n 'userdel' "$FIN" | head -1 | cut -d: -f1)" ]; } \
		&& ok "the poweroff is the LAST thing in the payload, after the removal" || bad "the poweroff is not last"
	grep -q '__GENERALIZE_OK__' "$FIN" && ok "a sentinel separates a generalize failure from the connection dying on poweroff" \
	                                   || bad "there is no sentinel"
	grep -q 'preserved: /var/lib/mlxsw-fallback' "$FIN" \
		&& ok "finish preserves /var/lib/mlxsw-fallback (stage-grub-fallback's state, and it must ship)" \
		|| bad "finish does not preserve grub-fallback's state directory"
	grep -q 'rm -f /swapfile' "$FIN" && ok "the 2 GiB swapfile is removed: the UNIT ships, the FILE does not" || bad "the swapfile is not removed"
	grep -q 'journalctl --rotate' "$FIN" && grep -q 'rm -rf /var/log/journal/\*' "$FIN" \
		&& ok "the build's journal is rotated and removed (the artifact must not ship this build's logs)" \
		|| bad "the build journal would ship inside the artifact"
	grep -q '/etc/sudoers.d/00-build-generalize' "$FIN" && ok "the build-time passwordless-sudo insurance is removed before the artifact ships" \
	                                                    || bad "the sudo insurance would reach a switch"
	grep -q 'rm -f /etc/ssh/ssh_host_' "$FIN" && ok "the SSH host keys are deleted (a fleet sharing one is a fleet sharing an identity)" \
	                                          || bad "the host keys survive generalization"
	grep -q ': > /etc/machine-id' "$FIN" && ok "machine-id is TRUNCATED, not deleted (that is what makes ConditionFirstBoot= fire)" \
	                                     || bad "machine-id is not truncated"
	[ ! -e "$FAKE_WORK/qemu.pid" ] && ok "the pidfile is removed once the guest is down" || bad "the pidfile survives a successful finish"
	assert_no_forbidden_traffic finish
	# MUST FAIL: no sentinel means the guest was NOT generalized.
	guest_up; run_phase finish SHIM_NO_SENTINEL=1
	[ "$PHASE_RC" != 0 ] && ok "a missing sentinel aborts finish" || bad "finish accepted a payload that never reached its sentinel"
	printf '%s\n' "$PHASE_OUT" | grep -q 'do not export' \
		&& ok "the abort says not to export an ungeneralized image" || bad "the abort does not warn against exporting"
	# 🔴 THE OTHER SAFETY PROPERTY: a guest that will not power off is NOT killed.
	# A forced kill is a power cut on a filesystem mid-shutdown.
	guest_up; run_phase finish
	[ "$PHASE_RC" != 0 ] && ok "a guest that never powers off fails the phase" || bad "finish returned success with the guest still up"
	kill -0 "$SELFTEST_GUEST_PID" 2>/dev/null \
		&& ok "the guest process was NOT killed on timeout (a forced kill ships a dirty filesystem)" \
		|| bad "finish KILLED the guest process on timeout"
	[ -e "$FAKE_WORK/qemu.pid" ] && ok "the pidfile is left in place after a timeout, so the state is still inspectable" \
	                             || bad "the pidfile was removed even though the guest is still running"
	printf '%s\n' "$PHASE_OUT" | grep -q 'NOT killing it' && ok "the timeout message says why it refuses to kill" || bad "the timeout message does not explain itself"

	# ------------------------------------------------------------------ S8
	hdr "S8  all: the phase order, end to end, and nothing in the guest after finish"
	guest_up; run_phase all SHIM_POWEROFF_PIDFILE="$FAKE_WORK/qemu.pid" SHIM_DEAD_PID="$SELFTEST_DEAD_PID" \
		OUT="$FAKE_WORK/all.raw"
	[ "$PHASE_RC" = 0 ] && ok "all exits 0" || { bad "all failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | tail -20 | sed 's/^/       /'; }
	local A B C D E
	A="$(payload_index 'PREFLIGHT-DONE')"; B="$(pushed_call /etc/repart.d/50-root.conf)"
	C="$(payload_index 'CANDIDATES=')";    D="$(payload_index 'VERIFY-FAILURES')"
	E="$(payload_index '__GENERALIZE_OK__')"
	[ "$A" -lt "$B" ] && [ "$B" -lt "$C" ] && [ "$C" -lt "$D" ] && [ "$D" -lt "$E" ] \
		&& ok "phase order holds: preflight($A) -> prepare($B) -> strip($C) -> verify($D) -> finish($E)" \
		|| bad "phase order is wrong: preflight=$A prepare=$B strip=$C verify=$D finish=$E"
	# 🔴 Nothing may run in the guest after finish: it removes the builder user,
	# and every remaining tool -- vm.sh ssh|down|provision|probe|audit -- connects
	# as that user. This is the assertion for that, and it is positional: the
	# generalize payload must be the LAST ssh call of the whole run.
	local LASTSSH=0 nn=1 TT
	TT="$(calls_total)"
	while [ "$nn" -le "$TT" ]; do
		[ "$(cat "$SHIM_DIR/prog.$nn" 2>/dev/null)" = ssh ] && LASTSSH="$nn"
		nn=$((nn + 1))
	done
	[ "$LASTSSH" = "$E" ] && ok "NO ssh call of any kind follows the generalize payload (call $E of $TT)" \
	                      || bad "an ssh call (#$LASTSSH) follows the generalize payload -- vm.sh connects as the user finish just deleted"
	if [ "$(prog_calls qemu-img)" = 1 ]; then ok "qemu-img runs exactly once in a whole run"; else bad "qemu-img ran $(prog_calls qemu-img) times"; fi
	# The conversion must come after the last ssh, because the guest must be DOWN.
	nn=1; local QEMU_AT=0
	while [ "$nn" -le "$TT" ]; do
		[ "$(cat "$SHIM_DIR/prog.$nn" 2>/dev/null)" = qemu-img ] && QEMU_AT="$nn"
		nn=$((nn + 1))
	done
	[ "$QEMU_AT" -gt "$LASTSSH" ] && ok "the image conversion happens AFTER the last guest contact (converting a live image captures a torn filesystem)" \
	                             || bad "qemu-img ran while the guest was still being talked to"
	assert_no_forbidden_traffic all

	# ------------------------------------------------------------------ S9
	hdr "S9  export: a host-side conversion, with the guest already down"
	guest_down; run_phase export OUT="$FAKE_WORK/artifact.raw"
	[ "$PHASE_RC" = 0 ] && ok "export exits 0 with the guest down" || { bad "export failed: rc=$PHASE_RC"; printf '%s\n' "$PHASE_OUT" | sed 's/^/       /'; }
	grep -q '^qemu-img convert -p -O raw ' "$SHIM_DIR/ledger" \
		&& ok "export runs qemu-img convert -p -O raw" || bad "the conversion is not 'convert -p -O raw': $(grep '^qemu-img' "$SHIM_DIR/ledger")"
	[ "$(prog_calls ssh)" = 0 ] && ok "export contacts NO guest (there is nothing left to contact)" || bad "export made $(prog_calls ssh) ssh calls"
	[ -f "$FAKE_WORK/artifact.raw.sha256" ] && ok "export writes a .sha256 beside the artifact" || bad "no checksum file was written"
	( cd "$FAKE_WORK" && sha256sum -c artifact.raw.sha256 >/dev/null 2>&1 ) \
		&& ok "the recorded checksum verifies against the artifact" || bad "the recorded checksum does not verify"
	grep -q 'dd it with' <<< "$PHASE_OUT" && ok "export prints the dd command an operator needs" || bad "export does not print the dd invocation"
	# MUST FAIL: a live guest means a torn filesystem.
	guest_up; run_phase export OUT="$FAKE_WORK/artifact2.raw"
	[ "$PHASE_RC" != 0 ] && ok "export REFUSES while the guest is running" || bad "export converted a live image"
	[ ! -e "$FAKE_WORK/artifact2.raw" ] && ok "and it wrote nothing" || bad "it wrote an artifact anyway"
	printf '%s\n' "$PHASE_OUT" | grep -q 'torn filesystem' && ok "the refusal explains the torn filesystem" || bad "the refusal is unexplained"
	# MUST FAIL: no working image at all.
	guest_down; mv "$FAKE_WORK/work.qcow2" "$FAKE_WORK/work.qcow2.hidden"
	run_phase export
	[ "$PHASE_RC" != 0 ] && ok "export refuses when there is no working image" || bad "export ran with no input image"
	mv "$FAKE_WORK/work.qcow2.hidden" "$FAKE_WORK/work.qcow2"
	# The NON-REPRESENTATIVE rename: a weakened run must not produce a filename
	# that can be mistaken for a shippable artifact.
	guest_down; run_phase export PREFLIGHT_STRICT=0 OUT="$FAKE_WORK/weak.raw"
	[ -f "$FAKE_WORK/weak-NON-REPRESENTATIVE.raw" ] \
		&& ok "PREFLIGHT_STRICT=0 renames the artifact NON-REPRESENTATIVE" \
		|| bad "a weakened run produced a normally-named artifact"
	printf '%s\n' "$PHASE_OUT" | grep -q 'is NOT shippable' && ok "and says so on the way out" || bad "the weakened artifact is not called out"
	guest_down; run_phase export
	printf '%s\n' "$PHASE_OUT" | grep -qE 'artifact:.*mlnx-sw-os-debian-[0-9]{8}\.raw' \
		&& ok "the default artifact name is mlnx-sw-os-<distro>-<UTC date>.raw" || bad "the default artifact name is wrong"

	# ------------------------------------------------------------------ S10
	hdr "S10 the six assets this stage owns"
	local RP="$ASSETS/etc.repart.d/50-root.conf"
	local FU="$ASSETS/etc.systemd.system/switch-firstboot.service"
	local SU="$ASSETS/etc.systemd.system/switch-swapfile.service"
	local GU="$ASSETS/etc.systemd.system/switch-growroot.service"
	local FS="$ASSETS/usr.local.sbin/switch-firstboot"
	local SS="$ASSETS/usr.local.sbin/switch-swapfile"

	# 50-root.conf -- one file, every disk.
	forbid_in "$RP" '^[[:space:]]*Device=' "50-root.conf pins a Device= (it must work on vda, sda and nvme0n1 with no branching)"
	forbid_in "$RP" '/dev/' "50-root.conf names a device path at all"
	forbid_in "$RP" '^[[:space:]]*(SizeMaxBytes|Weight)=' "50-root.conf caps the growth (it must take all free space)"
	grep -qx '\[Partition\]' "$RP" && ok "50-root.conf has a [Partition] section" || bad "50-root.conf has no [Partition] section"
	grep -qx 'Type=root' "$RP" && ok "50-root.conf selects Type=root -- it MATCHES the existing partition rather than creating one" \
	                           || bad "50-root.conf does not select Type=root"
	[ "$(sed 's/#.*//' "$RP" | grep -c '[^[:space:]]')" = 2 ] \
		&& ok "50-root.conf is exactly two directives ([Partition], Type=root) and nothing else" \
		|| bad "50-root.conf carries $(sed 's/#.*//' "$RP" | grep -c '[^[:space:]]') directives, expected 2"

	# switch-firstboot.service -- identity only, Condition never Assert.
	grep -qx 'ConditionFirstBoot=yes' "$FU" && ok "switch-firstboot.service uses ConditionFirstBoot=yes" || bad "switch-firstboot.service has no ConditionFirstBoot=yes"
	# 🔴 A unit ordered Before=systemd-networkd.service MUST NOT also carry the
	# implicit After=basic.target that DefaultDependencies adds: networkd is
	# needed before basic.target, so the two close an ordering cycle. Measured on
	# a real boot 2026-08-03 -- systemd broke it by DELETING a job, and which job
	# it deletes is not predictable. Any unit with the Before= edge needs this.
	grep -qx 'DefaultDependencies=no' "$FU" \
		&& ok "switch-firstboot.service sets DefaultDependencies=no (its Before=networkd edge would otherwise close an ordering cycle)" \
		|| bad "switch-firstboot.service keeps the implicit After=basic.target AND orders itself before networkd -- that is an ordering cycle"
	grep -qx 'Conflicts=shutdown.target' "$FU" \
		&& ok "and it re-adds the shutdown conflict that DefaultDependencies=no removes" \
		|| bad "DefaultDependencies=no without Conflicts=shutdown.target leaves the unit running into shutdown"
	forbid_in "$FU" '^[[:space:]]*Assert' \
		"switch-firstboot.service uses an Assert* directive (a failed Assert marks the unit FAILED; the project asserts 'systemctl --failed' empty with no allowlist ever)"
	forbid_in "$SU" '^[[:space:]]*Assert' "switch-swapfile.service uses an Assert* directive"
	forbid_in "$GU" '^[[:space:]]*Assert' "switch-growroot.service uses an Assert* directive"
	grep -qE '^Before=.*systemd-networkd\.service' "$FU" \
		&& ok "switch-firstboot.service is ordered Before= networkd (so DHCP cannot announce the pre-generalize hostname)" \
		|| bad "switch-firstboot.service does not run before networkd"
	grep -qE '^Before=.*[[:space:]]ssh\.service' "$FU" && grep -qE '^Before=.*sshd\.service' "$FU" \
		&& ok "switch-firstboot.service is ordered before BOTH ssh.service and sshd.service (it regenerates the keys sshd needs; the name differs by distro)" \
		|| bad "switch-firstboot.service does not order before both sshd spellings"
	grep -qx 'ExecStart=/usr/local/sbin/switch-firstboot' "$FU" && ok "switch-firstboot.service runs /usr/local/sbin/switch-firstboot" || bad "switch-firstboot.service ExecStart is wrong"
	grep -qx '\[Install\]' "$FU" && grep -qx 'WantedBy=multi-user.target' "$FU" \
		&& ok "switch-firstboot.service has an [Install] section (systemctl enable needs one)" || bad "switch-firstboot.service has no [Install] section"
	# 🔴 IDENTITY ONLY. Growth and swap belong to other units by ruling.
	forbid_in "$FU" '(repart|growfs|swap)' "switch-firstboot.service mentions growth or swap (it is identity-only by ruling)"
	forbid_in "$FS" '(systemd-repart|growfs|growpart|resize2fs|swapon|mkswap)' \
		"the switch-firstboot script grows or swaps anything (systemd-repart and x-systemd.growfs own growth)"
	forbid_in "$FS" '(netplan|networkctl|ip[[:space:]]+addr|ip[[:space:]]+link|nmcli|dhclient)' \
		"the switch-firstboot script touches the network (the shipped networkd units are the sole authority)"
	# ⚠ COMMAND POSITION. The file also says "no SSH host keys after ssh-keygen -A"
	# inside an error message, and a plain grep passed on that alone after the
	# call itself had been deleted.
	code_of "$FS" | grep -qE '^[[:space:]]*ssh-keygen[[:space:]]+-A[[:space:]]*$' \
		&& ok "switch-firstboot actually RUNS ssh-keygen -A (the host keys generalization deleted)" \
		|| bad "switch-firstboot does not run ssh-keygen -A"
	code_of "$FS" | grep -q '/sys/class/dmi/id' && ok "switch-firstboot derives the hostname from DMI (AD-5: no identity baked into the artifact)" || bad "switch-firstboot does not read DMI"
	code_of "$FS" | grep -q 'hostname already set' && ok "switch-firstboot leaves a pre-seeded /etc/hostname alone (the supported way to apply a site convention)" \
	                                               || bad "switch-firstboot would clobber a pre-seeded hostname"
	head -1 "$FS" | grep -qx '#!/bin/sh' && ok "switch-firstboot is /bin/sh (it must survive a swap of the base distro)" || bad "switch-firstboot is not /bin/sh"
	head -1 "$SS" | grep -qx '#!/bin/sh' && ok "switch-swapfile is /bin/sh" || bad "switch-swapfile is not /bin/sh"
	# ⚠ '\[\[' alone matches the '[[' inside every '[[:space:]]' bracket
	# expression in these files. The space after it is what makes it the bash
	# test keyword rather than a POSIX character class.
	forbid_in "$FS" '(\[\[[[:space:]]|[[:space:]]declare[[:space:]]|^[[:space:]]*local[[:space:]]|[[:space:]]=~[[:space:]])' \
		"the switch-firstboot script uses a bashism"
	forbid_in "$SS" '(\[\[[[:space:]]|[[:space:]]declare[[:space:]]|^[[:space:]]*local[[:space:]]|[[:space:]]=~[[:space:]])' \
		"the switch-swapfile script uses a bashism"

	# switch-swapfile.service -- a FILE, after BOTH halves of growth.
	grep -qx 'ConditionPathExists=!/swapfile' "$SU" \
		&& ok "switch-swapfile.service is conditioned on the FILE's absence, so a failed attempt retries next boot" \
		|| bad "switch-swapfile.service is not conditioned on /swapfile being absent"
	forbid_in "$SU" 'ConditionFirstBoot' "switch-swapfile.service is conditioned on first boot (it would never retry after a failure)"
	grep -qE '^After=.*systemd-repart\.service' "$SU" \
		&& ok "switch-swapfile.service is ordered after the PARTITION grow (systemd-repart)" || bad "switch-swapfile.service does not wait for systemd-repart"
	grep -qE '^After=.*systemd-growfs-root\.service' "$SU" \
		&& ok "switch-swapfile.service is ordered after the FILESYSTEM grow (systemd-growfs-root)" || bad "switch-swapfile.service does not wait for the filesystem grow"
	grep -qE '^After=.*systemd-growfs@-\.service' "$SU" \
		&& ok "switch-swapfile.service also names systemd-growfs@-.service (the generator may emit either name; inert edges are free)" \
		|| bad "switch-swapfile.service names only one of the two growfs unit spellings"
	grep -qx 'ExecStart=/usr/local/sbin/switch-swapfile' "$SU" \
		&& ok "switch-swapfile.service runs /usr/local/sbin/switch-swapfile" || bad "switch-swapfile.service ExecStart is wrong"
	grep -qx '\[Install\]' "$SU" && ok "switch-swapfile.service has an [Install] section" || bad "switch-swapfile.service has no [Install] section"
	grep -qE '^TimeoutStartSec=[0-9]+' "$SU" && ok "switch-swapfile.service raises TimeoutStartSec (a hole-free 2 GiB write on switch hardware is slow)" \
	                                         || bad "switch-swapfile.service leaves the default 90s timeout"
	code_of "$SS" | grep -q 'SIZE_MB="${SIZE_MB:-2048}"' && ok "the swapfile is 2 GiB, matching what mlnx-2410-cameo runs today" || bad "the swapfile size is not 2048 MiB"
	# 🔴 AD-4: nothing here may go near the partition table.
	forbid_in "$SS" '(parted|sgdisk|sfdisk|fdisk|partx|partprobe|mkfs)' \
		"the switch-swapfile script touches the partition table (AD-4 exists to delete swap partitions, not recreate them)"
	forbid_in "$SU" '(parted|sgdisk|sfdisk|fdisk|partx)' "switch-swapfile.service touches the partition table"
	code_of "$SS" | grep -q 'chmod 0600 "$SWAPFILE.partial"' \
		&& ok "the swapfile is chmod 0600 BEFORE mkswap (swapon refuses a world-readable one, and it would leak paged-out memory)" \
		|| bad "the swapfile is not made 0600 before mkswap"
	# ⚠ Both of these named a word that also appears in the file's own prose. The
	# btrfs one now demands the case ARM and the nofail one the fstab FIELD.
	code_of "$SS" | grep -qE '^[[:space:]]*btrfs\)' \
		&& ok "switch-swapfile has a btrfs case arm: it refuses loudly rather than creating something swapon rejects" \
		|| bad "switch-swapfile does not refuse btrfs"
	code_of "$SS" | grep -q 'sw,nofail' \
		&& ok "the fstab swap entry carries nofail (a removed swapfile must not fail the boot)" || bad "the fstab swap entry has no nofail"
	# ⚠ THE RECURRING BUG CLASS, twice, in this one file.
	forbid_in "$SS" '\[[[:space:]]+-s[[:space:]]+/proc/swaps' \
		"the switch-swapfile script size-tests /proc/swaps (procfs reports st_size 0 for a file with content: it would read 'no swap' while swapping)"
	# ⚠ THE ASSERTION LINE, not any awk. The file also LOGS the active swap with
	# awk, and a grep for that idiom passed on the log line alone after the
	# outcome assertion had been replaced by a space-anchored grep.
	code_of "$SS" | grep -qF "END{exit !f}' /proc/swaps" \
		&& ok "the swapfile's activation is asserted by FIELD-matching /proc/swaps with awk" \
		|| bad "/proc/swaps is not field-matched in the outcome assertion"
	code_of "$SS" | grep -qF 'is not active in /proc/swaps' \
		&& ok "and it DIES when the outcome is absent -- never a tool's exit status" \
		|| bad "the swapfile activation outcome is not asserted at all"
	forbid_in "$SS" 'grep'"[^|]*/proc/swaps" \
		"the switch-swapfile script greps /proc/swaps (it is TAB-delimited, so a space-anchored pattern never matches -- this project has already shipped that bug)"

	# switch-growroot.service -- no longer a fallback: it is THE growth unit.
	grep -qx '\[Install\]' "$GU" \
		&& ok "switch-growroot.service has an [Install] section -- systemctl enable cannot enable a unit without one" \
		|| bad "switch-growroot.service has no [Install] section: 'systemctl enable' would fail and growth would never run"
	grep -qx 'WantedBy=sysinit.target' "$GU" && ok "switch-growroot.service is WantedBy=sysinit.target" || bad "switch-growroot.service is not wanted by sysinit.target"
	grep -q 'UNVERIFIED UNTIL BOOTED' "$GU" \
		&& ok "the ordering-cycle risk is FLAGGED in the file, and verify is named as the gate" \
		|| bad "the ordering-cycle risk is not flagged in the unit"
	# ⚠ COMMENTS STRIPPED. The file's header EXPLAINS why SuccessExitStatus is
	# not copied, so a whole-file grep matches the explanation and reports the
	# opposite of the truth. That is the same defect as the `grep -q NOPASSWD`
	# that passed on a file demanding a password -- and it fired here, on the
	# first run of this very assertion.
	forbid_in "$GU" '^[[:space:]]*SuccessExitStatus' \
		"switch-growroot.service copies SuccessExitStatus=76/77 (on this artifact 'no root block device' and 'no GPT' are genuine failures worth surfacing)"
	grep -qx 'ExecStart=/usr/local/sbin/switch-growroot' "$GU" \
		&& ok "switch-growroot.service runs the WRAPPER, which tolerates 'nothing to grow' and nothing else" \
		|| bad "switch-growroot.service ExecStart is wrong -- it must be the wrapper, not systemd-repart directly"
	grep -qx 'ConditionPathExists=/etc/repart.d' "$GU" && ok "switch-growroot.service is conditioned on /etc/repart.d existing" || bad "switch-growroot.service has no condition"

	# ------------------------------------------------------------------ S11
	hdr "S11 no credential material anywhere this stage owns"
	local leaked=0
	for n in "$RP" "$FU" "$SU" "$GU" "$FS" "$SS" "$SELF_PATH"; do
		# ⚠ Case-SENSITIVE, and the banner form rather than the words: a
		# case-insensitive 'private key' matched the prose in this very file.
		grep -qE -- '-----BEGIN [A-Z ]*PRIVATE'' KEY-----|ssh-ed25519'' AAAA|ssh-rsa'' AAAA' "$n" && { bad "credential material in $n"; leaked=1; }
	done
	[ "$leaked" = 0 ] && ok "no key material in the six assets or in this script"
	leaked=0
	for n in "$RP" "$FU" "$SU" "$GU" "$FS" "$SS"; do
		sed 's/#.*//' "$n" | grep -qE '\$[0-9y]\$[A-Za-z0-9./]|password=|PASSWORD=' && { bad "a password or crypt hash in $n"; leaked=1; }
	done
	[ "$leaked" = 0 ] && ok "no password, and no crypt hash, in any of the six assets"

	# ------------------------------------------------------------------ S12
	hdr "S12 every payload the guest would receive parses"
	# The payloads are heredocs: nothing checks them until a guest runs them, and
	# this stage gets exactly one guest. These are the EXACT bytes recorded by
	# the shim during the runs above, not a second copy.
	guest_up; run_phase all SHIM_POWEROFF_PIDFILE="$FAKE_WORK/qemu.pid" SHIM_DEAD_PID="$SELFTEST_DEAD_PID" OUT="$FAKE_WORK/parse.raw"
	local T2 bad_parse=0 checked=0
	T2="$(calls_total)"; n=1
	while [ "$n" -le "$T2" ]; do
		if is_shell_payload "$n" && [ -s "$SHIM_DIR/stdin.$n" ]; then
			checked=$((checked + 1))
			bash -n "$SHIM_DIR/stdin.$n" 2>"$W/parse.err" || { bad_parse=1; sed 's/^/       /' "$W/parse.err"; }
		fi
		n=$((n + 1))
	done
	[ "$checked" -ge 8 ] && ok "$checked guest payloads were captured and parsed" || bad "only $checked guest payloads were captured -- the run did not cover the phases"
	[ "$bad_parse" = 0 ] && ok "every captured guest payload is syntactically valid shell" || bad "a guest payload does not parse"
	inf "no dash on this host: the payloads are parsed with 'bash -n', which does NOT catch"
	inf "bashisms. The guest runs them under 'sudo sh -s' and Debian's sh is dash --"
	inf "that gap is real and is only closable by installing dash or by the guest run."
	# The payloads must not assume bash either: they are piped to `sh`.
	local P2="$SHIM_DIR/payloads"; all_payloads > "$P2"
	forbid_in "$P2" '(\[\[[[:space:]]|declare[[:space:]]|[[:space:]]=~[[:space:]])' \
		"a guest payload uses a bashism (they are piped into 'sudo sh -s', and Debian's sh is dash)"

	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$t_pass" "$t_fail"
	[ "$t_fail" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- dispatch
case "${1:-all}" in
preflight) do_preflight ;;
prepare)   do_preflight; do_prepare ;;
# 🔴 `strip` preflights too. It is the phase the ordering contract at the top of
# this file binds -- stage-grub-fallback MUST precede it -- and it regenerates
# GRUB. A bare `strip` that skipped its preconditions would put the boot policy
# in the input and leave it out of the output, silently.
strip)     do_preflight; do_strip ;;
verify)    do_verify ;;
finish)    do_finish ;;
export)    do_export ;;
all)       do_preflight; do_prepare; do_strip; do_verify; do_finish; do_export ;;
selftest)  do_selftest ;;
*)
	sed -n '2,26p' "$0" | sed 's/^# \?//'
	printf '\nUsage: %s [preflight|prepare|strip|verify|finish|export|all|selftest]\n' "$0"
	exit 1 ;;
esac
