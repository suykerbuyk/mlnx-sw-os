#!/bin/bash
# S7 -- boot the FINISHED artifact and assert it came up correct.
#
# This is the member that makes every other member's claim checkable, so its
# assertion set is the real specification of "done". It owns a new file and
# edits nothing else: vm.sh is untouched.
#
# ---------------------------------------------------------------- the tiers
#
#   T1  OFFLINE   An INSPECTOR VM: boot the pristine base cloud image, attach
#                 the artifact as a READ-ONLY second disk, mount it and read.
#                 No boot of the artifact, so nothing the artifact does at
#                 runtime can confound the result.
#   T2  SERIAL    Boot the artifact, parse its serial log, never log in.
#   T3  ONLINE    ssh INTO the booted artifact and observe runtime state.
#
# 🔴 T1 IS AN INSPECTOR VM, NOT A LOOPBACK MOUNT, AND THAT IS A RULING.
# Reading ext4 out of a raw file on the build host needs either root (losetup)
# or e2fsprogs' debugfs plus util-linux' sfdisk. Both were rejected: the
# build-host dependency floor is qemu + xorriso + curl and it is held here the
# same way vm.sh holds it for the QMP channel. A guest we already know how to
# boot, from an image we already fetch, costs one boot and no new dependency.
#
# It also BUYS something a debugfs tier could not have: root and a real
# `mount`, so the FAT16 ESP is readable. The AD-5 question -- does the UEFI
# path resolve $prefix to the SAME /boot/grub/grubenv the BIOS path uses --
# is answerable offline because of this, and is answered below.
#
# ---------------------------------------------------------------- T3 runs on
# ---------------------------------------------------------------- SHIPPED BYTES
#
# The Phase-A review recorded, as Critical C1, that there is no execution path
# into the finished artifact, and proposed booting a MODIFIED COPY with a key
# injected offline. Measured 2026-08-04, that premise is obsolete: the shipped
# artifact carries `johns` with an authorized_keys that is byte-identical to
# the operator's public key. So T3 needs no injection and no modified copy --
# it logs into the bytes that ship. Do not reintroduce a modified-copy tier.
#
# 🔴 REACHING IT REQUIRES -device e1000e, NOT virtio-net. 24-mgmt-bond.network
# enslaves by `Driver=e1000e`. Under virtio-net NOTHING matches, the mgmt bond
# gets no member, no lease and no sshd reachable -- a harness that looked
# broken would in fact be the units working exactly as written. Presenting an
# e1000e NIC is not modifying the artifact; it is giving it the hardware it was
# written for. It also gives the bond a REAL member, which is what makes the
# mgmt-side runtime assertions discriminating at all (see H4 below).
#
# ---------------------------------------------------------------- what this
# ---------------------------------------------------------------- CANNOT prove
#
# QEMU HAS NO EMULATED SPECTRUM ASIC. mlxsw_pci binds nothing, zero swp*
# interfaces appear, and the data bridge has zero members. So port enumeration
# -- the epic's own success criterion -- is NOT verifiable here, by any amount
# of VM work. Every such assertion is reported SKIP with its reason, and every
# assertion that RUNS but cannot fail is reported WEAK with its reason. A check
# that runs and cannot fail is worse than a skip, because it prints green.
#
# Usage: boot-test.sh {offline|boot|all|selftest}
set -uo pipefail
# 🔴 DELIBERATELY NOT `set -e`. Every assertion must run: a harness that aborts
# on its first failure reports a subset it never names, which is this project's
# signature defect wearing a different hat. Fatal conditions call die().

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/.." && pwd)"

# ---------------------------------------------------------------- config

# NOT vm.sh's /var/tmp/mlnx-sw-os-vm. Per review finding M3, sharing WORK with
# the build VM means sharing its pidfile, and vm.sh's do_destroy would then
# remove the wrong artefacts.
WORK="${WORK:-/var/tmp/mlnx-sw-os-boot-test}"
VM_WORK="${VM_WORK:-/var/tmp/mlnx-sw-os-vm}"

IMAGE="${IMAGE:-}"                      # the artifact; auto-discovered if empty
BASE_IMAGE="${BASE_IMAGE:-$VM_WORK/cache/debian-13-generic-amd64.qcow2}"

MEM="${MEM:-2G}"
CPUS="${CPUS:-2}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
ACPI_TIMEOUT="${ACPI_TIMEOUT:-60}"
GROWN_SIZE="${GROWN_SIZE:-32G}"

# Base of a 5-port block. Every run derives its own SSH port from this and its
# monitor port from THAT (+1000), exactly as vm.sh does: one knob to keep
# distinct per concurrent agent, and the monitor follows by construction rather
# than being a third thing to get right.
BASE_PORT="${BASE_PORT:-2322}"

# The operator key that the artifact ships in johns's authorized_keys. T3 logs
# in with this. Overridable, because the key that ships is a property of the
# image, not of this script.
SHIP_USER="${SHIP_USER:-johns}"
SHIP_KEY="${SHIP_KEY:-$HOME/.ssh/id_ed25519}"

# Firmware for the UEFI runs. Sourced from the HOST package, never vendored:
# the repo's pinned OVMF_CODE.4m.fd is a different build from this host's, so
# pinning CODE while sourcing VARS from the host would be inconsistent. The
# decision recorded on the task is "vendor neither, preflight both".
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

# Synthetic DMI so hostname derivation is DISCRIMINATING instead of a skip.
# switch-firstboot builds mlnx-<sanitized product_name>-<last 8 of serial>;
# with a generic q35 DMI it would fall back to machine-id and prove only that
# the code ran. These values make the expected name exact and computable.
DMI_VENDOR="${DMI_VENDOR:-Mellanox}"
DMI_PRODUCT="${DMI_PRODUCT:-MSN2410-BB2FC}"
DMI_SERIAL="${DMI_SERIAL:-BT0001TEST}"
# 🔴 THE BOARD-SERIAL RUNG, exercised for real by the fifth run. switch-firstboot
# falls back from DMI product_serial to DMI board_serial before it falls back to
# machine-id, because a machine whose PRODUCT serial is a placeholder can still
# have a valid BASEBOARD serial -- observed on Arch hardware. qemu can drive both
# fields (-smbios type=1,serial= and type=2,serial=), so the rung is testable
# end to end instead of being a code path nothing ever takes.
DMI_BOARD_SERIAL="${DMI_BOARD_SERIAL:-MB0002TEST}"
# What a machine with no system serial actually reports. usable_serial() rejects
# it by pattern, which is what makes the board_serial rung reachable.
DMI_SERIAL_PLACEHOLDER="${DMI_SERIAL_PLACEHOLDER:-Not Specified}"

INSPECT_KEY="$WORK/inspect_key"         # throwaway, inspector VM only

# ---------------------------------------------------------------- result model

n_pass=0; n_fail=0; n_skip=0; n_weak=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; n_pass=$((n_pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; n_fail=$((n_fail + 1)); }
# 🔴 Every SKIP carries a reason. An unexplained skip is indistinguishable from
# a check somebody forgot to write.
skip() { printf '  \033[33mSKIP\033[0m %s\n         reason: %s\n' "$1" "$2"; n_skip=$((n_skip + 1)); }
# A check that RAN and could not have failed. Reported as its own state so it
# is never counted as evidence. $2 is NON-DISCRIMINATING or NON-REPRESENTATIVE.
weak() { printf '  \033[35m%s\033[0m %s\n         reason: %s\n' "$2" "$1" "$3"; n_weak=$((n_weak + 1)); }
inf()  { printf '  \033[36mNOTE\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null || die "missing build-host dependency: $1"; }

# Assert a plain boolean, with a message. Used by the host-side tiers; the
# inspector payload has its own emitter because it runs in another machine.
assert() { # $1 = 0/1 rc, $2 = description
	if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi
}

# ---------------------------------------------------------------- run scoping
#
# Every run -- the inspector and each of the four boots -- gets its own
# directory, pidfile, serial log, ssh port and monitor port. Nothing is shared,
# so a BIOS run cannot read a UEFI run's serial log and conclude anything.

RUN_TAG=""; RUN_DIR=""; RUN_PIDFILE=""; RUN_SERIAL=""; RUN_SSH=0; RUN_MON=0
# The hostname THIS run must produce, computed from the SMBIOS it was given.
# Per-run rather than global because the board-serial run is given different
# DMI and must therefore expect a different name -- a single global here would
# make that run assert the other runs' expectation and pass without meaning it.
RUN_WANT_HOST=""

# 🔴 MIRRORS switch-firstboot's derivation, including the inner printf. Without
# it, `sanitize | tail -c 8` counts sed's trailing NEWLINE as one of the eight
# bytes and yields SEVEN characters -- the harness and the script agreed on the
# wrong answer, so the assertion passed while both were off by one against the
# documented "last 8". Fixed in both places on 2026-08-04; they must move
# together or this check silently stops discriminating.
sanitize_dmi() { printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' \
	| sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'; }
want_hostname() { # $1 = DMI product, $2 = the serial the script will settle on
	printf 'mlnx-%s-%s' "$(sanitize_dmi "$1")" \
		"$(printf '%s' "$(sanitize_dmi "$2")" | tail -c 8)"
}

run_scope() { # $1 = tag, $2 = port index
	RUN_TAG="$1"
	RUN_DIR="$WORK/$RUN_TAG"
	RUN_PIDFILE="$RUN_DIR/qemu.pid"
	RUN_SERIAL="$RUN_DIR/serial.log"
	RUN_SSH=$((BASE_PORT + $2))
	RUN_MON=$((RUN_SSH + 1000))
	mkdir -p "$RUN_DIR"
}

# 🔴 Liveness is read from the PIDFILE, never from a process name. Neither
# `pgrep -f` nor `pkill -f` appears anywhere in this file: both match the full
# command line of the shell that invokes them. `pgrep -f` reported a VM as
# running when it had already exited (2026-08-02) and a generated
# `pkill -f qemu-system` destroyed the build VM outright (2026-08-03).
run_alive() {
	[ -r "$RUN_PIDFILE" ] || return 1
	kill -0 "$(cat "$RUN_PIDFILE")" 2>/dev/null
}

ssh_opts() { # $1 = key, $2 = port
	printf '%s\n' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ConnectTimeout=5 -i "$1" -p "$2"
}

ssh_run() { # $1 = key, $2 = port, $3 = user, rest = command
	local key="$1" port="$2" user="$3"; shift 3
	local -a o; mapfile -t o < <(ssh_opts "$key" "$port")
	ssh "${o[@]}" "$user@127.0.0.1" "$@"
}

wait_boot() { # $1 = key, $2 = user, $3 = what
	local key="$1" user="$2" what="$3" waited=0
	info "waiting for $what on port $RUN_SSH (timeout ${BOOT_TIMEOUT}s)"
	until ssh_run "$key" "$RUN_SSH" "$user" true 2>/dev/null; do
		run_alive || { tail -30 "$RUN_SERIAL" >&2; return 1; }
		if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
			tail -30 "$RUN_SERIAL" >&2
			return 1
		fi
		sleep 3; waited=$((waited + 3))
	done
	info "$what up after ${waited}s"
	return 0
}

# Read one QMP reply, skipping asynchronous events. On rejection the reply is
# KEPT rather than discarded: qemu's own `desc` is the whole diagnosis, and a
# ladder that reports only "QMP failed" costs a debugging round per mistake.
QMP_ERR=""
qmp_reply() {
	local line n=0
	while [ "$n" -lt 20 ]; do
		n=$((n + 1))
		IFS= read -r -t 5 line <&3 || { QMP_ERR="no reply within 5s"; return 1; }
		case "$line" in
		*'"event"'*)  continue ;;
		*'"return"'*) return 0 ;;
		*'"error"'*)  QMP_ERR="$line"; return 1 ;;
		esac
	done
	QMP_ERR="no return after 20 lines"
	return 1
}

# Send one or more QMP commands, in order, on a single connection. 0 only if
# every one was acknowledged.
#
# 🔴 The redirection is scoped to a BRACE GROUP, never attached to `exec`.
# `exec` with only redirections applies them to the SHELL, permanently: a bare
# `exec 3<>... 2>/dev/null` sends this script's stderr to /dev/null for the
# rest of the run, silencing later warnings. That is this project's signature
# bug class and it has already appeared once inside a ladder written to make
# failures loud (vm.sh, iter 17).
qmp_exec() { # $@ = JSON command strings
	local greeting c
	{ exec 3<>"/dev/tcp/127.0.0.1/$RUN_MON"; } 2>/dev/null || return 1
	IFS= read -r -t 5 greeting <&3 || { exec 3>&-; return 1; }
	case "$greeting" in *'"QMP"'*) ;; *) exec 3>&-; return 1 ;; esac
	printf '{"execute":"qmp_capabilities"}\n' >&3
	qmp_reply || { exec 3>&-; return 1; }
	for c in "$@"; do
		printf '%s\n' "$c" >&3
		qmp_reply || { warn "QMP rejected a command: $QMP_ERR"; exec 3>&-; return 1; }
	done
	exec 3>&-
}

