#!/bin/bash
# Slaved-VM pipeline for the switch image builder -- stages S1-S3.
#
# Boots an OFFICIAL distro cloud image under QEMU with an SSH key injected via
# a cloud-init NoCloud seed, then drives it over plain ssh. The build host needs
# only qemu, xorriso and curl -- no bootstrapper, no archive keyring, no
# cross-distro packaging tooling.
#
# THE DISTRO SEAM is the `case "$DISTRO"` block below plus the package commands
# in do_provision(). Nothing else in this file is distro-specific. That seam is
# the entire reason this exists instead of a pipeline written around a
# Debian-only bootstrapper: swapping to a rolling Arch base must not be a
# rewrite.
#
# Usage: vm.sh {fetch|up|ssh|provision|probe|status|down|destroy}
set -euo pipefail

# ---------------------------------------------------------------- config
DISTRO="${DISTRO:-debian}"

# NOT /tmp -- /tmp is tmpfs on the build host and the working image would live
# in RAM. See the task's Constraints.
WORK="${WORK:-/var/tmp/mlnx-sw-os-vm}"

DISK_SIZE="${DISK_SIZE:-8G}"        # AD-4: lean image, grown on first boot
MEM="${MEM:-4G}"
CPUS="${CPUS:-4}"
SSH_PORT="${SSH_PORT:-2222}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}" # hard ceiling on the readiness poll
BUILD_USER="${BUILD_USER:-builder}"

case "$DISTRO" in
debian)
	# GENERIC, not nocloud and not genericcloud. Measured 2026-08-01:
	#
	#   nocloud       "Does not run cloud-init and boots directly to a root
	#                 prompt" -- cloud-init is REMOVED. Booting it logged
	#                 zero cloud-init and zero sshd lines and sat at
	#                 "Please configure your system!". The seed ISO is never
	#                 read because nothing reads it. The name means "no
	#                 cloud-init", NOT "the NoCloud datasource".
	#   genericcloud  cloud-init present, but a REDUCED set of hardware
	#                 drivers -- built for virtual machines. This image is
	#                 dd'd onto physical SN2410/SN2700 hardware, so a
	#                 trimmed driver set is a direct boot risk.
	#   generic       cloud-init present, full driver set, and Debian
	#                 explicitly lists bare metal as a target. The only
	#                 variant that satisfies both halves of this pipeline.
	BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"
	BASE_IMAGE="debian-13-generic-amd64.qcow2"
	SUMS_FILE="SHA512SUMS"
	SUMS_TOOL="sha512sum"
	;;
arch)
	# URLs confirmed to resolve 2026-08-01. The provision() package commands
	# have NOT been exercised on Arch -- this entry demonstrates that the
	# seam is real, it does not claim a supported path.
	BASE_URL="https://geo.mirror.pkgbuild.com/images/latest"
	BASE_IMAGE="Arch-Linux-x86_64-cloudimg.qcow2"
	SUMS_FILE="Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
	SUMS_TOOL="sha256sum"
	;;
*)
	printf 'error: unknown DISTRO: %s\n' "$DISTRO" >&2; exit 1 ;;
esac

CACHE="$WORK/cache"                 # pristine downloads -- NEVER mutated
IMG="$WORK/work.qcow2"
SEED="$WORK/seed.iso"
KEY="$WORK/id_ed25519"
PIDFILE="$WORK/qemu.pid"
SERIAL="$WORK/serial.log"

SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-o ConnectTimeout=5
	-i "$KEY"
	-p "$SSH_PORT"
)

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null || die "missing build-host dependency: $1"; }