# Press the virtual ACPI power button.
qmp_powerdown() { qmp_exec '{"execute":"system_powerdown"}'; }

# Attach the artifact to a RUNNING guest, read-only.
#
# 🔴 THE ARTIFACT IS HOT-PLUGGED, NEVER PRESENT AT BOOT, AND THAT IS A BUG FIX,
# NOT A STYLE CHOICE. Debian's cloud images ship FIXED partition UUIDs, and this
# artifact is a descendant of the very image the inspector boots -- measured
# 2026-08-04, all three partition UUIDs are byte-identical, root included
# (8DC1F76B-78C4-43CA-9FB0-027BEF73886E on both). With both disks attached at
# boot, the base's own `root=PARTUUID=...` is AMBIGUOUS: the first attempt
# booted the base's GRUB and mounted the ARTIFACT's root, which is a harness
# that inspects the wrong filesystem while reporting confidently about it.
# Hot-plugging after userspace is up means root= has already been resolved, so
# the duplicate is inert. The payload additionally refuses to proceed if the
# device it was handed is the inspector's own root.
qmp_attach_artifact() { # $1 = image path
	qmp_exec \
		"{\"execute\":\"blockdev-add\",\"arguments\":{\"node-name\":\"artnode\",\"driver\":\"raw\",\"read-only\":true,\"file\":{\"driver\":\"file\",\"filename\":\"$1\",\"read-only\":true}}}" \
		'{"execute":"device_add","arguments":{"driver":"virtio-blk-pci","drive":"artnode","id":"artdev","bus":"hp0"}}'
}
# ⚠ The device MUST land on a pcie-root-port, not on pcie.0. q35's root complex
# refuses hotplug outright -- "Bus 'pcie.0' does not support hotplugging" -- so
# inspector_up boots one empty root port for the artifact to arrive on. Keeping
# q35 matters: it is the machine type vm.sh builds on, and an inspector on a
# different machine type would be inspecting under different firmware.

wait_down() {
	local limit="$1" waited=0
	while run_alive && [ "$waited" -lt "$limit" ]; do
		sleep 2; waited=$((waited + 2))
	done
	! run_alive
}

# Three rungs, same ladder shape as vm.sh: ssh, ACPI over QMP, then an
# ANNOUNCED force-kill. The announcement matters -- a silent "down" is what let
# a killed guest read as clean on 2026-08-03.
run_down() { # $1 = key (may be empty), $2 = user
	local key="${1:-}" user="${2:-}"
	run_alive || return 0
	if [ -n "$key" ] && [ -r "$key" ] && ssh_run "$key" "$RUN_SSH" "$user" true 2>/dev/null; then
		ssh_run "$key" "$RUN_SSH" "$user" 'sudo systemctl poweroff' 2>/dev/null || true
		if wait_down 30; then info "$RUN_TAG: down via ssh"; return 0; fi
	fi
	if qmp_powerdown; then
		if wait_down "$ACPI_TIMEOUT"; then info "$RUN_TAG: down via ACPI"; return 0; fi
	fi
	warn "$RUN_TAG: FORCING -- this is a power cut, not a shutdown; the overlay is discarded so no artifact state is at risk"
	if [ -r "$RUN_PIDFILE" ]; then kill "$(cat "$RUN_PIDFILE")" 2>/dev/null || true; fi
	wait_down 20
	return 0
}

ALL_SCOPES=()
cleanup_all() {
	local s
	for s in "${ALL_SCOPES[@]:-}"; do
		[ -n "$s" ] || continue
		RUN_TAG="${s%%:*}"; RUN_DIR="$WORK/$RUN_TAG"
		RUN_PIDFILE="$RUN_DIR/qemu.pid"; RUN_MON="${s##*:}"
		if run_alive; then
			warn "cleanup: $RUN_TAG still running -- powering down"
			run_down "" ""
		fi
	done
	return 0
}

# ---------------------------------------------------------------- discovery

discover_image() {
	[ -n "$IMAGE" ] && return 0
	local c
	c=$(ls -1t "$VM_WORK"/mlnx-sw-os-*.raw 2>/dev/null | head -1)
	[ -n "$c" ] || die "no artifact found in $VM_WORK -- pass IMAGE=<path>"
	IMAGE="$c"
	return 0
}

# ---------------------------------------------------------------- T1 inspector

write_inspect_seed() {
	need xorrisofs
	local d="$WORK/inspect-seed"
	rm -rf "$d"; mkdir -p "$d"
	if [ ! -r "$INSPECT_KEY.pub" ]; then
		info "generating a throwaway inspector key (never reaches the artifact)"
		ssh-keygen -t ed25519 -N '' -C 'mlnx-sw-os boot-test inspector' -f "$INSPECT_KEY" >/dev/null
	fi
	cat > "$d/user-data" <<-EOF
	#cloud-config
	users:
	  - name: inspector
	    sudo: 'ALL=(ALL) NOPASSWD:ALL'
	    shell: /bin/bash
	    lock_passwd: true
	    ssh_authorized_keys:
	      - $(cat "$INSPECT_KEY.pub")
	ssh_pwauth: false
	EOF
	cat > "$d/meta-data" <<-EOF
	instance-id: mlnx-sw-os-inspect
	local-hostname: inspector
	EOF
	xorrisofs -quiet -output "$RUN_DIR/seed.iso" -volid cidata -joliet -rock \
		"$d/user-data" "$d/meta-data"
}

inspector_up() {
	need qemu-system-x86_64; need qemu-img; need ssh; need ssh-keygen
	[ -r "$BASE_IMAGE" ] || die "no base image at $BASE_IMAGE -- run: scripts/vm.sh fetch"

	# A COPY of the pristine base, never the download itself.
	cp --reflink=auto "$BASE_IMAGE" "$RUN_DIR/inspect.qcow2"
	write_inspect_seed

	rm -f "$RUN_SERIAL"
	info "booting the inspector with NO artifact attached (duplicate-PARTUUID guard)"
	qemu-system-x86_64 \
		-enable-kvm -machine q35 -cpu host \
		-m "$MEM" -smp "$CPUS" \
		-drive file="$RUN_DIR/inspect.qcow2",if=none,id=base,format=qcow2 \
		-device virtio-blk-pci,drive=base,bootindex=0 \
		-device pcie-root-port,id=hp0,bus=pcie.0 \
		-drive file="$RUN_DIR/seed.iso",media=cdrom,format=raw \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$RUN_SSH"-:22 \
		-device virtio-net-pci,netdev=n0 \
		-display none -serial file:"$RUN_SERIAL" \
		-qmp tcp:127.0.0.1:"$RUN_MON",server=on,wait=off \
		-pidfile "$RUN_PIDFILE" -daemonize \
		|| die "qemu failed to start the inspector"

	wait_boot "$INSPECT_KEY" inspector "inspector ssh" \
		|| die "inspector never came up -- see $RUN_SERIAL"

	# 🔴 read-only at the QEMU layer is load-bearing. The payload runs as root
	# over a filesystem we are asserting about; without it a journal replay or
	# an fsck would mutate the very bytes under test. qemu refusing the write is
	# a stronger guarantee than remembering to pass `-o ro` to mount, and both
	# are used.
	info "hot-plugging the artifact read-only"
	qmp_attach_artifact "$IMAGE" || die "could not hot-plug the artifact over QMP"

	local waited=0
	until ssh_run "$INSPECT_KEY" "$RUN_SSH" inspector "test -b /dev/vdb1" 2>/dev/null; do
		[ "$waited" -lt 60 ] || die "the artifact never appeared as /dev/vdb1 in the inspector"
		sleep 2; waited=$((waited + 2))
	done
	info "artifact visible in the inspector after ${waited}s"
}

# The offline assertion payload. Runs INSIDE the inspector, as root, against
# the mounted artifact. It emits one `R<TAB>STATUS<TAB>text[<TAB>reason]` line
# per assertion and a terminator carrying its own count.
#
# 🔴 IT DOES NOT `set -e`, for the same reason this file does not, and it MUST
# print its terminator. The host refuses to tally a run whose terminator is
# missing or whose count disagrees -- otherwise a payload that died halfway
# would report a clean subset, which is precisely "a check that silently never
# runs" with a network in the middle of it.
inspect_payload() {
	cat <<'PAYLOAD'
set -u
ART="${ART_DEV:-/dev/vdb}"
N=0
R() { N=$((N + 1)); printf 'R\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
# 🔴 A NOTE IS NOT AN ASSERTION, so it must not advance N. It did on the first
# run, and the host's count guard caught the discrepancy exactly as designed
# (claimed 117, received 116) -- the guard worked; the emitter was wrong.
NT() { printf 'R\tNOTE\t%s\t\n' "$1"; }
P() { R PASS "$1"; }
F() { R FAIL "$1"; }
S() { R SKIP "$1" "$2"; }
W() { R "$2" "$1" "$3"; }
yn() { if [ "$1" -eq 0 ]; then P "$2"; else F "$2"; fi; }

M=/mnt/art
E=/mnt/esp
mkdir -p "$M" "$E"

# 🔴 REFUSE TO INSPECT OUR OWN ROOT. The artifact shares every partition UUID
# with the base image it was built from, so a harness that got the device wrong
# would mount the INSPECTOR's filesystem and report on it with full confidence.
# That is not hypothetical: the first run of this tier did exactly that. Both
# halves are checked -- the device name, and then the mounted filesystem's
# device number against /.
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
case "$ROOTSRC" in
"$ART"*) F "the artifact device ($ART) is not the inspector's own root ($ROOTSRC)"; printf 'R\tEND\t%s\t\n' "$N"; exit 0 ;;
*) P "the artifact device ($ART) is not the inspector's own root ($ROOTSRC)" ;;
esac

mount -o ro "${ART}1" "$M"  2>/dev/null || { R FAIL "artifact root partition mounts read-only"; printf 'R\tEND\t%s\t\n' "$N"; exit 0; }
P "artifact root partition mounts read-only"
if [ "$(stat -c %d / 2>/dev/null)" = "$(stat -c %d "$M" 2>/dev/null)" ]; then
  F "the mounted artifact is a DIFFERENT filesystem from the inspector's root"
  printf 'R\tEND\t%s\t\n' "$N"; exit 0
fi
P "the mounted artifact is a DIFFERENT filesystem from the inspector's root"
if mount -o ro "${ART}15" "$E" 2>/dev/null; then P "artifact ESP mounts read-only"; ESP=1
else F "artifact ESP mounts read-only"; ESP=0; fi

have() { [ -e "$M$1" ]; }
gone() { [ ! -e "$M$1" ]; }
inst() { # package installed?
  awk -v p="$1" '$1=="Package:"&&$2==p{f=1} f&&$1=="Status:"{print $4; exit}' "$M/var/lib/dpkg/status" 2>/dev/null | grep -qx installed
}

# ------------------------------------------------------------ identity
grep -q '^builder:' "$M/etc/passwd" 2>/dev/null && F "no builder user survives in /etc/passwd" || P "no builder user survives in /etc/passwd"
gone /home/builder && P "/home/builder is gone" || F "/home/builder is gone"
grep -q "^${SHIP_USER:-johns}:" "$M/etc/passwd" 2>/dev/null && P "the shipped administrator account exists" || F "the shipped administrator account exists"
[ -s "$M/home/${SHIP_USER:-johns}/.ssh/authorized_keys" ] && P "administrator authorized_keys is non-empty" || F "administrator authorized_keys is non-empty"
[ -s "$M/root/.ssh/authorized_keys" ] && F "root authorized_keys is empty (no root login ships)" || P "root authorized_keys is empty (no root login ships)"
# ⚠ THE RATIONALE HERE WAS FALSE and is corrected. Truncating machine-id does
# NOT make ConditionFirstBoot fire: that directive tests /run/systemd/first-boot,
# PID 1 never created it, and the 2026-08-04 artifact shipped with a zero-length
# machine-id AND a skipped switch-firstboot. The truncation is still right, for
# the reason that was always real -- per-machine uniqueness.
[ -f "$M/etc/machine-id" ] && [ ! -s "$M/etc/machine-id" ] && P "/etc/machine-id is zero-length (systemd mints a fresh one per machine)" || F "/etc/machine-id is zero-length (systemd mints a fresh one per machine)"
[ -s "$M/etc/hostname" ] && F "/etc/hostname is empty (DMI derivation applies)" || P "/etc/hostname is empty (DMI derivation applies)"
ls "$M"/etc/ssh/ssh_host_*_key >/dev/null 2>&1 && F "SSH host keys were removed by generalize" || P "SSH host keys were removed by generalize"

# 🔴 THE STAMP MUST NOT SHIP. switch-firstboot.service is conditioned on this
# file's ABSENCE, and the build guest reboots once between `prepare` and
# `verify` -- which FIRES the unit and writes the stamp inside the image being
# built. stage-generalize's do_finish removes it; if that ever regresses, the
# artifact boots with identity setup already marked done: no hostname, no host
# keys, no sshd, exactly the defect the stamp replaced. This assertion is the
# only thing standing between that regression and a fleet-wide re-image.
gone /var/lib/switch-firstboot.stamp \
  && P "no first-boot stamp ships (else switch-firstboot is skipped on the artifact's first boot)" \
  || F "a first-boot stamp SHIPS in the artifact -- switch-firstboot will be skipped and this image is unreachable"
# The unit must no longer carry the directive that failed. Checked on the
# INSTALLED unit, not on the repo asset: what ships is what matters.
grep -q 'ConditionFirstBoot' "$M/etc/systemd/system/switch-firstboot.service" 2>/dev/null \
  && F "the shipped switch-firstboot.service carries no ConditionFirstBoot (it evaluates false here)" \
  || P "the shipped switch-firstboot.service carries no ConditionFirstBoot (it evaluates false here)"
grep -qx 'ConditionPathExists=!/var/lib/switch-firstboot.stamp' "$M/etc/systemd/system/switch-firstboot.service" 2>/dev/null \
  && P "the shipped switch-firstboot.service is conditioned on the stamp's absence" \
  || F "the shipped switch-firstboot.service is not conditioned on the stamp"
# The SECOND, INDEPENDENT trigger for remote access. Its absence is invisible
# until the day switch-firstboot is skipped again -- which is the day it matters.
[ -x "$M/usr/local/sbin/switch-sshd-keygen" ] \
  && P "switch-sshd-keygen is installed and executable (the redundant path to a reachable switch)" \
  || F "switch-sshd-keygen is installed and executable"
grep -qx 'ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key' "$M/etc/systemd/system/switch-sshd-keygen.service" 2>/dev/null \
  && P "switch-sshd-keygen.service is conditioned on the KEY's absence, so it retries every boot" \
  || F "switch-sshd-keygen.service is not conditioned on the host key's absence"

# ------------------------------------------------------------ kernel + mlxsw (BUILD GATE)
#
# 🔴 RULING REVERSED BY THE OPERATOR, 2026-08-04. The earlier ruling was "FAIL
# on the presence of any second kernel at all". It is withdrawn: a kernel
# WITHOUT mlxsw is a deliberate RESCUE KERNEL, kept on purpose. Its value is
# precisely that it lacks the driver -- it is the kernel that still boots when a
# DKMS rebuild goes wrong or the ASIC itself wedges, which is exactly when you
# need a shell to inspect a failed boot. Debian's own fail-safe-kernel
# convention did not arise by accident.
#
# So the gate is no longer about COUNT. It is about SELECTION: a rescue kernel
# is safe only while nothing can reach it automatically.
GC="$M/boot/grub/grub.cfg"
DEFK=$(awk '/^menuentry /{f=1} f&&/^[[:space:]]*linux[[:space:]]/{print; exit}' "$GC" 2>/dev/null | sed -n 's/.*vmlinuz-\([^ ]*\).*/\1/p')
LKG=$(sed -n 's/^KERNEL=//p' "$M/var/lib/mlxsw-fallback/last-known-good" 2>/dev/null)
has_mlxsw() { # $1 = kernel version. 🔴 GLOB *.ko* -- trixie ships .ko.xz and a
              # bare *.ko glob finds ZERO while printing green.
  [ "$(ls -1 "$M/lib/modules/$1/updates/dkms/"mlxsw*.ko* 2>/dev/null | wc -l)" -gt 0 ]
}

WITH=""; WITHOUT=""
for k in $(ls -1 "$M/lib/modules" 2>/dev/null); do
  if has_mlxsw "$k"; then WITH="$WITH $k"; else WITHOUT="$WITHOUT $k"; fi
done
[ -n "$WITH" ] && P "at least one shipped kernel carries mlxsw ($WITH )" \
               || F "at least one shipped kernel carries mlxsw -- NONE do"
[ -n "$WITHOUT" ] && NT "rescue kernel(s) present, by design, reachable only by hand:$WITHOUT" \
                  || NT "no rescue kernel ships (permitted, not required)"

# 1. What boots UNATTENDED must have the driver.
if [ -z "$DEFK" ]; then F "the default GRUB entry names a kernel"
elif has_mlxsw "$DEFK"; then P "the DEFAULT boot kernel carries mlxsw ($DEFK)"
else F "the DEFAULT boot kernel carries mlxsw -- $DEFK has none, so an unattended boot yields zero ports"; fi

# 2. What the R4 ladder can ARM must have the driver. A rescue kernel reachable
#    by grub-reboot is not a rescue kernel, it is a silent portless boot.
if [ -z "$LKG" ]; then F "last-known-good names a kernel"
elif has_mlxsw "$LKG"; then P "last-known-good names a kernel WITH mlxsw ($LKG)"
else F "last-known-good names a kernel WITH mlxsw -- it names $LKG, which has none: the fallback ladder can arm a portless boot"; fi

# 3. The rescue kernel must not be the default under any spelling.
for k in $WITHOUT; do
  [ "$k" = "$DEFK" ] && F "rescue kernel $k is not the default" || P "rescue kernel $k is not the default"
  [ "$k" = "$LKG" ]  && F "rescue kernel $k is not last-known-good" || P "rescue kernel $k is not last-known-good"
  # 🔴 unattended-upgrades ships ENABLED and its Remove-Unused-Kernel-Packages
  # default is true. apt protects only the running and previous kernels, so the
  # rescue kernel survives today and is silently autoremoved at the SECOND
  # kernel upgrade -- unless it is marked manually installed, which takes it out
  # of the autoremove set permanently.
  if grep -q "^Package: linux-image-$k\$" "$M/var/lib/apt/extended_states" 2>/dev/null; then
    if awk -v k="linux-image-$k" '$1=="Package:"&&$2==k{f=1} f&&$1=="Auto-Installed:"{print $2; exit}' "$M/var/lib/apt/extended_states" | grep -qx 1; then
      F "rescue kernel $k is marked MANUALLY installed (else unattended-upgrades autoremoves it at the 2nd kernel upgrade)"
    else P "rescue kernel $k is marked MANUALLY installed"; fi
  else P "rescue kernel $k is marked MANUALLY installed"; fi
done
KVER="${DEFK:-$(ls -1 "$M/lib/modules" 2>/dev/null | sort -V | tail -1)}"
for m in mlxsw_core mlxsw_pci mlxsw_spectrum mlxsw_i2c mlxsw_minimal objagg parman; do
  ls "$M/lib/modules/$KVER/updates/dkms/$m".ko* >/dev/null 2>&1 && P "module $m present for $KVER" || F "module $m present for $KVER"
done
for p in dkms linux-headers-amd64 gcc build-essential systemd-repart grub-cloud-amd64; do
  inst "$p" && P "package $p installed" || F "package $p installed"
done
grep -q "^KERNEL=$KVER\$" "$M/var/lib/mlxsw-fallback/last-known-good" 2>/dev/null \
  && P "last-known-good is seeded with the shipped kernel ($KVER)" \
  || F "last-known-good is seeded with the shipped kernel ($KVER)"
[ -s "$M/boot/grub/grubenv" ] && P "/boot/grub/grubenv exists and is non-empty" || F "/boot/grub/grubenv exists and is non-empty"

# ------------------------------------------------------------ growth
have /etc/repart.d/50-root.conf && grep -q '^Type=root' "$M/etc/repart.d/50-root.conf" \
  && P "/etc/repart.d/50-root.conf declares Type=root" || F "/etc/repart.d/50-root.conf declares Type=root"
[ -x "$M/usr/local/sbin/switch-growroot" ] && P "switch-growroot wrapper is installed and executable" || F "switch-growroot wrapper is installed and executable"
grep -qE '[ ,]x-systemd\.growfs' "$M/etc/fstab" && P "root fstab entry carries x-systemd.growfs" || F "root fstab entry carries x-systemd.growfs"
grep -qx 'RESUME=none' "$M/etc/initramfs-tools/conf.d/resume" 2>/dev/null && P "/etc/initramfs-tools/conf.d/resume is none" || F "/etc/initramfs-tools/conf.d/resume is none"
# The shipped systemd-repart.service must be MASKED, not disabled: it is
# static, so `disable` is a no-op on it.
if [ -L "$M/etc/systemd/system/systemd-repart.service" ] && [ "$(readlink "$M/etc/systemd/system/systemd-repart.service")" = /dev/null ]; then
  P "shipped systemd-repart.service is masked to /dev/null"
else F "shipped systemd-repart.service is masked to /dev/null"; fi
for u in switch-growroot.service switch-firstboot.service switch-sshd-keygen.service switch-swapfile.service mlxsw-modules-present.service ssh.service; do
  st=$(systemctl is-enabled --root="$M" "$u" 2>/dev/null)
  [ "$st" = enabled ] && P "unit $u is enabled" || F "unit $u is enabled (got '${st:-missing}')"
done

# ------------------------------------------------------------ cloud/netplan purge
for p in cloud-init netplan.io netplan-generator python3-netplan libnetplan1 cloud-initramfs-growroot cloud-guest-utils fancontrol ipmiutil; do
  inst "$p" && F "package $p is absent" || P "package $p is absent"
done
for d in /etc/netplan /etc/cloud /var/lib/cloud /usr/lib/systemd/system-generators/netplan /opt/packages; do
  gone "$d" && P "$d is absent" || F "$d is absent"