vm_running() {
	[ -r "$PIDFILE" ] || return 1
	kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

ssh_vm() { ssh "${SSH_OPTS[@]}" "$BUILD_USER@127.0.0.1" "$@"; }

# Readiness is a poll against the forwarded port with a hard ceiling -- not a
# fixed sleep, and not console pattern-matching.
wait_ssh() {
	local what="${1:-ssh}" waited=0
	info "waiting for $what (timeout ${BOOT_TIMEOUT}s)"
	until ssh_vm true 2>/dev/null; do
		vm_running || { tail -20 "$SERIAL" >&2; die "qemu exited -- see $SERIAL"; }
		[ "$waited" -lt "$BOOT_TIMEOUT" ] || {
			tail -20 "$SERIAL" >&2
			die "$what not up after ${BOOT_TIMEOUT}s -- see $SERIAL"
		}
		sleep 3; waited=$((waited + 3))
	done
	info "$what up after ${waited}s"
}

# ---------------------------------------------------------------- S1: fetch
do_fetch() {
	need curl
	mkdir -p "$CACHE"

	info "fetching $BASE_IMAGE"
	# -L: cloud.debian.org 302s to a mirror. -C -: resume a partial download
	# rather than restarting 388 MB.
	curl -fL --progress-bar -C - -o "$CACHE/$BASE_IMAGE" "$BASE_URL/$BASE_IMAGE"
	curl -fLsS -o "$CACHE/$SUMS_FILE" "$BASE_URL/$SUMS_FILE"

	info "verifying checksum"
	local line
	line=$(grep -F " $BASE_IMAGE" "$CACHE/$SUMS_FILE" | head -1) \
		|| die "$BASE_IMAGE is not listed in $SUMS_FILE -- cannot verify"
	[ -n "$line" ] || die "$BASE_IMAGE is not listed in $SUMS_FILE"
	( cd "$CACHE" && printf '%s\n' "$line" | "$SUMS_TOOL" -c - ) \
		|| die "CHECKSUM MISMATCH -- delete $CACHE/$BASE_IMAGE and refetch"

	info "base image verified: $CACHE/$BASE_IMAGE"
}

# ---------------------------------------------------------------- seed
write_seed() {
	need xorrisofs
	local d="$WORK/seed"
	rm -rf "$d"; mkdir -p "$d"

	[ -r "$KEY.pub" ] || {
		info "generating a dedicated build key (throwaway; S6 strips it)"
		ssh-keygen -t ed25519 -N '' -C 'mlnx-sw-os build' -f "$KEY" >/dev/null
	}

	# NoCloud: cloud-init reads a filesystem labelled `cidata` carrying
	# user-data and meta-data. No metadata service is contacted, which is
	# exactly a switch on a management network.
	cat > "$d/user-data" <<-EOF
	#cloud-config
	users:
	  - name: $BUILD_USER
	    sudo: 'ALL=(ALL) NOPASSWD:ALL'
	    shell: /bin/bash
	    lock_passwd: true
	    ssh_authorized_keys:
	      - $(cat "$KEY.pub")
	ssh_pwauth: false
	EOF

	cat > "$d/meta-data" <<-EOF
	instance-id: mlnx-sw-os-build
	local-hostname: mlnx-build
	EOF

	# xorrisofs, not genisoimage: genisoimage is not packaged on the Arch
	# build host and xorrisofs takes the same options. One dependency fewer.
	xorrisofs -quiet -output "$SEED" -volid cidata -joliet -rock \
		"$d/user-data" "$d/meta-data"
}

# ---------------------------------------------------------------- S2: boot
do_up() {
	need qemu-system-x86_64; need qemu-img; need ssh
	[ -r "$CACHE/$BASE_IMAGE" ] || die "no base image -- run: $0 fetch"

	if vm_running; then
		info "already running (pid $(cat "$PIDFILE"))"; return 0
	fi

	if [ ! -f "$IMG" ]; then
		info "preparing working image from the pristine base"
		# Copy, never mutate the download: a re-run must start from a
		# pristine base or the build is not repeatable.
		cp --reflink=auto "$CACHE/$BASE_IMAGE" "$IMG"

		local cur want
		# Parse the PLAIN output, not --output=json. The JSON nests a
		# `children[].info` for the backing file whose own "virtual-size"
		# is the FILE size and sorts first -- taking head -1 there reads
		# 416 MiB for an image whose virtual size is 3 GiB, and would
		# happily attempt a shrink (which qemu-img refuses) on any base
		# larger than $DISK_SIZE.
		cur=$(qemu-img info "$IMG" | sed -n 's/^virtual size:.*(\([0-9]*\) bytes)/\1/p')
		[ -n "$cur" ] || die "could not determine virtual size of $IMG"
		want=$(numfmt --from=iec "${DISK_SIZE}")
		if [ "$want" -gt "$cur" ]; then
			info "resizing $((cur / 1048576))M -> $DISK_SIZE"
			qemu-img resize -q "$IMG" "$DISK_SIZE"
		else
			info "base virtual size $((cur / 1048576))M already >= $DISK_SIZE, not resizing"
		fi
	fi

	write_seed

	info "booting"
	rm -f "$SERIAL"
	qemu-system-x86_64 \
		-enable-kvm -machine q35 -cpu host \
		-m "$MEM" -smp "$CPUS" \
		-drive file="$IMG",if=virtio,format=qcow2 \
		-drive file="$SEED",media=cdrom,format=raw \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
		-device virtio-net-pci,netdev=n0 \
		-display none -serial file:"$SERIAL" \
		-pidfile "$PIDFILE" -daemonize

	wait_ssh "ssh"
	info "ssh -i $KEY -p $SSH_PORT $BUILD_USER@127.0.0.1"
}

# ---------------------------------------------------------------- S3: provision
do_provision() {
	vm_running || die "not running -- run: $0 up"

	# DISTRO SEAM. The minimum set only: the harvested manifest's
	# "probably not required" packages (bc, flex, bison, cpio, libelf-dev,
	# libssl-dev, dwarves) are deliberately NOT installed, so Phase 3 finds
	# out by failing loudly rather than by inheriting the old script's list.
	#
	# The kernel series is derived from the running kernel. No point-release
	# literal reaches this script -- trixie has no stable ABI number and
	# 6.12.94 was already stale by the time it was written down.
	# The shipped image's kernel lags the archive: debian-13-generic ships
	# 6.12.96+deb13-amd64 while trixie's linux-source-6.12 is at 6.12.100-1
	# (measured 2026-08-01). Installing linux-headers-amd64 on top of that
	# yields headers for a kernel we are NOT running, and Phase 3's vermagic
	# check would then prove nothing. So upgrade to the archive first and
	# reboot if the kernel moved -- which is also what a real switch does on
	# `apt upgrade`.
	local before after
	before=$(ssh_vm 'uname -r')
	info "running kernel before upgrade: $before"

	info "full-upgrade to archive state"
	ssh_vm 'sudo sh -s' <<-'EOF'
	set -eu
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get full-upgrade -y -qq
	EOF

	if [ "$(ssh_vm 'ls -1 /boot/vmlinuz-* | sed "s|.*vmlinuz-||" | sort -V | tail -1')" != "$before" ]; then
		info "kernel changed -- rebooting so the running kernel matches the archive"
		ssh_vm 'sudo systemctl reboot' 2>/dev/null || true
		sleep 5
		wait_ssh "ssh after reboot"
	fi
	after=$(ssh_vm 'uname -r')
	[ "$before" = "$after" ] && info "kernel unchanged: $after" \
	                         || info "kernel now: $before -> $after"

	# DISTRO SEAM. The minimum set only: the harvested manifest's
	# "probably not required" packages (bc, flex, bison, cpio, libelf-dev,
	# libssl-dev, dwarves) are deliberately NOT installed, so Phase 3 finds
	# out by failing loudly rather than by inheriting the old script's list.
	#
	# The kernel series is derived from the running kernel. No point-release
	# literal reaches this script -- trixie has no stable ABI number and
	# 6.12.94 was already stale by the time it was written down.
	info "installing the minimum build set (series derived in-guest)"
	ssh_vm 'sudo sh -s' <<-'EOF'
	set -eu
	export DEBIAN_FRONTEND=noninteractive
	SERIES=$(uname -r | cut -d. -f1,2)
	apt-get install -y -qq build-essential dkms linux-headers-amd64 "linux-source-$SERIES"
	EOF

	# Assert the thing Phase 3 depends on, rather than assuming it.
	info "asserting headers match the running kernel"
	ssh_vm 'sh -s' <<-'EOF'
	set -eu
	R=$(uname -r)
	[ -d "/lib/modules/$R/build" ] || { echo "FAIL: no /lib/modules/$R/build" >&2; exit 1; }
	H=$(dpkg-query -W -f='${Version}' "linux-headers-$R" 2>/dev/null || echo MISSING)
	I=$(dpkg-query -W -f='${Version}' "linux-image-$R" 2>/dev/null || echo MISSING)
	echo "running:  $R"
	echo "headers:  linux-headers-$R = $H"
	echo "image:    linux-image-$R = $I"
	[ "$H" = "MISSING" ] && { echo "FAIL: headers for the running kernel are not installed" >&2; exit 1; }
	echo "OK: headers present for the running kernel"
	EOF

	info "extracting linux-source (ships as a tarball, not a tree)"
	ssh_vm 'sudo sh -s' <<-'EOF'
	set -eu
	SERIES=$(uname -r | cut -d. -f1,2)
	cd /usr/src
	[ -d "linux-source-$SERIES" ] || tar -xf "linux-source-$SERIES.tar.xz"
	ls -d "/usr/src/linux-source-$SERIES"
	EOF
}

# ---------------------------------------------------------------- probe
# The Phase 0 deliverable: record what the VM actually is, from the VM itself.
do_probe() {
	vm_running || die "not running -- run: $0 up"
	ssh_vm 'sudo sh -s' <<-'EOF'
	set -eu
	echo "=== identity ==="
	. /etc/os-release; echo "os:            $PRETTY_NAME"
	echo "uname -r:      $(uname -r)"
	echo "series:        $(uname -r | cut -d. -f1,2)"
	echo
	echo "=== package versions (headers and source must agree on the base) ==="
	for p in linux-headers-amd64 dkms build-essential; do
	  printf '%-22s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo '-')"
	done
	S=$(uname -r | cut -d. -f1,2)
	printf '%-22s %s\n' "linux-source-$S" "$(dpkg-query -W -f='${Version}' "linux-source-$S" 2>/dev/null || echo '-')"
	printf '%-22s %s\n' "running kernel pkg" "$(dpkg-query -W -f='${Version}' "linux-image-$(uname -r)" 2>/dev/null || echo '-')"
	echo
	echo "=== partition label of the base image (settles the open question) ==="
	sfdisk -l /dev/vda 2>/dev/null | grep -iE 'disklabel|^/dev/vda'
	echo
	echo "=== is root the LAST partition ON DISK? (AD-4 precondition) ==="
	# BY POSITION, not by partition number. Debian's cloud layout numbers
	# root as 1 while placing vda14 (bios_boot) and vda15 (ESP) BEFORE it on
	# disk, precisely so root stays growable. Sorting by number reports vda15
	# and gives the wrong answer.
	partx -o NR,START,END,SIZE,NAME -g /dev/vda | sort -k2 -n
	LAST=$(partx -o NR,START -g /dev/vda | sort -k2 -n | tail -1 | awk '{print $1}')
	ROOT=$(findmnt -no SOURCE / | sed 's|.*/vda||')
	echo "root is /dev/vda$ROOT; last partition on disk is /dev/vda$LAST"
	[ "$ROOT" = "$LAST" ] && echo "AD-4 precondition: SATISFIED (root is last, growable)" \
	                      || echo "AD-4 precondition: VIOLATED (something sits after root)"
	echo
	echo "=== growth tooling present in the base? ==="
	command -v growpart || echo "growpart: ABSENT"
	dpkg-query -W -f='cloud-guest-utils ${Version} (${Status})\n' cloud-guest-utils 2>/dev/null || echo "cloud-guest-utils: not installed"
	dpkg-query -W -f='cloud-init ${Version}\n' cloud-init 2>/dev/null || echo "cloud-init: not installed"
	echo
	echo "=== mlxsw premises (Phase 1 audits properly; this is a peek) ==="
	C=/boot/config-$(uname -r)
	grep -E '^# CONFIG_MLXSW_CORE is not set|^CONFIG_MLXSW_CORE=' "$C" || echo "CONFIG_MLXSW_CORE: ABSENT ENTIRELY"
	grep -E '^CONFIG_MODULE_SIG_FORCE=|^# CONFIG_MODULE_SIG_FORCE is not set' "$C" || echo "MODULE_SIG_FORCE: absent"
	echo
	echo "=== disk ==="
	findmnt -no SOURCE,FSTYPE,SIZE,USED,AVAIL /
	EOF
}

# ---------------------------------------------------------------- lifecycle
do_status() {
	if vm_running; then
		printf 'running  pid=%s  ssh -i %s -p %s %s@127.0.0.1\n' \
			"$(cat "$PIDFILE")" "$KEY" "$SSH_PORT" "$BUILD_USER"
		ssh_vm true 2>/dev/null && echo "ssh:     reachable" || echo "ssh:     NOT reachable"
	else
		echo "stopped"
	fi
	[ -r "$CACHE/$BASE_IMAGE" ] && echo "base:    $CACHE/$BASE_IMAGE" || echo "base:    not fetched"
	[ -f "$IMG" ] && echo "image:   $IMG ($(du -h "$IMG" | cut -f1) on disk)" || echo "image:   not prepared"
}

do_down() {
	vm_running || { info "not running"; return 0; }
	info "graceful poweroff"
	ssh_vm 'sudo systemctl poweroff' 2>/dev/null || true
	local waited=0
	while vm_running && [ "$waited" -lt 60 ]; do sleep 2; waited=$((waited + 2)); done
	vm_running && { info "forcing"; kill "$(cat "$PIDFILE")" 2>/dev/null || true; } || true
	rm -f "$PIDFILE"
	info "down"
}

do_destroy() {
	do_down
	# Deliberately keeps $CACHE: the pristine base is expensive to refetch
	# and is never mutated, so there is nothing to invalidate.
	rm -f "$IMG" "$SEED" "$SERIAL"
	rm -rf "$WORK/seed"
	info "working image removed; pristine base kept in $CACHE"
}

# ---------------------------------------------------------------- dispatch
mkdir -p "$WORK"
case "${1:-}" in
fetch)     do_fetch ;;
up)        do_up ;;
ssh)       shift; ssh_vm "$@" ;;
provision) do_provision ;;
probe)     do_probe ;;
status)    do_status ;;
down)      do_down ;;
destroy)   do_destroy ;;
*)
	sed -n '2,18p' "$0" | sed 's/^# \?//'
	printf '\nUsage: %s {fetch|up|ssh|provision|probe|status|down|destroy}\n' "$0"
	exit 1 ;;
esac