done
# The generator is what actually renders; the package name alone is not evidence.
ls "$M"/usr/lib/systemd/system-generators/*netplan* >/dev/null 2>&1 && F "no netplan generator of any name ships" || P "no netplan generator of any name ships"

# ------------------------------------------------------------ apt sources / stray debs
if grep -rqs 'file:/opt/packages' "$M/etc/apt/sources.list" "$M/etc/apt/sources.list.d/" 2>/dev/null; then
  F "no file:/opt/packages apt source (checked .list AND deb822 .sources)"
else P "no file:/opt/packages apt source (checked .list AND deb822 .sources)"; fi
SD=$(find "$M" -xdev -name '*.deb' 2>/dev/null | head -5)
[ -z "$SD" ] && P "no stray .deb anywhere in the image" || F "no stray .deb anywhere in the image -- found: $(printf '%s' "$SD" | tr '\n' ' ')"

# ------------------------------------------------------------ networkd config
ND="$M/etc/systemd/network"
NF=$(ls -1 "$ND" 2>/dev/null | wc -l)
[ "$NF" -eq 6 ] && P "/etc/systemd/network holds exactly the 6 shipped units" || F "/etc/systemd/network holds exactly the 6 shipped units (found $NF)"
if grep -rq 'MACAddress=' "$ND" 2>/dev/null; then F "no MACAddress= anywhere in /etc/systemd/network"
else P "no MACAddress= anywhere in /etc/systemd/network"; fi
for f in "$ND"/*.network; do
  b=$(basename "$f")
  [ "$(grep -c '^\[Match\]' "$f")" -eq 1 ] && P "$b has exactly one [Match]" || F "$b has exactly one [Match]"
  [ "$(grep -c '^\[Network\]' "$f")" -eq 1 ] && P "$b has exactly one [Network]" || F "$b has exactly one [Network]"
done

# --- mgmt (O1). The v6 asymmetry with data is DELIBERATE; do not flag it.
G="$ND/22-mgmt-bond.network"
grep -qx 'IPv6AcceptRA=true' "$G" && P "mgmt: IPv6AcceptRA=true" || F "mgmt: IPv6AcceptRA=true"
grep -q 'IPv6SendRA=' "$G" && F "mgmt: no IPv6SendRA= (never advertise as a router)" || P "mgmt: no IPv6SendRA= (never advertise as a router)"
grep -qE '(DHCPv6PrefixDelegation|DHCPPrefixDelegation)=' "$G" && F "mgmt: no prefix delegation (both spellings)" || P "mgmt: no prefix delegation (both spellings)"
grep -q '^\[DHCPv6\]' "$G" && F "mgmt: no [DHCPv6] section" || P "mgmt: no [DHCPv6] section"
grep -q 'RouteMetric=' "$G" && F "mgmt: no RouteMetric= (D1 removes eligibility, it does not rank)" || P "mgmt: no RouteMetric= (D1 removes eligibility, it does not rank)"
grep -qx 'MTUBytes=1500' "$G" && P "mgmt: MTUBytes=1500 written explicitly" || F "mgmt: MTUBytes=1500 written explicitly"

# --- data (IPv4-only ruling)
D="$ND/32-data.network"
grep -qx 'DHCP=ipv4' "$D" && P "data: DHCP=ipv4 (not yes)" || F "data: DHCP=ipv4 (not yes)"
grep -qx 'IPv6AcceptRA=false' "$D" && P "data: IPv6AcceptRA=false" || F "data: IPv6AcceptRA=false"
grep -qx 'LinkLocalAddressing=ipv4' "$D" && P "data: LinkLocalAddressing=ipv4" || F "data: LinkLocalAddressing=ipv4"
grep -q 'IPv6SendRA=' "$D" && F "data: no IPv6SendRA= (never advertise onto a ~35-host segment)" || P "data: no IPv6SendRA= (never advertise onto a ~35-host segment)"
grep -qE '(DHCPv6PrefixDelegation|DHCPPrefixDelegation)=' "$D" && F "data: no prefix delegation (both spellings)" || P "data: no prefix delegation (both spellings)"
grep -q '^\[DHCPv6\]' "$D" && F "data: no [DHCPv6] section" || P "data: no [DHCPv6] section"
# 🔴 Under [DHCPv4], never [DHCP]: `[DHCP] UseGateway=` is silently dropped.
S4=$(awk '/^\[DHCPv4\]/{f=1;next} /^\[/{f=0} f' "$D")
printf '%s\n' "$S4" | grep -qx 'UseRoutes=false'  && P "data: [DHCPv4] UseRoutes=false"  || F "data: [DHCPv4] UseRoutes=false"
printf '%s\n' "$S4" | grep -qx 'UseGateway=false' && P "data: [DHCPv4] UseGateway=false" || F "data: [DHCPv4] UseGateway=false"
grep -qx 'MTUBytes=1500' "$D" && P "data: MTUBytes=1500 written explicitly" || F "data: MTUBytes=1500 written explicitly"
grep -qx 'MTUBytes=9000' "$ND/34-data.network" && P "swp*: MTUBytes=9000 (transit ports, the one place jumbo belongs)" || F "swp*: MTUBytes=9000"
grep -qx 'RequiredForOnline=no' "$ND/34-data.network" && P "swp*: RequiredForOnline=no (dark ports must not gate boot)" || F "swp*: RequiredForOnline=no"
grep -qx 'RequiredForOnline=no' "$D" && P "data: RequiredForOnline=no" || F "data: RequiredForOnline=no"
grep -q 'RequiredForOnline=' "$G" && F "mgmt: no RequiredForOnline= (mgmt is the plane that must be up)" || P "mgmt: no RequiredForOnline= (mgmt is the plane that must be up)"
# 🔴 STRIP COMMENTS FIRST and match the KEY, not the word. A bare
# `grep -i primary` matched 20-mgmt-bond.netdev's own comment explaining that
# the bond deliberately ships WITHOUT a primary -- the guard failed on the
# documentation of the very property it was checking for.
sed 's/#.*//' "$ND/20-mgmt-bond.netdev" | grep -qE '^[[:space:]]*(Primary|PrimarySlave|PrimaryReselectPolicy)=' \
  && F "mgmt bond ships no primary (D7/D2)" || P "mgmt bond ships no primary (D7/D2)"
grep -q 'phys_port_name' "$M/etc/udev/rules.d/10-local.rules" 2>/dev/null && P "swp* udev rule is installed" || F "swp* udev rule is installed"

# ------------------------------------------------------------ thermal
grep -qx 'coretemp' "$M/etc/modules-load.d/mlxsw-sensors.conf" 2>/dev/null && P "coretemp queued in /etc/modules-load.d/mlxsw-sensors.conf" || F "coretemp queued in /etc/modules-load.d/mlxsw-sensors.conf"
grep -qx 'jc42'     "$M/etc/modules-load.d/mlxsw-sensors.conf" 2>/dev/null && P "jc42 queued in /etc/modules-load.d/mlxsw-sensors.conf" || F "jc42 queued in /etc/modules-load.d/mlxsw-sensors.conf"
# Two authorities for one outcome is the defect; /etc/modules feeds the same
# unit via the modules.conf symlink, so it must stay empty.
if [ -s "$M/etc/modules" ] && grep -qvE '^\s*(#|$)' "$M/etc/modules"; then
  F "/etc/modules carries no module names (modules-load.d is the sole authority)"
else P "/etc/modules carries no module names (modules-load.d is the sole authority)"; fi

# ------------------------------------------------------------ GRUB drop-ins
GD="$M/etc/default/grub.d"
have /etc/default/grub.d/20_switch-cmdline.cfg && P "20_switch-cmdline.cfg ships" || F "20_switch-cmdline.cfg ships"
have /etc/default/grub.d/25_switch-boot-policy.cfg && P "25_switch-boot-policy.cfg ships" || F "25_switch-boot-policy.cfg ships"
gone /etc/default/grub.d/15_timeout.cfg && P "15_timeout.cfg is ABSENT (deleted, not overridden)" || F "15_timeout.cfg is ABSENT (deleted, not overridden)"
# The invariant is DISJOINTNESS BY VARIABLE, not prefix order.
for v in GRUB_CMDLINE_LINUX GRUB_TERMINAL GRUB_SERIAL_COMMAND GRUB_DEFAULT GRUB_TIMEOUT GRUB_TIMEOUT_STYLE; do
  c=$(grep -lE "^${v}=" "$GD"/*.cfg 2>/dev/null | wc -l)
  [ "$c" -eq 1 ] && P "GRUB variable $v is owned by exactly one drop-in" || F "GRUB variable $v is owned by exactly one drop-in (found $c)"
done

# ------------------------------------------------------------ generated grub.cfg
# 🔴 Assert the GENERATED cfg, never only the drop-in inputs -- that is the
# real defence against a future base drop-in sorting after ours.
GC="$M/boot/grub/grub.cfg"
if [ -r "$GC" ]; then
  DEFLINE=$(awk '/^menuentry /{f=1} f&&/^\t*linux\t/{print; exit}' "$GC")
  case "$DEFLINE" in
  *"vmlinuz-$KVER"*) P "default menuentry boots the shipped kernel ($KVER)" ;;
  *) F "default menuentry boots the shipped kernel -- got: $(printf '%s' "$DEFLINE" | sed 's/.*vmlinuz-\([^ ]*\).*/\1/')" ;;
  esac
  case "$DEFLINE" in *net.ifnames=0*) P "generated cmdline carries net.ifnames=0" ;; *) F "generated cmdline carries net.ifnames=0" ;; esac
  case "$DEFLINE" in *console=ttyS0,115200*) P "generated cmdline PRESERVED the base console= (drop-in appended, did not assign)" ;; *) F "generated cmdline PRESERVED the base console= (drop-in appended, did not assign)" ;; esac
  grep -q '^terminal_input .*serial' "$GC" && P "grub.cfg terminal_input includes serial (the fallback menu is steerable)" || F "grub.cfg terminal_input includes serial"
  grep -q 'timeout_style=menu' "$GC" && P "grub.cfg sets timeout_style=menu (without it the timeout is decorative)" || F "grub.cfg sets timeout_style=menu"
  # 🔴 ALLOW LEADING WHITESPACE and fail honestly. Debian emits `set timeout=`
  # INDENTED, inside the feature_timeout_style if/else, so a ^-anchored match
  # found nothing -- and the first draft then passed in BOTH branches, which is
  # a check that cannot fail. EVERY emitted timeout must qualify, not just one:
  # the else-branch value is the one that applies on a grub without the
  # timeout_style feature, and a decorative 0 there would be missed by head -1.
  T=$(sed -n 's/^[[:space:]]*set timeout=\([0-9][0-9]*\).*/\1/p' "$GC")
  if [ -z "$T" ]; then
    F "grub.cfg sets a boot timeout"
  else
    low=$(printf '%s\n' "$T" | sort -n | head -1)
    if [ "$low" -ge 5 ]; then P "grub.cfg timeout is >= 5 on every branch (values: $(printf '%s' "$T" | tr '\n' ' '))"
    else F "grub.cfg timeout is >= 5 on every branch (lowest is $low)"; fi
  fi
  grep -q 'load_env' "$GC" && P "grub.cfg calls load_env (the one-shot arming mechanism can work)" || F "grub.cfg calls load_env"
else F "/boot/grub/grub.cfg is readable"; fi

# ------------------------------------------------------------ ESP / AD-5
if [ "$ESP" = 1 ]; then
  [ -f "$E/EFI/BOOT/BOOTX64.EFI" ] && P "ESP carries EFI/BOOT/BOOTX64.EFI (blank-NVRAM firmware will find it)" || F "ESP carries EFI/BOOT/BOOTX64.EFI"
  # 🔴 AD-5's open question, answered rather than assumed: does the UEFI path
  # resolve $prefix to the SAME /boot/grub/grubenv the BIOS path uses?
  EG=$(ls "$E"/EFI/debian/grub.cfg 2>/dev/null | head -1)
  if [ -n "$EG" ]; then
    if grep -q 'configfile' "$EG" && grep -qE 'search|\$prefix|/boot/grub' "$EG"; then
      P "ESP grub.cfg chains to the root /boot/grub (UEFI and BIOS share one grubenv)"
      NT "ESP grub.cfg body: $(tr '\n' ' ' < "$EG" | cut -c1-200)"
    else F "ESP grub.cfg chains to the root /boot/grub"; fi
  else S "UEFI \$prefix resolves to /boot/grub" "no EFI/debian/grub.cfg on the ESP; determine from the UEFI boot run instead"; fi
  ls "$E"/EFI/debian/grubenv >/dev/null 2>&1 && F "no SECOND grubenv on the ESP (one arming mechanism, not two)" || P "no SECOND grubenv on the ESP (one arming mechanism, not two)"
else
  S "ESP contents" "the ESP did not mount"
fi

# ------------------------------------------------------------ hardware-only
S "front-panel port enumeration into the data bridge" "QEMU has no emulated Spectrum ASIC: mlxsw_pci binds nothing and zero swp* appear. Hardware only -- no VM work closes this."
S "swp* MTU is 9000 at runtime" "no swp* interface exists in QEMU; the shipped config value is asserted offline above"
S "10-local.rules udev priority beats 80-net-setup-link.rules" "requires a real mlxsw port to rename; not settleable in QEMU"
S "in-kernel MLXSW_CORE_THERMAL drives the fans" "needs real hardware and a scheduled production change on a live switch"
S "GRUB fallback ladder BEHAVIOUR (a failed boot actually rolls back)" "requires a deliberately broken kernel install; this run asserts the ladder is present and armable, never that it fires"

umount "$E" 2>/dev/null || true
umount "$M" 2>/dev/null || true
printf 'R\tEND\t%s\t\n' "$N"
PAYLOAD
}

tally_stream() { # stdin = the R-stream; returns 1 if the terminator is missing
	local status text reason tag saw_end=0 claimed=0 seen=0
	while IFS=$'\t' read -r tag status text reason; do
		[ "$tag" = R ] || continue
		case "$status" in
		END)  saw_end=1; claimed="$text" ;;
		PASS) ok "$text"; seen=$((seen + 1)) ;;
		FAIL) bad "$text"; seen=$((seen + 1)) ;;
		SKIP) skip "$text" "$reason"; seen=$((seen + 1)) ;;
		NON-DISCRIMINATING|NON-REPRESENTATIVE) weak "$text" "$status" "$reason"; seen=$((seen + 1)) ;;
		NOTE) inf "$text"; ;;
		esac
	done
	if [ "$saw_end" -ne 1 ]; then
		bad "the offline payload ran to completion (no terminator -- it died partway and the results above are an UNNAMED SUBSET)"
		return 1
	fi
	if [ "$claimed" -ne "$seen" ]; then
		bad "the offline payload's assertion count matches what arrived (claimed $claimed, received $seen)"
		return 1
	fi
	inf "offline payload terminator seen; $seen assertions accounted for"
	return 0
}

do_offline() {
	discover_image
	run_scope inspect 0
	ALL_SCOPES+=("inspect:$RUN_MON")
	hdr "T1 OFFLINE -- inspector VM, artifact attached read-only"
	inf "artifact: $IMAGE"
	inspector_up
	local out
	out="$(ssh_run "$INSPECT_KEY" "$RUN_SSH" inspector \
		"sudo ART_DEV=/dev/vdb SHIP_USER=$SHIP_USER sh -s" < <(inspect_payload) 2>/dev/null)"
	# 🔴 A HERESTRING, NEVER A PIPE. `... | tally_stream` runs the tallier in a
	# SUBSHELL, so every n_pass/n_fail increment is discarded when it exits: the
	# first run printed 117 assertions and then summarised "PASS 0 FAIL 0",
	# which would have reported a failing artifact as clean.
	tally_stream <<< "$out"
	run_down "$INSPECT_KEY" inspector
}

# ---------------------------------------------------------------- T2/T3 boots

boot_artifact() { # $1 = mode (bios|uefi), $2 = size (native|grown), $3 = port index, $4 = tag (optional)
	local mode="$1" size="$2" idx="$3" tag="${4:-$1-$2}"
	run_scope "$tag" "$idx"
	ALL_SCOPES+=("$tag:$RUN_MON")

	# The SMBIOS this run presents, and therefore the hostname it must produce.
	# Defaults reproduce the four original runs exactly; the board-serial run
	# overrides them to make switch-firstboot's second fallback rung reachable.
	local sys_serial="${SMBIOS_SYS_SERIAL:-$DMI_SERIAL}"
	local board_serial="${SMBIOS_BOARD_SERIAL:-}"
	local -a smbios=(-smbios type=1,manufacturer="$DMI_VENDOR",product="$DMI_PRODUCT",serial="$sys_serial")
	if [ -n "$board_serial" ]; then
		smbios+=(-smbios type=2,serial="$board_serial")
		# The system serial is a placeholder here, so the script must reject it
		# and settle on the BOARD serial. That is the whole point of this run.
		RUN_WANT_HOST="$(want_hostname "$DMI_PRODUCT" "$board_serial")"
	else
		RUN_WANT_HOST="$(want_hostname "$DMI_PRODUCT" "$sys_serial")"
	fi

	# 🔴 NEVER boot the artifact directly. Growth REPARTITIONS the disk it boots
	# on; booting the raw file would mutate the very bytes under test and every
	# later run would inspect a different image. A qcow2 overlay makes each run
	# disposable and the artifact immutable, and it is also how the two growth
	# branches are produced: an overlay at the backing size has zero free space
	# (the tolerance path), one at GROWN_SIZE has headroom (the work path).
	rm -f "$RUN_DIR/disk.qcow2"
	if [ "$size" = grown ]; then
		qemu-img create -q -f qcow2 -b "$IMAGE" -F raw "$RUN_DIR/disk.qcow2" "$GROWN_SIZE" \
			|| { bad "$RUN_TAG: could not create the grown overlay"; return 1; }
	else
		qemu-img create -q -f qcow2 -b "$IMAGE" -F raw "$RUN_DIR/disk.qcow2" \
			|| { bad "$RUN_TAG: could not create the native overlay"; return 1; }
	fi

	local -a fw=()
	if [ "$mode" = uefi ]; then
		# Written from scratch. qemu.uefi.sh is a PXE netboot script with no
		# disk attached, pointing at a path that does not exist on this host,
		# with VARS in the CODE slot -- it is not reused, and build.image.sh's
		# invocation wires CODE into the varstore slot and is not copied either.
		[ -r "$OVMF_CODE" ] || { bad "$RUN_TAG: no OVMF_CODE at $OVMF_CODE"; return 1; }
		[ -r "$OVMF_VARS" ] || { bad "$RUN_TAG: no OVMF_VARS at $OVMF_VARS"; return 1; }
		# 🔴 A FRESH VARS COPY PER RUN. A persisted varstore makes the UEFI run
		# non-repeatable and can cache a stale boot entry -- precisely the class
		# of false-green this member exists to delete.
		cp -f "$OVMF_VARS" "$RUN_DIR/OVMF_VARS.fd"
		chmod u+w "$RUN_DIR/OVMF_VARS.fd"
		fw=(
			-drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE"
			-drive if=pflash,format=raw,unit=1,file="$RUN_DIR/OVMF_VARS.fd"
		)
	fi

	hdr "T2/T3 $RUN_TAG -- ${mode^^} boot, $size disk"
	rm -f "$RUN_SERIAL"
	qemu-system-x86_64 \
		-enable-kvm -machine q35 -cpu host \
		-m "$MEM" -smp "$CPUS" \
		"${fw[@]}" \
		"${smbios[@]}" \
		-drive file="$RUN_DIR/disk.qcow2",if=none,id=root,format=qcow2 \
		-device virtio-blk-pci,drive=root,bootindex=0 \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$RUN_SSH"-:22 \
		-device e1000e,netdev=n0 \
		-display none -serial file:"$RUN_SERIAL" \
		-qmp tcp:127.0.0.1:"$RUN_MON",server=on,wait=off \
		-pidfile "$RUN_PIDFILE" -daemonize \
		|| { bad "$RUN_TAG: qemu failed to start"; return 1; }

	if wait_boot "$SHIP_KEY" "$SHIP_USER" "$RUN_TAG ssh"; then
		assert 0 "$RUN_TAG: the artifact boots and sshd is reachable on the shipped user model"
		assert_serial "$mode" "$size"
		assert_online "$mode" "$size"
	else
		bad "$RUN_TAG: the artifact did not reach a reachable sshd within ${BOOT_TIMEOUT}s"
		assert_serial "$mode" "$size"
		skip "$RUN_TAG: all T3 runtime assertions" "the guest never became reachable; see $RUN_SERIAL"
	fi
	run_down "$SHIP_KEY" "$SHIP_USER"
}

# 🔴 STRIP ANSI ESCAPES BEFORE ASSERTING ON A SERIAL LOG. systemd colourises
# the UNIT NAME inside its status lines, so the bytes on the wire are
#
#   Failed to start \e[0;1;39mssh.service\e[0m - OpenBSD Secure Shell server.
#
# and a literal `grep 'Failed to start ssh.service'` matches NOTHING. That
# produced a false PASS on "sshd started" across all four runs -- an assertion
# reporting green about the exact defect the run had just found, which is the
# worst direction this class can fail in. Carriage returns go too: the console
# is \r\n and a trailing \r defeats an anchored match.
serial_plain() { # $1 = raw serial log, $2 = destination
	sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x1b\][0-9;]*[^\x07]*\x07//g' -e 's/\r//g' "$1" > "$2"
}

assert_serial() { # $1 = mode, $2 = size
	local mode="$1" size="$2" s="$RUN_DIR/serial.plain"
	[ -r "$RUN_SERIAL" ] || { bad "$RUN_TAG: serial log was captured"; return 0; }
	serial_plain "$RUN_SERIAL" "$s"

	grep -qE 'login:' "$s" && ok "$RUN_TAG: reaches a login prompt on serial" \
	                       || bad "$RUN_TAG: reaches a login prompt on serial"
	# 🔴 systemd breaks an ordering cycle by DELETING A JOB. The damage is never
	# the cycle, it is which unit silently vanished.
	if grep -q 'Found ordering cycle' "$s"; then
		bad "$RUN_TAG: no ordering cycle in the boot ($(grep -c 'Found ordering cycle' "$s") lines)"
		grep -A2 'Found ordering cycle' "$s" | head -8 | sed 's/^/       /'
	else ok "$RUN_TAG: no ordering cycle in the boot"; fi

	# 🔴 GROWTH IS READ FROM THE KERNEL'S OWN RESIZE LINE, never from
	# switch-growroot's stdout. The first draft grepped the serial log for
	# "nothing to grow", which is the WRAPPER's stdout and therefore goes to the
	# JOURNAL -- it can never appear on the console. Both branches were unsound
	# in the same way and in opposite directions: the native runs reported a
	# false FAIL on correct growth, and the grown runs "passed" by asserting the
	# ABSENCE of a string that cannot occur, i.e. a check that could not fail.
	# `EXT4-fs (vda1): resizing filesystem from N to M blocks` is emitted by the
	# kernel, always reaches serial, and is the outcome rather than a message
	# about the outcome.
	local rz from to
	rz=$(grep -aoE 'resizing filesystem from [0-9]+ to [0-9]+ blocks' "$s" | tail -1)
	if [ -z "$rz" ]; then
		bad "$RUN_TAG: the kernel reports a root filesystem resize"
	else
		from=$(printf '%s' "$rz" | sed 's/.*from \([0-9]*\) to.*/\1/')
		to=$(printf '%s' "$rz" | sed 's/.*to \([0-9]*\) blocks.*/\1/')
		if [ "$size" = native ]; then
			if [ "$from" -eq "$to" ]; then
				ok "$RUN_TAG: growth correctly did nothing on a full disk ($from blocks, unchanged)"
			else bad "$RUN_TAG: growth correctly did nothing on a full disk (resized $from -> $to)"; fi
		else
			if [ "$to" -gt "$from" ]; then
				ok "$RUN_TAG: growth GREW the root filesystem ($from -> $to blocks) -- AD-4's work path"
			else bad "$RUN_TAG: growth GREW the root filesystem on a disk with ${GROWN_SIZE} of headroom (got $from -> $to)"; fi
		fi
	fi
	grep -qa 'Finished switch-growroot.service' "$s" \
		&& ok "$RUN_TAG: switch-growroot exited clean (systemd reports Finished, not Failed)" \
		|| bad "$RUN_TAG: switch-growroot exited clean"

	# 🔴 SAME DEFECT, SAME FIX. `switch-firstboot: done` is the script's stdout
	# and never reaches serial either. The getty banner does, and it carries the
	# hostname -- which is the unit's own principal output, so this asserts that
	# the unit ACHIEVED something rather than that it logged something.
	local want="$RUN_WANT_HOST"
	if grep -qa "$want login:" "$s"; then
		ok "$RUN_TAG: switch-firstboot derived the hostname from DMI ('$want' on the login banner)"
	else
		bad "$RUN_TAG: switch-firstboot derived the hostname from DMI -- banner shows '$(grep -aoE '^[A-Za-z0-9.-]+ login:' "$s" | tail -1)', wanted '$want login:'"
	fi
	# 🔴 NEVER 'localhost'. That is the name an artifact wears when identity setup
	# did not run at all, and it is the single most diagnostic string in this
	# whole file -- the 2026-08-04 artifact showed it on all four runs while
	# every other assertion about the boot passed.
	grep -qaE '^localhost login:' "$s" \
		&& bad "$RUN_TAG: the login banner is not 'localhost' (that name means switch-firstboot never ran)" \
		|| ok "$RUN_TAG: the login banner is not 'localhost'"
	# Its other principal output: the host keys sshd cannot start without.
	grep -qa 'Failed to start ssh.service' "$s" \
		&& bad "$RUN_TAG: sshd started (the host keys were regenerated at first boot)" \
		|| ok "$RUN_TAG: sshd started (the host keys were regenerated at first boot)"
	if [ "$mode" = uefi ]; then
		grep -qiE 'EFI stub|efi:' "$s" && ok "$RUN_TAG: the kernel reports an EFI boot (the UEFI path really was taken)" \
		                               || bad "$RUN_TAG: the kernel reports an EFI boot (the UEFI path really was taken)"
	fi
	return 0
}

g() { ssh_run "$SHIP_KEY" "$RUN_SSH" "$SHIP_USER" "$@" 2>/dev/null; }

assert_online() { # $1 = mode, $2 = size
	local mode="$1" size="$2" v

	# 🔴 UNCONDITIONALLY empty. No allowlist, ever: a unit that cannot succeed
	# in QEMU must be CONDITIONED by its owning member so systemd reports it
	# skipped, not failed. If a unit here needs an allowlist, the unit is wrong
	# and this is a FAIL against that member.
	v="$(g 'systemctl --failed --no-legend --plain' | grep -c .)"
	if [ "${v:-1}" -eq 0 ]; then ok "$RUN_TAG: systemctl --failed is empty (no allowlist)"
	else
		bad "$RUN_TAG: systemctl --failed is empty (no allowlist) -- $v failed unit(s):"
		g 'systemctl --failed --no-legend --plain' | sed 's/^/       /'
	fi

	# Hostname derivation, made discriminating by the synthetic DMI above.
	local want="$RUN_WANT_HOST"
	v="$(g 'cat /etc/hostname')"
	if [ "$v" = "$want" ]; then ok "$RUN_TAG: hostname derived from DMI is exactly '$want'"
	else bad "$RUN_TAG: hostname derived from DMI is exactly '$want' (got '${v:-empty}')"; fi

	v="$(g 'cat /etc/machine-id')"
	[ -n "$v" ] && ok "$RUN_TAG: machine-id was regenerated at first boot" || bad "$RUN_TAG: machine-id was regenerated at first boot"

	# 🔴 THE TRIGGER, OBSERVED RATHER THAN INFERRED. This is the assertion whose
	# absence let the original defect ship: the unit was enabled, its file was
	# correct, and it never ran. `systemctl show -p ConditionResult` is systemd's
	# own answer about its own decision, and after a successful first boot the
	# stamp exists -- so the expected answer here is "no", for the right reason.
	v="$(g 'systemctl show -p ConditionResult --value switch-firstboot.service')"
	local st; st="$(g 'test -e /var/lib/switch-firstboot.stamp && echo yes || echo no')"
	if [ "$st" = yes ]; then
		ok "$RUN_TAG: switch-firstboot RAN and left its stamp (so it will be skipped, correctly, on every later boot)"
	else
		bad "$RUN_TAG: switch-firstboot RAN and left its stamp -- no stamp exists, so it did not complete (ConditionResult=${v:-unknown})"
	fi
	v="$(g 'systemctl is-active switch-firstboot.service')"
	[ "$v" = active ] && ok "$RUN_TAG: switch-firstboot.service is active (RemainAfterExit) rather than skipped" \
		|| bad "$RUN_TAG: switch-firstboot.service is active rather than skipped (got '${v:-unknown}')"

	v="$(g 'ls -1 /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l')"
	[ "${v:-0}" -ge 1 ] && ok "$RUN_TAG: SSH host keys were regenerated at first boot ($v)" || bad "$RUN_TAG: SSH host keys were regenerated at first boot"
	# ed25519 ONLY, by ruling. Counted at runtime because the offline tier sees
	# an artifact with NO host keys at all -- this is the only tier that can.
	v="$(g 'ls -1 /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l')"
	[ "${v:-0}" = 1 ] && ok "$RUN_TAG: exactly one host key type exists (ed25519 only, by ruling)" \
		|| bad "$RUN_TAG: exactly one host key type exists (ed25519 only) -- found ${v:-0}: $(g 'ls -1 /etc/ssh/ssh_host_*_key 2>/dev/null | tr "\n" " "')"
	v="$(g 'ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null')"
	printf '%s' "$v" | grep -q "$want" \
		&& ok "$RUN_TAG: the host key's comment carries the derived hostname (set_hostname ran before keygen)" \
		|| bad "$RUN_TAG: the host key's comment carries the derived hostname (got: ${v:-nothing})"

	# --- growth outcome. THE OUTCOME, never a unit's exit status.
	local disk root
	disk="$(g "lsblk -bnro SIZE /dev/vda | head -1")"
	root="$(g "df -B1 --output=size / | tail -1 | tr -d ' '")"
	if [ -n "$disk" ] && [ -n "$root" ]; then
		local pct=$(( root * 100 / disk ))
		if [ "$size" = grown ]; then
			if [ "$pct" -ge 90 ]; then ok "$RUN_TAG: root grew to fill the disk (${pct}% of ${disk} bytes) -- AD-4's WORK path"
			else bad "$RUN_TAG: root grew to fill the disk -- only ${pct}% of ${disk} bytes"; fi
		else
			if [ "$pct" -ge 90 ]; then ok "$RUN_TAG: root already fills the disk (${pct}%) and growth left it intact"
			else bad "$RUN_TAG: root already fills the disk -- got ${pct}%"; fi
		fi
	else bad "$RUN_TAG: could not measure the root filesystem against the disk"; fi

	v="$(g 'swapon --show=NAME,SIZE --noheadings')"
	if printf '%s' "$v" | grep -q .; then ok "$RUN_TAG: swap is active at first boot ($(printf '%s' "$v" | tr -s ' ' | tr '\n' ' '))"
	else bad "$RUN_TAG: swap is active at first boot (AD-4's 2 GB swapfile)"; fi

	# --- networkd authority. 🔴 INCLUDING .link files: netplan generated
	# 10-netplan-<if>.link as well as .network, and a check that inspected only
	# .network would pass with a live .link present.
	v="$(g 'ls -1 /run/systemd/network/ 2>/dev/null | wc -l')"
	if [ "${v:-1}" -eq 0 ]; then ok "$RUN_TAG: /run/systemd/network is empty (.link files included) -- /etc is the sole authority"
	else
		bad "$RUN_TAG: /run/systemd/network is empty (.link files included) -- found $v:"
		g 'ls -1 /run/systemd/network/' | sed 's/^/       /'
	fi

	# --- mgmt plane. Real, because of -device e1000e.
	v="$(g 'networkctl --no-legend list mgmt 2>/dev/null')"
	if printf '%s' "$v" | grep -q 'routable'; then ok "$RUN_TAG: mgmt bond is routable with a real e1000e member"
	else bad "$RUN_TAG: mgmt bond is routable with a real e1000e member (got: ${v:-nothing})"; fi
	v="$(g 'cat /sys/class/net/mgmt/mtu')"
	[ "$v" = 1500 ] && ok "$RUN_TAG: mgmt MTU is 1500 at runtime" || bad "$RUN_TAG: mgmt MTU is 1500 at runtime (got ${v:-unknown})"

	# --- the default-route shape (D1)
	local nd on_mgmt
	nd="$(g "ip -4 route show default | wc -l")"
	on_mgmt="$(g "ip -4 route show default dev mgmt | wc -l")"
	if [ "${nd:-0}" -eq 1 ] && [ "${on_mgmt:-0}" -eq 1 ]; then
		ok "$RUN_TAG: exactly one IPv4 default route, and it is on mgmt"
	else
		bad "$RUN_TAG: exactly one IPv4 default route on mgmt (found $nd default route(s), $on_mgmt on mgmt)"
	fi
	# 🔴 H4: the DATA half of this cannot fail here and must not read as proof.
	weak "$RUN_TAG: data contributes no default route" NON-DISCRIMINATING \
		"the data bridge has zero members in QEMU (no ASIC, no swp*), so it has no carrier and no lease and could contribute no route regardless of how it were configured. The load-bearing check is the offline [DHCPv4] UseRoutes/UseGateway pair."

	# --- mlxsw modules are loadable for the running kernel
	if g 'modprobe -n mlxsw_spectrum' >/dev/null 2>&1; then
		ok "$RUN_TAG: mlxsw_spectrum resolves for the running kernel (dependencies satisfied)"
	else bad "$RUN_TAG: mlxsw_spectrum resolves for the running kernel"; fi
	v="$(g 'dkms status 2>/dev/null | grep -c mlxsw')"
	[ "${v:-0}" -ge 1 ] && ok "$RUN_TAG: dkms reports mlxsw installed for the running kernel" || bad "$RUN_TAG: dkms reports mlxsw installed for the running kernel"

	# --- weakened and skipped, with reasons
	weak "$RUN_TAG: systemd-networkd-wait-online did not stall the boot" NON-REPRESENTATIVE \
		"the single e1000e NIC comes up immediately here, so this passes in the only place it is cheap to run. The stated hazard is a switch with most front-panel ports dark, which QEMU cannot present."
	weak "$RUN_TAG: /etc/systemd/network is the only config source" NON-DISCRIMINATING \
		"cloud-init and netplan are purged from the image entirely, so no generator exists that could write to /run. The check cannot fail on an artifact that passed the offline purge assertions."
	v="$(g 'ls -1d /sys/class/net/swp* 2>/dev/null | wc -l')"
	skip "$RUN_TAG: front-panel ports enumerate into the data bridge (observed $v swp*)" \
		"QEMU has no emulated Spectrum ASIC; mlxsw_pci binds nothing. Hardware only."
	if g 'lsmod' | grep -q '^jc42'; then inf "$RUN_TAG: jc42 loaded"; fi
	skip "$RUN_TAG: coretemp/jc42 bind to real sensors" \
		"neither binds on a q35 vCPU with no real DIMM SMBus; systemd-modules-load masks per-module failure, so the unit succeeds either way. Presence is asserted offline."
	return 0
}

do_boot() {
	discover_image
	need qemu-system-x86_64; need qemu-img; need ssh
	[ -r "$SHIP_KEY" ] || die "no readable private key at $SHIP_KEY -- T3 logs into the shipped user model as $SHIP_USER"
	boot_artifact bios native 1
	boot_artifact bios grown  2
	boot_artifact uefi native 3
	boot_artifact uefi grown  4
	# 🔴 THE FIFTH RUN EXISTS FOR ONE RUNG. switch-firstboot falls back
	# product_serial -> board_serial -> machine-id, and the middle rung was added
	# from an Arch observation: a machine whose PRODUCT serial is a placeholder
	# can still carry a valid BASEBOARD serial. Without this run that rung is
	# code nothing ever takes -- and an untaken fallback is indistinguishable
	# from a broken one until the day a switch needs it.
	#
	# The system serial is set to a real placeholder rather than left unset, so
	# usable_serial() must REJECT it by pattern for this run to pass. If the
	# rejection list ever stops covering "Not Specified", the derived hostname
	# becomes mlnx-<product>-specified and this run goes red.
	SMBIOS_SYS_SERIAL="$DMI_SERIAL_PLACEHOLDER" SMBIOS_BOARD_SERIAL="$DMI_BOARD_SERIAL" \
		boot_artifact bios native 5 bios-board-serial
}

# ---------------------------------------------------------------- selftest
#
# OFFLINE proof: no VM, no root, no network. This script is a host-side driver
# whose work happens in qemu and in two different guests, so its offline tier
# is shim-ledger based -- run the real code paths with stand-ins first on PATH,
# record what they were asked to do, and assert on the record.
#
# 🔴 WHAT THIS TIER CANNOT PROVE, named so it is not mistaken for covered:
# whether the artifact is actually correct. That is what the other two tiers
# are for. This proves the HARNESS -- that the qemu invocations have the shape
# they claim, that the result model cannot silently lose a failure, and that
# the payload-truncation guard fires.

st_pass=0; st_fail=0
sok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; st_pass=$((st_pass + 1)); }
sbad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; st_fail=$((st_fail + 1)); }

# Forbidden-idiom grep, COMMENTS EXEMPT so this file may document what it
# refuses to do. Every pattern is assembled from adjacent quoted fragments so
# the literal never appears contiguously and the guard cannot match its own
# definition -- the same bug class as pkill matching its own invoking shell.
forbid_in() { # $1 = file, $2 = ERE, $3 = description
	local hits
	hits="$(sed 's/#.*//' "$1" | grep -nE "$2" || true)"
	if [ -z "$hits" ]; then sok "never $3"
	else sbad "$3 -- found:"; printf '%s\n' "$hits" | sed 's/^/       /'; fi
}

ST_TMP=""
# 🔴 EVERY BRANCH IS AN `if`, NEVER `[ ... ] && { ... }`. At the end of a
# function the latter returns 1 when the test is false; under a caller that
# stops on error it aborts before the rm -rf, leaking a temp tree per run while
# reporting a clean exit -- a cleanup path that silently never ran.
st_cleanup() {
	if [ -z "${ST_TMP:-}" ]; then return 0; fi
	rm -rf "$ST_TMP"
	ST_TMP=""
	return 0
}

write_st_shims() { # $1 = bin dir
	local d="$1" g
	mkdir -p "$d"
	cat > "$d/.recorder" <<-'SHIM'
	#!/bin/sh
	# Recorded stand-in: logs argv and stdin, then simulates the MINIMUM its
	# caller parses. Nothing else is faked.
	d="${SHIM_DIR:?SHIM_DIR unset -- a shim escaped its harness}"
	n=$(cat "$d/seq" 2>/dev/null || echo 0)
	n=$((n + 1)); printf '%s\n' "$n" > "$d/seq"
	prog=${0##*/}
	printf '%s %s\n' "$prog" "$*" >> "$d/ledger"
	: > "$d/argv.$n"
	for a in "$@"; do printf '%s\n' "$a" >> "$d/argv.$n"; done
	: > "$d/stdin.$n"
	[ -t 0 ] || cat >> "$d/stdin.$n"
	case "$prog" in
	qemu-img)
		# create must really produce the file, so the caller's later
		# readability checks are answered by a real file.
		last=""
		for a in "$@"; do case "$a" in *.qcow2) last="$a" ;; esac; done
		[ -n "$last" ] && printf 'FAKE-OVERLAY\n' > "$last" ;;
	ssh-keygen)
		f=""; nx=0
		for a in "$@"; do
			[ "$nx" = 1 ] && { f="$a"; nx=0; }
			[ "$a" = "-f" ] && nx=1
		done
		if [ -n "$f" ]; then
			printf 'FAKE-PRIVATE-KEY\n' > "$f"; chmod 0600 "$f"
			printf 'ssh-ed25519 AAAAFAKE inspector\n' > "$f.pub"
		fi ;;
	xorrisofs)
		o=""; nx=0
		for a in "$@"; do
			[ "$nx" = 1 ] && { o="$a"; nx=0; }
			[ "$a" = "-output" ] && nx=1
		done
		[ -n "$o" ] && printf 'FAKE-ISO\n' > "$o" ;;
	esac
	exit 0
	SHIM
	chmod 0755 "$d/.recorder"
	for g in qemu"-system"-x86_64 qemu-img ssh ssh-keygen xorrisofs; do
		cp "$d/.recorder" "$d/$g"
	done
}

# The CODE UNDER TEST: this file with its comments stripped AND its own
# selftest section excised.
#
# 🔴 EXCISING THE SELFTEST IS THE POINT, not tidiness. A shape guard that greps
# the whole file matches its own pattern literal and its own PASS/FAIL message
# strings, so it reports on itself instead of on the code. Caught by watching it
# fail: the "does not reuse qemu.uefi.sh" guard found `qemu.uefi.sh` three
# times -- once in its own pattern and twice in its own messages -- while the
# only real occurrence was in a comment. Same class as a guard matching its own
# bait (iter 17) and as pkill matching its own invoking shell.
#
# 🔴 IT IS A FILE, NEVER A PIPELINE. `printf '%s' "$src" | grep -q ...` is RACY
# under `set -o pipefail`: grep -q exits on its FIRST match, printf then takes
# SIGPIPE, and pipefail promotes that to a pipeline failure. Whether an
# assertion passed depended on how early in the file its pattern matched rather
# than on whether it was true -- eight guards inverted this way on the first
# run. Grepping a real file has no reader to close early.
write_src_under_test() { # $1 = destination
	sed '/^# -\{4,\} selftest$/,$d' "$HERE/boot-test.sh" | sed 's/#.*//' > "$1"
}

# Assert a pattern IS present in the code under test.
has() { # $1 = ERE, $2 = description
	if grep -qE -- "$1" "$SRC"; then sok "$2"; else sbad "$2"; fi
}
# Assert a pattern is NOT present in the code under test.
hasnt() { # $1 = ERE, $2 = description
	if grep -qE -- "$1" "$SRC"; then sbad "$2"; else sok "$2"; fi
}

do_selftest() {
	local SHIM_DIR
	ST_TMP="$(mktemp -d)"
	trap st_cleanup EXIT INT TERM
	SHIM_DIR="$ST_TMP/bin"
	export SHIM_DIR
	write_st_shims "$SHIM_DIR"

	hdr "boot-test.sh selftest -- no VM, no root, no network"

	# --- the file itself
	if bash -n "$HERE/boot-test.sh"; then sok "bash -n is clean"; else sbad "bash -n is clean"; fi

	# 🔴 Both forms match the full command line of the shell that invokes them.
	forbid_in "$HERE/boot-test.sh" 'pki''ll[[:space:]]+-f'  "uses pkill with a command-line pattern"
	forbid_in "$HERE/boot-test.sh" 'pgr''ep[[:space:]]+-f'  "uses pgrep with a command-line pattern"
	# `exec` carrying ONLY redirections applies them to the shell, permanently.
	forbid_in "$HERE/boot-test.sh" '^[[:space:]]*ex''ec[[:space:]]+[0-9]*[<>][^|]*2>[[:space:]]*/dev/null' "attaches a silencing redirection directly to exec"
	# A bare .ko glob finds ZERO on trixie, which ships .ko.xz, and prints
	# green. Two things keep this guard off its own back: the pattern literal
	# is split, AND the description below must never spell the glob out --
	# forbid_in scans the whole file, and the first attempt matched its own
	# MESSAGE (the trailing space after the suffix satisfies the [^*]).
	forbid_in "$HERE/boot-test.sh" 'mlxsw\*\.k''o[^*]' "globs the mlxsw modules with a bare kernel-object suffix (trixie ships them compressed)"
	# A cleanup that ends in a test aborts before its rm under set -e.
	forbid_in "$HERE/boot-test.sh" '^[[:space:]]*\[[^]]*\][[:space:]]*&&[[:space:]]*\{[[:space:]]*rm' "ends a cleanup path in a bare test-and-brace"
	# `[DHCP] UseGateway=` is silently dropped by systemd; the section matters.
	if grep -q 'DHCPv4' "$HERE/boot-test.sh"; then sok "asserts the DHCP keys under [DHCPv4], not [DHCP]"; else sbad "asserts the DHCP keys under [DHCPv4], not [DHCP]"; fi

	# --- the result model cannot lose a failure
	local before_fail=$n_fail
	( n_fail=0; bad "synthetic" >/dev/null; [ "$n_fail" -eq 1 ] ) \
		&& sok "bad() increments the failure counter" || sbad "bad() increments the failure counter"
	n_fail=$before_fail

	# --- the truncation guard fires
	local out
	out="$(printf 'R\tPASS\tone\t\nR\tPASS\ttwo\t\n' | ( tally_stream >/dev/null 2>&1; echo "rc=$?" ))"
	case "$out" in *rc=1*) sok "a payload with NO terminator is rejected" ;; *) sbad "a payload with NO terminator is rejected" ;; esac
	out="$(printf 'R\tPASS\tone\t\nR\tEND\t7\t\n' | ( tally_stream >/dev/null 2>&1; echo "rc=$?" ))"
	case "$out" in *rc=1*) sok "a payload whose count DISAGREES is rejected" ;; *) sbad "a payload whose count DISAGREES is rejected" ;; esac
	out="$(printf 'R\tPASS\tone\t\nR\tEND\t1\t\n' | ( tally_stream >/dev/null 2>&1; echo "rc=$?" ))"
	case "$out" in *rc=0*) sok "a complete payload is accepted" ;; *) sbad "a complete payload is accepted" ;; esac
	# 🔴 The tallier must mutate the REAL counters, not a subshell's copy. The
	# first run summarised "PASS 0 FAIL 0" after printing 117 assertions,
	# because it was invoked through a pipe.
	local p0=$n_pass f0=$n_fail
	tally_stream >/dev/null 2>&1 <<< "$(printf 'R\tPASS\ta\t\nR\tFAIL\tb\t\nR\tEND\t2\t\n')"
	if [ "$n_pass" -eq $((p0 + 1)) ] && [ "$n_fail" -eq $((f0 + 1)) ]; then
		sok "tally_stream increments the caller's counters (not a subshell's)"
	else sbad "tally_stream increments the caller's counters -- pass $p0->$n_pass, fail $f0->$n_fail"; fi
	n_pass=$p0; n_fail=$f0

	# --- the payload is syntactically valid sh
	inspect_payload > "$ST_TMP/payload.sh"
	if sh -n "$ST_TMP/payload.sh"; then sok "the offline payload is valid POSIX sh"; else sbad "the offline payload is valid POSIX sh"; fi
	grep -q "printf 'R\\\\tEND" "$ST_TMP/payload.sh" && sok "the payload emits a terminator" || sbad "the payload emits a terminator"
	grep -q 'set -e' "$ST_TMP/payload.sh" && sbad "the payload does not set -e (every assertion must run)" || sok "the payload does not set -e (every assertion must run)"
	grep -q 'mount -o ro' "$ST_TMP/payload.sh" && sok "the payload mounts the artifact read-only" || sbad "the payload mounts the artifact read-only"
	# 🔴 The kernel gate is about SELECTION, not COUNT (ruling reversed
	# 2026-08-04: a driverless RESCUE kernel is deliberate). These four must all
	# be present or the rescue kernel stops being safe.
	grep -q 'the DEFAULT boot kernel carries mlxsw' "$ST_TMP/payload.sh" \
		&& sok "the payload gates on the DEFAULT kernel carrying mlxsw" || sbad "the payload gates on the DEFAULT kernel carrying mlxsw"
	grep -q 'last-known-good names a kernel WITH mlxsw' "$ST_TMP/payload.sh" \
		&& sok "the payload gates on the R4 ladder never arming a driverless kernel" || sbad "the payload gates on the R4 ladder never arming a driverless kernel"
	grep -q 'is not the default' "$ST_TMP/payload.sh" \
		&& sok "the payload asserts the rescue kernel is not auto-selectable" || sbad "the payload asserts the rescue kernel is not auto-selectable"
	grep -q 'marked MANUALLY installed' "$ST_TMP/payload.sh" \
		&& sok "the payload asserts the rescue kernel survives unattended-upgrades" || sbad "the payload asserts the rescue kernel survives unattended-upgrades"
	grep -q 'exactly one kernel module tree' "$ST_TMP/payload.sh" \
		&& sbad "the payload no longer fails on a second kernel (ruling withdrawn)" || sok "the payload no longer fails on a second kernel (ruling withdrawn)"

	# --- the serial de-escaper, proven by OUTCOME on a real systemd line
	# 🔴 A behavioural test, not a source grep. Three assertions in this file
	# have now failed by grepping for text that could not appear, and a source
	# grep is exactly what kept missing it. This feeds the de-escaper the actual
	# byte sequence systemd emits and asserts the result is greppable.
	printf 'Starting \033[0;1;39mssh.service\033[0m - OpenBSD Secure Shell server...\r\n' >  "$ST_TMP/raw.log"
	printf '[\033[0;1;31mFAILED\033[0m] Failed to start \033[0;1;39mssh.service\033[0m - x.\r\n' >> "$ST_TMP/raw.log"
	printf '[    2.3] EXT4-fs (vda1): resizing filesystem from 2064379 to 8355835 blocks\r\n' >> "$ST_TMP/raw.log"
	grep -qa 'Failed to start ssh.service' "$ST_TMP/raw.log" \
		&& sbad "the RAW serial log defeats a literal grep (guard premise)" \
		|| sok "the RAW serial log defeats a literal grep (guard premise)"
	serial_plain "$ST_TMP/raw.log" "$ST_TMP/plain.log"
	grep -qa 'Failed to start ssh.service' "$ST_TMP/plain.log" \
		&& sok "de-escaped, the systemd status line IS matchable" \
		|| sbad "de-escaped, the systemd status line IS matchable"
	grep -qa '^\[FAILED\] Failed to start' "$ST_TMP/plain.log" \
		&& sok "de-escaping leaves the line anchorable at column 0" \
		|| sbad "de-escaping leaves the line anchorable at column 0"
	[ "$(grep -ac $'\r' "$ST_TMP/plain.log")" -eq 0 ] \
		&& sok "carriage returns are stripped" || sbad "carriage returns are stripped"
	# The growth line must survive de-escaping with its numbers intact.
	[ "$(sed -n 's/.*resizing filesystem from \([0-9]*\) to \([0-9]*\) blocks.*/\1 \2/p' "$ST_TMP/plain.log")" = "2064379 8355835" ] \
		&& sok "the kernel resize line survives de-escaping with both block counts" \
		|| sbad "the kernel resize line survives de-escaping with both block counts"
	# --- run scoping: every run is isolated
	local -a tags=(inspect bios-native bios-grown uefi-native uefi-grown)
	local i=0 ports="" mons="" serials=""
	for t in "${tags[@]}"; do
		run_scope "$t" "$i"
		ports="$ports $RUN_SSH"; mons="$mons $RUN_MON"; serials="$serials $RUN_SERIAL"
		i=$((i + 1))
	done
	[ "$(printf '%s' "$ports" | tr ' ' '\n' | grep -c .)" -eq "$(printf '%s' "$ports" | tr ' ' '\n' | sort -u | grep -c .)" ] \
		&& sok "every run gets a distinct ssh port" || sbad "every run gets a distinct ssh port"
	[ "$(printf '%s' "$mons" | tr ' ' '\n' | sort -u | grep -c .)" -eq 5 ] \
		&& sok "every run gets a distinct monitor port" || sbad "every run gets a distinct monitor port"
	[ "$(printf '%s' "$serials" | tr ' ' '\n' | sort -u | grep -c .)" -eq 5 ] \
		&& sok "every run gets a distinct serial log (a BIOS run cannot read a UEFI run's)" || sbad "every run gets a distinct serial log"
	# 🔴 M3: never vm.sh's WORK, and never its port.
	case "$WORK" in *mlnx-sw-os-vm) sbad "WORK is distinct from vm.sh's" ;; *) sok "WORK is distinct from vm.sh's build directory" ;; esac
	local clash=0 p
	for p in $ports; do [ "$p" = 2222 ] && clash=1; done
	[ "$clash" -eq 0 ] && sok "no run collides with vm.sh's default ssh port 2222" || sbad "no run collides with vm.sh's default ssh port 2222"
	# The monitor derives from the ssh port rather than being defaulted apart.
	run_scope probe 7
	[ "$RUN_MON" -eq $((RUN_SSH + 1000)) ] && sok "the monitor port derives from the ssh port" || sbad "the monitor port derives from the ssh port"

	# --- the qemu invocations have the shape they claim.
	# Proven from the SOURCE of the invocation rather than by booting, because
	# booting is what the other tiers do. Read as text so a future edit that
	# swaps virtio back in, or persists the varstore, fails here.
	local SRC="$ST_TMP/src.txt"
	write_src_under_test "$SRC"
	if [ -s "$SRC" ]; then sok "the code under test extracted (selftest excised, $(grep -c . "$SRC") non-blank lines)"
	else sbad "the code under test extracted"; fi

	has 'device e1000e,netdev=n0'   "the artifact boots behind an e1000e NIC (24-mgmt-bond.network matches Driver=e1000e)"
	has 'device virtio-net-pci,netdev=n0' "the INSPECTOR still uses virtio-net (it is not the artifact)"
	has 'if=pflash,format=raw,unit=0,readonly=on,file="\$OVMF_CODE"' "OVMF CODE goes in pflash unit 0, read-only"
	has 'if=pflash,format=raw,unit=1,file="\$RUN_DIR/OVMF_VARS.fd"'  "OVMF VARS goes in pflash unit 1, writable, per-run"
	has 'cp -f "\$OVMF_VARS" "\$RUN_DIR/OVMF_VARS.fd"' "the varstore is a FRESH copy per run (no cached boot entry)"
	# The PXE netboot script with no disk attached is never reused.
	hasnt 'qemu\.uefi\.sh' "does not reuse the repo's PXE netboot UEFI script"
	# 🔴 The artifact and the base share every partition UUID, so it must NOT be
	# present at boot: the inspector's own root= would be ambiguous.
	# The JSON lives inside a double-quoted shell string, so the quotes are
	# backslash-escaped on disk; the pattern must match what the FILE holds.
	has 'read-only\\":true' "the inspector attaches the artifact READ-ONLY at the qemu layer"
	has 'qmp_attach_artifact' "the artifact is HOT-PLUGGED after boot, not attached at boot"
	has 'pcie-root-port,id=hp0,bus=pcie\.0' "an empty PCIe root port is provided for the hot-plug to land on"
	has 'QMP rejected a command' "a QMP rejection reports qemu's own error text"
	# 🔴 Piping into the tallier loses every counter increment to a subshell.
	hasnt '\|[[:space:]]*tally_stream' "the tallier is never invoked through a pipe"
	has 'tally_stream <<< ' "the tallier is fed by a herestring"
	# A NOTE is not an assertion and must not advance the payload's count.
	hasnt 'R NOTE ' "notes never travel through the assertion counter"

	# 🔴 A SERIAL ASSERTION MAY ONLY GREP FOR TEXT THAT REACHES THE CONSOLE.
	# A unit's ExecStart stdout goes to the JOURNAL; systemd's own status lines
	# and the kernel's messages go to the console. Grepping serial for the
	# former produced a false FAIL on the native runs and an unfailable "PASS"
	# on the grown ones. These two literals are the ones that bit; the patterns
	# live in the excised selftest section, so they cannot match themselves.
	hasnt 'nothing to grow' "asserts growth from a wrapper's stdout (journal-only, never on serial)"
	hasnt 'switch-firstboot: done' "asserts first-boot from the script's stdout (journal-only, never on serial)"
	has 'resizing filesystem from \[0-9\]\+ to' "growth is asserted from the KERNEL's resize line, which always reaches serial"
	has 'serial_plain "\$RUN_SERIAL"' "assert_serial reads the DE-ESCAPED copy, never the raw log"
	has 'login:" "\$s"' "first-boot is asserted from the getty banner hostname, which always reaches serial"
	hasnt 'id=art,format=raw' "does not attach the artifact as a boot-time drive"
	has 'is not the inspector.s own root' "the payload refuses to inspect the inspector's own root device"
	has 'stat -c %d / ' "the payload compares filesystem device numbers before trusting the mount"
	# 🔴 The artifact is never booted directly: growth repartitions its disk.
	has 'file="\$RUN_DIR/disk.qcow2",if=none,id=root' "boots a per-run overlay, never the artifact file itself"
	has 'qemu-img create -q -f qcow2 -b "\$IMAGE" -F raw' "the overlay is backed by the artifact (the bytes under test are the shipped ones)"
	has 'smbios type=1' "synthetic DMI is supplied so hostname derivation is discriminating"
	# 🔴 THE BOARD-SERIAL RUNG. Present as a qemu option AND as a run that uses
	# it: a type=2 option nothing passes would be a fallback path with no test.
	has 'smbios type=2,serial=' "the BASEBOARD serial can be driven too (switch-firstboot's second fallback rung)"
	has 'bios-board-serial' "a run exists that presents a placeholder system serial and a valid board serial"
	has 'SMBIOS_BOARD_SERIAL="\$DMI_BOARD_SERIAL"' "and that run is the one wired to the board serial"
	# 🔴 THE OFF-BY-ONE. `sanitize | tail -c 8` counts sed's trailing NEWLINE as
	# one of the eight bytes and returns SEVEN characters. Harness and script
	# agreed on the wrong answer, so the assertion passed while both were wrong
	# against the documented "last 8". The inner printf is the fix, in both files.
	has 'printf .%s. "\$\(sanitize_dmi "\$2"\)" | tail -c 8' \
		"the expected hostname strips the trailing newline before counting 8 bytes (or it silently yields 7)"
	has 'RUN_WANT_HOST' "the expected hostname is PER RUN (the board-serial run must expect a different name)"
	# The single most diagnostic string in the 2026-08-04 failure.
	has 'localhost login:' "'localhost' on the banner is explicitly a FAILURE (it is what an artifact wears when identity setup never ran)"
	has 'ConditionResult --value switch-firstboot' \
		"the trigger is read from systemd's OWN verdict at runtime -- the check whose absence let a correct-looking, never-running unit ship"
	has 'switch-firstboot.stamp' "the offline tier asserts the first-boot stamp does not ship in the artifact"

	# --- the growth branches really differ
	local b
	has '"\$GROWN_SIZE"' "the grown overlay is created at GROWN_SIZE (default $GROWN_SIZE)"
	b=$(grep -cE 'qemu-img create -q -f qcow2 -b "\$IMAGE" -F raw' "$SRC")
	[ "${b:-0}" -eq 2 ] && sok "there are exactly two overlay shapes: native and grown" || sbad "there are exactly two overlay shapes (found $b)"

	# --- every SKIP carries a reason, and weak states are distinct from PASS
	local nskip nreason
	# (^|space) rather than ^space: several S calls sit after an `else` on the
	# same line, and anchoring at line start would silently exclude them from
	# BOTH counts -- a guard that agrees with itself about a subset it never
	# names is the defect this file exists to catch.
	nskip=$(grep -cE '(^|[[:space:]])S "' "$SRC")
	nreason=$(grep -cE '(^|[[:space:]])S "[^"]*" "' "$SRC")
	[ "$nskip" -eq "$nreason" ] && sok "every payload SKIP carries a reason ($nskip)" || sbad "every payload SKIP carries a reason ($nreason of $nskip)"
	has 'n_weak=\$\(\(n_weak \+ 1\)\)' "weakened assertions are counted apart from PASS"
	has 'NON-DISCRIMINATING' "the NON-DISCRIMINATING label is used"
	has 'NON-REPRESENTATIVE' "the NON-REPRESENTATIVE label is used"

	# --- the power ladder announces a force
	has 'this is a power cut' "the force rung announces that it is a power cut"
	has 'kill -0 "\$\(cat "\$RUN_PIDFILE"\)"' "liveness is read from the pidfile, never from a process name"

	# --- seed hygiene: the inspector key never reaches the artifact
	has 'INSPECT_KEY\.pub' "the inspector seeds a throwaway key of its own"
	has 'ssh_run "\$SHIP_KEY"' "T3 logs in with the SHIPPED user model, not an injected key"

	printf '\n\033[1mselftest: %d passed, %d failed\033[0m\n' "$st_pass" "$st_fail"
	st_cleanup
	[ "$st_fail" -eq 0 ]
}

# ---------------------------------------------------------------- report

report() {
	hdr "boot-test summary"
	printf '  PASS %d   FAIL %d   SKIP %d   WEAK %d\n' "$n_pass" "$n_fail" "$n_skip" "$n_weak"
	printf '\n'
	printf '  SKIP = not runnable here, with a stated reason.\n'
	printf '  WEAK = the check RAN and could not have failed. It is not evidence.\n'
	printf '\n'
	printf '  🔴 Port enumeration into the data bridge -- the epic'"'"'s own success\n'
	printf '     criterion -- is NOT proven by any of this. QEMU has no Spectrum\n'
	printf '     ASIC. That claim needs a switch on trixie and nothing less.\n'
	if [ "$n_fail" -gt 0 ]; then
		printf '\n\033[31m  %d FAILED -- the artifact is NOT validated.\033[0m\n' "$n_fail"
		return 1
	fi
	printf '\n\033[32m  no failures.\033[0m\n'
	return 0
}

# ---------------------------------------------------------------- interactive
#
# 🔴 THE IMAGE ALREADY SUPPORTS BOTH CONSOLES. Measured on the artifact: the
# generated command line carries `console=tty0 console=ttyS0,115200` -- BOTH --
# and `getty@tty1.service` (the VGA text console) is enabled, alongside the
# serial getty systemd spawns because ttyS0 is the last console= token. Enabling
# serial did not disable VGA.
#
# What hides the VGA console is THIS HARNESS: the automated tiers pass
# `-display none` because they are unattended and assert on a serial FILE. That
# is a harness choice, not a property of the image, and it is the whole reason
# there appeared to be no way in. This subcommand is the documented way in.
do_console() {
	discover_image
	need qemu-system-x86_64; need qemu-img
	local mode="${MODE:-bios}"
	run_scope "console-$mode" 6
	rm -f "$RUN_DIR/disk.qcow2"
	qemu-img create -q -f qcow2 -b "$IMAGE" -F raw "$RUN_DIR/disk.qcow2" "${GROWN_SIZE}" \
		|| die "could not create the overlay"

	local -a fw=()
	if [ "$mode" = uefi ]; then
		[ -r "$OVMF_CODE" ] || die "no OVMF_CODE at $OVMF_CODE"
		cp -f "$OVMF_VARS" "$RUN_DIR/OVMF_VARS.fd"; chmod u+w "$RUN_DIR/OVMF_VARS.fd"
		fw=(-drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE"
		    -drive if=pflash,format=raw,unit=1,file="$RUN_DIR/OVMF_VARS.fd")
	fi

	cat <<-EOM

	Booting the artifact interactively (${mode^^}), on a DISPOSABLE overlay --
	the artifact file itself is never written.

	  serial console : this terminal (you are attached to it now)
	  VGA console    : ${DISPLAY_MODE:-none -- re-run with DISPLAY_MODE=gtk for a window}
	  ssh            : ssh -i $SHIP_KEY -p $RUN_SSH $SHIP_USER@127.0.0.1
	  quit qemu      : Ctrl-a x        (serial is on a qemu multiplexer)
	  qemu monitor   : Ctrl-a c

	⚠ Console LOGIN needs a password, and this image is SSH-key-only by design,
	  so no account has one. Until fix-switch-firstboot-never-fires lands, sshd
	  cannot start either -- so this session is for WATCHING the boot and using
	  the GRUB menu, not for logging in. Interrupt GRUB to reach the rescue
	  kernel or a root shell (init=/bin/sh).

	EOM

	# -serial mon:stdio, not -serial file: this is the interactive path. `mon:`
	# multiplexes the qemu monitor onto the same terminal so Ctrl-a x can end a
	# guest that never reaches a prompt.
	qemu-system-x86_64 \
		-enable-kvm -machine q35 -cpu host \
		-m "$MEM" -smp "$CPUS" \
		"${fw[@]}" \
		-smbios type=1,manufacturer="$DMI_VENDOR",product="$DMI_PRODUCT",serial="$DMI_SERIAL" \
		-drive file="$RUN_DIR/disk.qcow2",if=none,id=root,format=qcow2 \
		-device virtio-blk-pci,drive=root,bootindex=0 \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$RUN_SSH"-:22 \
		-device e1000e,netdev=n0 \
		-display "${DISPLAY_MODE:-none}" -serial mon:stdio
}

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	printf '\nCommands:\n'
	printf '  offline    T1 only -- inspector VM, artifact attached read-only\n'
	printf '  boot       T2+T3 only -- four boots: {BIOS,UEFI} x {native,grown}\n'
	printf '  all        offline, then boot (default)\n'
	printf '  console    boot the artifact INTERACTIVELY on a disposable overlay,\n'
	printf '             serial attached to this terminal (Ctrl-a x to quit).\n'
	printf '             MODE=uefi for the UEFI path; DISPLAY_MODE=gtk for a VGA window.\n'
	printf '  selftest   offline proof of the harness itself: no VM, no root\n'
}

# ---------------------------------------------------------------- dispatch
case "${1:-all}" in
offline)  trap cleanup_all EXIT INT TERM; do_offline; report ;;
boot)     trap cleanup_all EXIT INT TERM; do_boot;    report ;;
all)      trap cleanup_all EXIT INT TERM; do_offline; do_boot; report ;;
console)  do_console ;;
selftest) do_selftest ;;
-h|--help|help) usage ;;
*) usage; exit 2 ;;
esac
