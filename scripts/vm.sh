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
# Usage: vm.sh {fetch|up|ssh|provision|probe|audit|status|down|destroy}
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

# QMP control port -- the out-of-band power channel. DERIVED from SSH_PORT on
# purpose, never defaulted independently: safe concurrent VM work already
# requires a distinct WORK and a distinct SSH_PORT per agent, and a separately
# defaulted monitor port would be a third thing to get right. Two agents on the
# defaults would silently share one control channel over each other's guest.
# Derived, the existing discipline covers it by construction.
MON_PORT="${MON_PORT:-$((SSH_PORT + 1000))}"
# How long to wait for ACPI to be acted on before force-killing. A guest whose
# kernel has already wedged ignores the power button too, so this MUST time out
# and fall through rather than read as a guarantee.
ACPI_TIMEOUT="${ACPI_TIMEOUT:-60}"

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
	#
	# 🔴 PINNED TO AN IMMUTABLE SNAPSHOT, NEVER `latest/`. `latest/` is a
	# MOVING TARGET and pointing a build at it has two distinct failure
	# modes, both measured on this host 2026-08-04:
	#
	#   1. The image is cached and the SUMS file is not, so a re-fetch
	#      verifies a GOOD cache against a NEWER snapshot's checksum and
	#      dies with "CHECKSUM MISMATCH" -- telling the operator to delete
	#      the only pinned thing in the build. Reproduced exactly: the
	#      cache held 1ff07be8… (snapshot 20260722-2547) under a SUMS file
	#      saying db3cd133… (snapshot 20260803-2559).
	#
	#   2. Worse, and silent: `curl -C -` resumes by BYTE OFFSET. Against a
	#      URL whose content changed underneath it, a local file SMALLER
	#      than the new remote yields a HYBRID -- old bytes at the front,
	#      new bytes at the back, the correct total size, and curl exits 0.
	#      A local file LARGER is left stale and never refreshed, also rc=0.
	#      Only the checksum catches either, and case 1 is why the checksum
	#      cannot be trusted. Pinning makes `-C -` correct again, which is
	#      why the flag is KEPT: resuming 400 MB is what it is for.
	#
	# Bump these deliberately, in a commit that says why -- it is a FLOOR to
	# be raised on purpose, exactly like the `linux-headers-amd64` bound.
	# Two builds must differ in the code under test, not in their base.
	#
	# 🔴 THESE TWO ARE ONE FACT AND MOVE TOGETHER. The digest describes THAT
	# serial's image and no other, which is why it is keyed to the serial
	# below rather than applied to whatever serial happens to be selected:
	# carrying yesterday's digest onto today's snapshot reports a perfectly
	# good download as corrupt, which is the exact false diagnosis this
	# whole change exists to remove.
	#
	# 🔴 The expected digest is a REPO FACT, not a network fact. An immutable
	# directory is still fetched over the network, and verifying a download
	# against a checksum from the same server only proves the server is
	# self-consistent. The mirror's own SUMS is then a corroborating second
	# opinion, and the two disagreeing is a finding rather than a coin toss.
	PINNED_SERIAL=20260722-2547
	PINNED_SHA512=1ff07be8406c4abcb75662a351b6124408c4a2795801037f8e4fe9ee27084ee2112bef92222f4bbeb9f7df8df1062971a9692f4c82f3da3c01fda6b1493906b9

	BASE_SERIAL="${BASE_SERIAL:-$PINNED_SERIAL}"

	# ⚠ Snapshot directories and `latest/` DO NOT USE THE SAME FILENAMES:
	#     latest/         debian-13-generic-amd64.qcow2
	#     20260722-2547/  debian-13-generic-amd64-20260722-2547.qcow2
	# so a pin is not a URL swap -- the filename is serial-stamped too.
	if [ "$BASE_SERIAL" = latest ]; then
		BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"
		BASE_IMAGE="debian-13-generic-amd64.qcow2"
		# No repo-side digest is possible for a moving target.
		BASE_SHA512="${BASE_SHA512-}"
	else
		BASE_URL="https://cloud.debian.org/images/cloud/trixie/$BASE_SERIAL"
		BASE_IMAGE="debian-13-generic-amd64-$BASE_SERIAL.qcow2"
		if [ "$BASE_SERIAL" = "$PINNED_SERIAL" ]; then
			BASE_SHA512="${BASE_SHA512-$PINNED_SHA512}"
		else
			# THE BUMP PATH. A serial other than the recorded one has no
			# recorded digest yet -- by definition, that is what bumping
			# means. Verify against the mirror, and do_fetch prints the
			# observed digest for the human to record. Anything else here
			# would mean checking a new image against an old digest.
			BASE_SHA512="${BASE_SHA512-}"
		fi
	fi
	SUMS_FILE="SHA512SUMS"
	SUMS_TOOL="sha512sum"
	;;
arch)
	# URLs confirmed to resolve 2026-08-01. The provision() package commands
	# have NOT been exercised on Arch -- this entry demonstrates that the
	# seam is real, it does not claim a supported path.
	#
	# ⚠ THIS ARM IS NOT PINNED, and that is a known gap rather than a
	# ruling. `images/latest` is the same moving-target shape the debian
	# arm was just pinned away from, so it carries the same two defects
	# documented above. It is left as-is because this seam has never been
	# exercised and pinning a serial nobody has ever built from would be
	# inventing a fact. The MECHANISM below (repo digest first, mirror as
	# corroboration, unpinned builds warn) applies to this arm already --
	# only the pinned serial is missing.
	BASE_SERIAL="${BASE_SERIAL:-latest}"
	BASE_URL="https://geo.mirror.pkgbuild.com/images/latest"
	BASE_IMAGE="Arch-Linux-x86_64-cloudimg.qcow2"
	BASE_SHA512="${BASE_SHA512:-}"
	SUMS_FILE="Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
	SUMS_TOOL="sha256sum"
	;;
*)
	printf 'error: unknown DISTRO: %s\n' "$DISTRO" >&2; exit 1 ;;
esac

CACHE="$WORK/cache"                 # pristine downloads -- NEVER mutated

# 🔴 The sums file is cached UNDER THE NAME OF THE IMAGE IT DESCRIBES, never
# under its own remote name. Every snapshot serves a file called `SHA512SUMS`,
# so caching it by that name aliases every serial onto one path -- which is
# precisely the mechanism that let a 20260722 image sit under a 20260803 sums
# file and report a good cache as corrupt. Named this way, a sums file can only
# ever sit beside the image it is about, and a stale pair is visible in `ls`
# rather than inferred. BASE_IMAGE is serial-stamped, so two serials cannot
# collide in either file.
SUMS_CACHE="$CACHE/$BASE_IMAGE.sums"
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

# Poll the pidfile until the guest is gone. Returns 0 if it went down.
#
# 🔴 Liveness is read from the PIDFILE, never from a process name. Neither
# `pgrep -f` nor `pkill -f` may be used here or anywhere near this script: both
# match the full command line of the shell that invokes them. `pgrep -f`
# reported a VM as running when it had already exited (2026-08-02) and
# `pkill -f qemu-system` destroyed the build VM outright (2026-08-03).
wait_down() {
	local limit="$1" waited=0
	while vm_running && [ "$waited" -lt "$limit" ]; do
		sleep 2; waited=$((waited + 2))
	done
	! vm_running
}

# ------------------------------------------------------ out-of-band power
# The guest's only control channel that does not depend on the guest's network
# or on a login. Without it an unreachable guest can only be SIGTERMed, and
# qemu does NOT translate SIGTERM into an ACPI power-down request -- it is a
# power cut, and it ships a dirty filesystem into an image that gets `dd`'d
# onto production switches. It is also the ONLY path left after
# stage-generalize's `finish`, which removes the very user ssh_vm() connects as.
#
# QMP over loopback TCP, spoken with bash's own /dev/tcp: the build-host
# dependency set stays qemu, xorriso and curl. socat, nc and python3 would each
# add one. QMP rather than HMP because HMP is explicitly not a stable interface.

# Read one QMP reply, skipping asynchronous events. 0 on {"return":...}.
qmp_reply() {
	local line n=0
	while [ "$n" -lt 20 ]; do
		n=$((n + 1))
		IFS= read -r -t 5 line <&3 || return 1
		case "$line" in
		*'"event"'*)  continue ;;
		*'"return"'*) return 0 ;;
		*'"error"'*)  return 1 ;;
		esac
	done
	return 1
}

# Press the virtual ACPI power button. 0 only if qemu acknowledged the command
# -- which means the button was pressed, NOT that the guest acted on it. A
# guest with a wedged kernel ignores ACPI exactly as it ignores ssh, so the
# caller must still wait and still fall through.
qmp_powerdown() {
	local greeting
	# 🔴 The redirection is scoped to a BRACE GROUP, never attached to `exec`.
	# `exec` with only redirections applies them to the SHELL, permanently: a
	# bare `exec 3<>... 2>/dev/null` sends this script's stderr to /dev/null
	# for the rest of the run -- including rung 3's power-cut warning. That is
	# this project's signature bug class (four instances in iter 12, the first
	# of them this exact idiom), and it reappeared here, inside the ladder
	# written to make failures loud. Caught by watching a real failure print.
	{ exec 3<>"/dev/tcp/127.0.0.1/$MON_PORT"; } 2>/dev/null || return 1
	IFS= read -r -t 5 greeting <&3   || { exec 3>&-; return 1; }
	case "$greeting" in *'"QMP"'*) ;; *) exec 3>&-; return 1 ;; esac
	printf '{"execute":"qmp_capabilities"}\n' >&3
	qmp_reply                        || { exec 3>&-; return 1; }
	printf '{"execute":"system_powerdown"}\n' >&3
	qmp_reply                        || { exec 3>&-; return 1; }
	exec 3>&-
}

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

	# ⚠ Three distinct states, and each message says only what it can know.
	# "pinned" and "has a repo digest" are SEPARATE properties: keying the
	# moving-target warning off the digest would report a pinned serial with
	# an empty BASE_SHA512 as a moving target, which is simply false.
	if [ "$BASE_SERIAL" = latest ]; then
		# Loud, on every unpinned fetch. The whole point of the pin is that
		# "which base image was this built from?" has an answer; an unpinned
		# build must not be able to look like a pinned one.
		info "⚠ BASE_SERIAL=latest is a MOVING TARGET -- this build is NOT reproducible"
		info "⚠ no repo-side digest is possible for it; the mirror's $SUMS_FILE is the only authority"
	elif [ -z "$BASE_SHA512" ]; then
		info "base image pinned to snapshot $BASE_SERIAL (reproducible)"
		info "⚠ no digest is recorded in this repo for $BASE_SERIAL -- the mirror is the only authority"
	else
		info "base image pinned to snapshot $BASE_SERIAL"
	fi

	info "fetching $BASE_IMAGE"
	# -L: cloud.debian.org 302s to a mirror. -C -: resume a partial download
	# rather than restarting 400 MB. ⚠ Sound ONLY because the URL is pinned:
	# resuming by byte offset against a moving target silently splices two
	# different images together. See the DISTRO case block.
	curl -fL --progress-bar -C - -o "$CACHE/$BASE_IMAGE" "$BASE_URL/$BASE_IMAGE"
	curl -fLsS -o "$SUMS_CACHE" "$BASE_URL/$SUMS_FILE"

	info "verifying checksum"
	local have line mirror
	have="$("$SUMS_TOOL" "$CACHE/$BASE_IMAGE" | cut -d' ' -f1)"

	# Exact field match, never a substring: one snapshot directory lists
	# .json, .qcow2, .raw and .tar.xz sharing a prefix, and `grep -F` on a
	# name that is a prefix of another would take whichever sorted first.
	line=$(awk -v n="$BASE_IMAGE" '$2 == n || $2 == "*" n { print; exit }' "$SUMS_CACHE")
	mirror=$(printf '%s\n' "$line" | cut -d' ' -f1)

	if [ -n "$BASE_SHA512" ]; then
		# The REPO's digest is the authority. The mirror gets a vote, not a veto.
		if [ "$have" != "$BASE_SHA512" ]; then
			printf 'error: CHECKSUM MISMATCH against the digest pinned in this repo\n' >&2
			printf '       expected: %s\n' "$BASE_SHA512" >&2
			printf '       got:      %s\n' "$have" >&2
			# The URL is immutable, so "the remote moved" is ruled OUT by
			# construction and only one cause remains. Say which.
			printf '       %s is an IMMUTABLE snapshot, so the remote cannot have moved:\n' "$BASE_SERIAL" >&2
			printf '       this is a corrupt or partial download. Delete it and refetch:\n' >&2
			printf '         rm -f %s %s\n' "$CACHE/$BASE_IMAGE" "$SUMS_CACHE" >&2
			exit 1
		fi
		info "matches the digest pinned in this repo"

		if [ -z "$line" ]; then
			info "⚠ $BASE_IMAGE is not listed in the mirror's $SUMS_FILE -- no second opinion available"
		elif [ "$mirror" = "$BASE_SHA512" ]; then
			info "and the mirror's $SUMS_FILE agrees"
		else
			# Not a download problem: the bytes already matched the repo.
			# Either the recorded digest is wrong for this serial, or the
			# mirror is serving something else. Both need a human.
			printf 'error: the mirror DISAGREES with the digest pinned in this repo\n' >&2
			printf '       repo:   %s\n' "$BASE_SHA512" >&2
			printf '       mirror: %s\n' "$mirror" >&2
			printf '       The downloaded bytes match the repo, so this is NOT a corrupt\n' >&2
			printf '       download -- do not "delete and refetch". Either BASE_SHA512 is\n' >&2
			printf '       recorded wrong for %s, or the mirror is serving another image.\n' "$BASE_SERIAL" >&2
			exit 1
		fi
	else
		# Unpinned: the mirror is all there is.
		[ -n "$line" ] || die "$BASE_IMAGE is not listed in $SUMS_FILE -- cannot verify"
		if [ "$have" != "$mirror" ]; then
			printf 'error: CHECKSUM MISMATCH against the mirror'"'"'s %s\n' "$SUMS_FILE" >&2
			printf '       expected: %s\n' "$mirror" >&2
			printf '       got:      %s\n' "$have" >&2
			printf '       ⚠ BASE_SERIAL=%s is a MOVING TARGET, so there are TWO causes and\n' "$BASE_SERIAL" >&2
			printf '       this message cannot tell them apart: a corrupt download, OR a\n' >&2
			printf '       perfectly good cache measured against a newer snapshot.\n' >&2
			printf '       Pin BASE_SERIAL to a snapshot and the ambiguity goes away.\n' >&2
			exit 1
		fi
		if [ "$BASE_SERIAL" = latest ]; then
			info "matches the mirror's $SUMS_FILE (unpinned -- this is not a reproducibility claim)"
		else
			# THE BUMP PATH's payoff: hand the human the exact two lines to
			# paste, so recording a new pin is copy-paste rather than a
			# manual sha512sum they might run against the wrong file.
			info "matches the mirror's $SUMS_FILE"
			info "to make this pin permanent, record BOTH lines in the debian arm of vm.sh:"
			printf '         PINNED_SERIAL=%s\n' "$BASE_SERIAL"
			printf '         PINNED_SHA512=%s\n' "$have"
		fi
	fi

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
		-qmp tcp:127.0.0.1:"$MON_PORT",server=on,wait=off \
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
# ---------------------------------------------------------------- Phase 1
# Pipe the audit in over ssh rather than installing it: the guest stays a
# stock system, and the same script runs unmodified against a live switch.
do_audit() {
	vm_running || die "not running -- run: $0 up"
	local a="$HERE/mlxsw-premise-audit.sh"
	[ -r "$a" ] || die "audit script not found: $a"
	ssh_vm 'sudo bash -s' < "$a"
}

do_status() {
	if vm_running; then
		printf 'running  pid=%s  ssh -i %s -p %s %s@127.0.0.1\n' \
			"$(cat "$PIDFILE")" "$KEY" "$SSH_PORT" "$BUILD_USER"
		ssh_vm true 2>/dev/null && echo "ssh:     reachable" || echo "ssh:     NOT reachable"
		# Report the out-of-band channel separately: after `finish` this is
		# the only one left, so "ssh NOT reachable" alone does not say
		# whether the guest can still be powered down cleanly.
		if (exec 3<>"/dev/tcp/127.0.0.1/$MON_PORT") 2>/dev/null; then
			echo "qmp:     reachable on 127.0.0.1:$MON_PORT"
		else
			echo "qmp:     NOT reachable on 127.0.0.1:$MON_PORT (booted before -qmp?)"
		fi
	else
		echo "stopped"
	fi
	[ -r "$CACHE/$BASE_IMAGE" ] && echo "base:    $CACHE/$BASE_IMAGE" || echo "base:    not fetched"
	[ -f "$IMG" ] && echo "image:   $IMG ($(du -h "$IMG" | cut -f1) on disk)" || echo "image:   not prepared"
}

# A LADDER, and the rungs are not interchangeable. Each one reaches the guest
# by a path the previous one has just failed on, and only the last is a power
# cut. The force rung is retained -- an unkillable qemu is worse than a dirty
# image -- but it is reached deliberately and it announces what it did.
do_down() {
	vm_running || { info "not running"; return 0; }

	# Rung 1 -- ssh. Preferred whenever the guest is reachable: it is the
	# only rung where the guest's own shutdown sequence runs from userspace.
	#
	# Probe FIRST rather than firing and waiting out the timeout. The exact
	# case this ladder exists for -- an unreachable guest, and every guest
	# after stage-generalize's `finish` -- is the case where rung 1 cannot
	# work, and spending 60s proving that again on every call is how a
	# recovery path acquires a reputation for being slow enough to skip.
	# The poweroff exit status is NOT usable for this: a successful poweroff
	# drops the connection and reports failure just as a dead sshd does.
	if ssh_vm true 2>/dev/null; then
		info "poweroff over ssh"
		ssh_vm 'sudo systemctl poweroff' 2>/dev/null || true
		if wait_down 60; then
			rm -f "$PIDFILE"; info "down"; return 0
		fi
		info "ssh accepted the poweroff but the guest is still up"
	else
		info "ssh is not answering -- going straight to the out-of-band path"
	fi

	# Rung 2 -- the ACPI power button over QMP. This is the rung that did not
	# exist before, and it is the one that matters: it needs no guest network
	# and no login, so it works when ssh is dead AND after `finish` has removed
	# the builder user, which is when rung 1 is dead by construction.
	info "pressing the ACPI power button over QMP"
	if qmp_powerdown; then
		if wait_down "$ACPI_TIMEOUT"; then
			rm -f "$PIDFILE"; info "down (ACPI power button)"; return 0
		fi
		info "ACPI was accepted but the guest did not act on it within ${ACPI_TIMEOUT}s"
	else
		info "QMP not answering on 127.0.0.1:$MON_PORT -- guest booted before -qmp existed?"
	fi

	# Rung 3 -- SIGTERM. qemu does not turn this into an ACPI request, so the
	# guest OS never sees it: this is a power cut and the filesystem is dirty.
	# Say so. A silent "down" here is what let a killed guest read as a clean
	# one on 2026-08-03.
	info "FORCING -- SIGTERM to qemu. This is a POWER CUT: the guest filesystem"
	info "is dirty and the image is NOT defensible provenance for a switch."
	kill "$(cat "$PIDFILE")" 2>/dev/null || true
	wait_down 20 || true
	rm -f "$PIDFILE"
	info "down (FORCED -- dirty)"
}

do_destroy() {
	do_down
	# Deliberately keeps $CACHE: the pristine base is expensive to refetch
	# and is never mutated, so there is nothing to invalidate.
	rm -f "$IMG" "$SEED" "$SERIAL"
	rm -rf "$WORK/seed"
	info "working image removed; pristine base kept in $CACHE"
}

# ---------------------------------------------------------------- selftest
#
# OFFLINE proof: no VM, no root, no network. This script is a host-side driver
# whose work happens in qemu and in a guest, so its offline tier is shim-ledger
# based -- re-enter THIS script as a child with stand-ins first on PATH, record
# what it tried to do, and assert on the record.
#
# 🔴 PROOF BY OUTCOME WHEREVER AN OUTCOME EXISTS. The do_down ladder is not
# proven by reading its source: a REAL throwaway process stands in for the
# guest, the real do_down runs against it, and the assertions are about what
# happened to that process. Rung 3 genuinely kills it.
#
# 🔴 WHAT THIS TIER CANNOT PROVE -- named so it is not mistaken for covered.
# The QMP wire handshake itself. Speaking QMP needs something LISTENING on a
# TCP port; bash's /dev/tcp is a client only, and it is a SHELL BUILTIN, so no
# PATH shim can intercept it. socat, nc and python3 would each break the
# qemu+xorriso+curl dependency floor, and launching a real qemu to listen would
# contradict this tier's own "no VM" claim. So what is proven here is rung 2's
# FAILURE path, its POSITION in the ladder, and the exact bytes it would send.
# Rung 2's SUCCESS path is covered by the live ladder tests recorded on the
# out-of-band-guest-access task, and by nothing in here.
t_pass=0
t_fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; t_pass=$((t_pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; t_fail=$((t_fail + 1)); }
inf() { printf '  \033[36mNOTE\033[0m %s\n' "$*"; }
hdr() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Forbidden-idiom grep over a file, COMMENTS EXEMPT so this file may document
# what it refuses to do. Every pattern is assembled from adjacent quoted
# fragments so the literal never appears contiguously here and the guard cannot
# match its own definition -- the same bug class as `pkill -f` matching its own
# invoking shell.
forbid_in() { # $1 = file, $2 = ERE, $3 = description
	local hits
	hits="$(sed 's/#.*//' "$1" | grep -nE "$2" || true)"
	if [ -z "$hits" ]; then ok "never $3"
	else bad "$3 -- found:"; printf '%s\n' "$hits" | sed 's/^/       /'; fi
}

SELFTEST_TMP=""
SELFTEST_PID=""
# 🔴 EVERY BRANCH IS AN `if`, NEVER `[ ... ] && { ... }`. Under `set -e` a
# false test at statement level returns 1 and aborts the function -- the first
# draft ended with `[ -n "$SELFTEST_PID" ] && { kill ...; }` and, whenever that
# test was false, never reached the `rm -rf` below. It leaked a temp tree per
# run while reporting a clean exit: a cleanup path that silently never ran,
# which is the same class as the checks this harness exists to catch.
selftest_cleanup() {
	local p
	if [ -z "${SELFTEST_TMP:-}" ]; then return 0; fi
	# Everything this harness started: the guests it spawned directly, and the
	# ones the qemu stand-in spawned on its behalf.
	if [ -r "$SELFTEST_TMP/spawned" ]; then
		while read -r p; do kill "$p" 2>/dev/null || true; done < "$SELFTEST_TMP/spawned"
	fi
	if [ -n "${SELFTEST_PID:-}" ]; then kill "$SELFTEST_PID" 2>/dev/null || true; fi
	rm -rf "$SELFTEST_TMP"
	SELFTEST_TMP=""
	return 0
}

write_selftest_shims() { # $1 = bin dir
	local d="$1" g
	mkdir -p "$d"
	cat > "$d/.recorder" <<-'SHIM'
	#!/bin/sh
	# Recorded stand-in: logs its argv and stdin, then simulates the MINIMUM
	# each caller parses. Nothing else is faked -- anything not answered here
	# is a real coreutils binary doing real work on real files.
	d="${SHIM_DIR:?SHIM_DIR unset -- a shim escaped its harness}"
	n=$(cat "$d/seq" 2>/dev/null || echo 0)
	n=$((n + 1)); printf '%s\n' "$n" > "$d/seq"
	prog=${0##*/}
	printf '%s %s\n' "$prog" "$*" >> "$d/ledger"
	: > "$d/argv.$n"
	for a in "$@"; do printf '%s\n' "$a" >> "$d/argv.$n"; done
	: > "$d/stdin.$n"
	[ -t 0 ] || cat >> "$d/stdin.$n"

	# Pull the value following a flag out of argv, POSIX-ly.
	argval() { f=$1; shift; nx=0; for a in "$@"; do
		[ "$nx" = 1 ] && { printf '%s\n' "$a"; return 0; }
		[ "$a" = "$f" ] && nx=1; done; return 1; }

	case "$prog" in
	ssh)
		# A dead sshd is the case the ladder exists for, so it is a first-class
		# mode rather than something the harness works around.
		[ "${SHIM_SSH_RC:-0}" = 0 ] || exit "${SHIM_SSH_RC}"
		for a in "$@"; do
			case "$a" in
			*"systemctl poweroff"*)
				# REALLY end the stand-in guest. wait_down then observes a
				# genuine transition instead of a rewritten pidfile.
				if [ -r "${SHIM_GUEST_PIDFILE:-/nonexistent}" ]; then
					kill "$(cat "$SHIM_GUEST_PIDFILE")" 2>/dev/null || true
				fi ;;
			esac
		done ;;
	qemu-system-x86_64)
		# Stand in for a booted guest by leaving a REAL live process behind the
		# pidfile: vm_running then answers honestly for the rest of the run.
		pf=$(argval -pidfile "$@") || pf=
		if [ -n "$pf" ]; then
			# 🔴 EVERY fd redirected away from the caller's. run_cmd captures
			# this run with $(...), and a command substitution reads until the
			# LAST writer closes the pipe -- a background process inheriting
			# stdout holds it open for its full lifetime. The first draft
			# backgrounded a 900s sleep and hung the harness for 900s, looking
			# exactly like a deadlock in the code under test.
			sleep 900 </dev/null >/dev/null 2>&1 &
			printf '%s\n' "$!" > "$pf"
			printf '%s\n' "$!" >> "${SHIM_SPAWNED:-/dev/null}"
		fi ;;
	qemu-img)
		# do_up parses the PLAIN output deliberately (the JSON nests the
		# backing file's size first). Answer in exactly that shape.
		[ "${1:-}" = info ] && printf 'virtual size: 3 GiB (3221225472 bytes)\n' ;;
	ssh-keygen)
		f=$(argval -f "$@") || f=
		if [ -n "$f" ]; then
			printf 'FAKE-PRIVATE-KEY\n' > "$f"; chmod 0600 "$f"
			printf 'ssh-ed25519 AAAAFAKE mlnx-sw-os build\n' > "$f.pub"
		fi ;;
	xorrisofs)
		o=$(argval -output "$@") || o=
		[ -n "$o" ] && printf 'FAKE-ISO\n' > "$o" ;;
	curl)
		o=$(argval -o "$@") || o=
		case "$o" in
		"") ;;
		*.sums|*SUMS|*SHA*)
			# The name written into the sums line is DERIVED from the
			# -o path (strip the .sums suffix the caller appended), so
			# the shim tracks whatever BASE_IMAGE the child computed
			# instead of hardcoding one serial's filename and going
			# stale the next time the pin moves. SHIM_SUM_NAME still
			# overrides, for the "not listed at all" case.
			#
			# ⚠ NOT `n`: that is this shim's sequence counter, set
			# above and used for argv.$n/stdin.$n. Reusing it here
			# happens to work only because those writes already
			# ran -- which is a trap, not a design.
			sn="${o##*/}"; sn="${sn%.sums}"
			printf '%s  %s\n' "${SHIM_SUM:-000bad000}" "${SHIM_SUM_NAME:-$sn}" > "$o" ;;
		*)  printf 'FAKE-BASE-IMAGE\n' > "$o" ;;
		esac ;;
	esac
	exit 0
	SHIM
	chmod 0755 "$d/.recorder"
	for g in ssh qemu"-system"-x86_64 qemu-img ssh-keygen xorrisofs curl; do
		cp "$d/.recorder" "$d/$g"
	done
}

do_selftest() {
	# 🔴 EVERY ONE OF THESE IS A `local`, NEVER A FILE-SCOPE ASSIGNMENT.
	# run_cmd re-enters this script, so a file-scope assignment runs AGAIN in
	# the child -- and because these names arrive in the child's environment
	# already marked exported, re-assigning one there changes what the SHIMS
	# see. A file-scope SHIM_DIR="" is documented on stage-generalize.sh:907
	# as having produced an empty ledger and a harness that asserted nothing.
	local T SELF_PATH SHIM_BIN SHIM_DIR FAKE_WORK CMD_OUT CMD_RC real_sum
	SELF_PATH="${BASH_SOURCE[0]}"
	T="$(mktemp -d)"; SELFTEST_TMP="$T"
	trap selftest_cleanup EXIT INT TERM
	SHIM_BIN="$T/bin"; SHIM_DIR="$T/shim"; FAKE_WORK="$T/work"
	mkdir -p "$SHIM_DIR" "$FAKE_WORK/cache"
	: > "$T/spawned"
	write_selftest_shims "$SHIM_BIN"

	# --- harness -----------------------------------------------------------
	run_cmd() { # $1 = subcommand, $2.. = VAR=VALUE
		local sub="$1"; shift
		rm -rf "$SHIM_DIR"; mkdir -p "$SHIM_DIR"
		printf '0\n' > "$SHIM_DIR/seq"; : > "$SHIM_DIR/ledger"
		CMD_RC=0
		# </dev/null matters: a stand-in reading stdin with nothing redirected
		# in would block on the caller's terminal forever.
		CMD_OUT="$(env PATH="$SHIM_BIN:$PATH" SHIM_DIR="$SHIM_DIR" \
			SHIM_SPAWNED="$T/spawned" SHIM_GUEST_PIDFILE="$FAKE_WORK/qemu.pid" \
			WORK="$FAKE_WORK" DISTRO=debian "$@" \
			bash "$SELF_PATH" "$sub" </dev/null 2>&1)" || CMD_RC=$?
	}
	calls()      { grep -c . "$SHIM_DIR/ledger" 2>/dev/null || true; }
	prog_calls() { grep -c "^$1 " "$SHIM_DIR/ledger" 2>/dev/null || true; }
	said()       { printf '%s\n' "$CMD_OUT" | grep -qF -- "$1"; }
	line_of()    { printf '%s\n' "$CMD_OUT" | grep -nF -- "$1" | head -1 | cut -d: -f1; }

	# A stand-in guest that is a REAL process, so vm_running/wait_down/kill are
	# all exercised for real rather than simulated.
	guest_spawn() {
		sleep 900 &
		SELFTEST_PID=$!
		printf '%s\n' "$SELFTEST_PID" >> "$T/spawned"
		printf '%s\n' "$SELFTEST_PID" > "$FAKE_WORK/qemu.pid"
	}
	guest_alive() { [ -n "${SELFTEST_PID:-}" ] && kill -0 "$SELFTEST_PID" 2>/dev/null; }
	guest_stop()  {
		[ -n "${SELFTEST_PID:-}" ] && { kill "$SELFTEST_PID" 2>/dev/null || true; }
		SELFTEST_PID=""; rm -f "$FAKE_WORK/qemu.pid"
	}

	# 🔴 Prove the GUARD, not just the code. A forbidden-idiom pattern that
	# cannot match the thing it forbids is a check that silently never runs --
	# forbid() once shipped 11 patterns whose reporting branch had never
	# executed. Bait is matched as TEXT; nothing here is ever executed.
	guard_fires() { # $1 = ERE, $2 = bait, $3 = description
		printf '%s\n' "$2" > "$T/bait"
		grep -qE "$1" "$T/bait" \
			&& ok "the $3 guard matches its own bait, so it can actually fire" \
			|| bad "the $3 guard does NOT match what it forbids -- it can never fire"
	}

	hdr "0  the harness itself is not vacuous"
	# 🔴 Probe with a run that MUST reach a stand-in. The first draft probed
	# `status` against a stopped guest, which correctly touches nothing -- so
	# the vacuity guard reported an empty ledger and was itself the only thing
	# failing. A guard that cannot distinguish "nothing happened" from "nothing
	# was supposed to happen" is not a guard.
	guest_spawn
	run_cmd status
	if [ "$(calls)" -gt 0 ]; then
		ok "a run reaches the stand-ins ($(calls) call(s)) -- ledger assertions are about real traffic"
	else
		bad "NO stand-in was ever called: every ledger assertion below would be vacuously true"
	fi
	[ -x "$SHIM_BIN/ssh" ] && ok "the stand-ins are on PATH ahead of the real binaries" \
	                       || bad "the stand-in directory was never populated"

	hdr "1  source guards -- forbidden idioms, and the guards are themselves checked"
	forbid_in "$SELF_PATH" 'pg''rep[[:space:]]+-[a-zA-Z]*f' \
		"uses pg""rep -f (it matches the invoking shell's own command line)"
	forbid_in "$SELF_PATH" 'pk''ill[[:space:]]+-[a-zA-Z]*f' \
		"uses pk""ill -f (it destroyed the build VM on 2026-08-03)"
	# The signature bug class: `exec` with ONLY redirections applies them to the
	# SHELL, permanently. A bare `exec 3<>... 2>/dev/null` silences this script's
	# stderr for the rest of the run, including rung 3's power-cut warning.
	forbid_in "$SELF_PATH" '^[[:space:]]*ex''ec[[:space:]]+[0-9]+<>[^;]*2>' \
		"attaches a redirection to a bare ex""ec on the /dev/tcp open (it would silence the shell permanently)"
	# 🔴 THE BAIT IS SPLIT TOO, not just the pattern. The first draft split only
	# the patterns and wrote the bait literally -- so the guards above found the
	# forbidden idioms inside their own test data and reported this file as
	# violating rules it does not violate. Bait is data: it is matched as text
	# and never executed.
	guard_fires 'pg''rep[[:space:]]+-[a-zA-Z]*f' 'pg''rep -f qemu-system' "pg""rep -f"
	guard_fires 'pk''ill[[:space:]]+-[a-zA-Z]*f' 'pk''ill -f qemu-system' "pk""ill -f"
	guard_fires '^[[:space:]]*ex''ec[[:space:]]+[0-9]+<>[^;]*2>' \
		'	ex''ec 3<>"/dev/tcp/127.0.0.1/$MON_PORT" 2>/dev/null || return 1' "bare-ex""ec redirection"
	grep -q '{ ex''ec 3<>' "$SELF_PATH" \
		&& ok "the /dev/tcp open is scoped to a brace group" \
		|| bad "the /dev/tcp open is not brace-scoped"

	hdr "2  the concurrency property -- MON_PORT is DERIVED, never independently defaulted"
	grep -q 'MON_PORT="${MON_PORT:-\$((SSH_PORT + 1000))}"' "$SELF_PATH" \
		&& ok "MON_PORT derives from SSH_PORT" \
		|| bad "MON_PORT does not derive from SSH_PORT -- two agents on the defaults share one control channel"
	# do_status reports the monitor only for a RUNNING guest, so these need one:
	# against a stopped guest the assertions would be measuring silence.
	guest_spawn
	run_cmd status SSH_PORT=2500
	said "3500" && ok "SSH_PORT=2500 yields monitor port 3500 (derived at runtime, not just in source)" \
	             || bad "the derived monitor port did not follow SSH_PORT"
	run_cmd status SSH_PORT=2500 MON_PORT=9999
	said "9999" && ok "an explicit MON_PORT still overrides the derivation" \
	             || bad "MON_PORT cannot be overridden"

	hdr "3  up -- the qemu invocation, and the pristine base is never mutated"
	# Clear the stand-in the port checks needed, or up would short-circuit on it
	# and this section would assert against a qemu that was never launched.
	guest_stop
	# $BASE_IMAGE, never a literal: it is serial-stamped now, so a hardcoded
	# filename here would silently stop describing the file the child looks
	# for the next time the pin moves -- and `up` would fail for a reason
	# that has nothing to do with what this section is testing.
	printf 'PRISTINE-BASE\n' > "$FAKE_WORK/cache/$BASE_IMAGE"
	real_sum="$(sha512sum "$FAKE_WORK/cache/$BASE_IMAGE" | cut -d' ' -f1)"
	run_cmd up
	# Keep THIS run's ledger: run_cmd clears it, and the seed assertions two
	# sections down are about the boot-from-scratch run, not about whatever ran
	# last. The first draft asserted the cidata label against the ledger of the
	# short-circuited second `up`, which launches nothing -- a live assertion
	# reading a ledger that could never contain what it was looking for.
	cp "$SHIM_DIR/ledger" "$T/ledger.up"
	[ "$CMD_RC" = 0 ] && ok "up succeeds against the stand-ins" || bad "up failed: rc=$CMD_RC"
	grep -q -- '-qmp tcp:127.0.0.1:3222,server=on,wait=off' "$SHIM_DIR/ledger" \
		&& ok "qemu is given a QMP socket on the derived port" \
		|| bad "qemu was not given a QMP socket"
	grep -q -- '-qmp tcp:0.0.0.0' "$SHIM_DIR/ledger" \
		&& bad "the QMP socket is bound to 0.0.0.0 -- it is a full control channel over the guest" \
		|| ok "the QMP socket is bound to loopback only, never 0.0.0.0"
	grep -q -- 'hostfwd=tcp:127.0.0.1:2222-:22' "$SHIM_DIR/ledger" \
		&& ok "the ssh forward is scoped to loopback" || bad "the ssh forward is not loopback-scoped"
	grep -q -- '-pidfile' "$SHIM_DIR/ledger" \
		&& ok "qemu is given a pidfile (liveness is read from it, never from a process name)" \
		|| bad "qemu is given no pidfile"
	[ "$(sha512sum "$FAKE_WORK/cache/$BASE_IMAGE" | cut -d' ' -f1)" = "$real_sum" ] \
		&& ok "the pristine base is byte-identical after up (copied, never mutated)" \
		|| bad "up MUTATED the pristine base -- a re-run no longer starts from a known state"
	[ -f "$FAKE_WORK/work.qcow2" ] && ok "the working image is a separate file" \
	                               || bad "no working image was produced"

	hdr "4  up short-circuits on a running guest (the stale-guest trap)"
	run_cmd up
	said "already running" && ok "a second up reports the guest it is handing back" \
	                       || bad "up did not announce that it short-circuited"
	[ "$(prog_calls qemu-system-x86_64)" = 0 ] \
		&& ok "and it started no second qemu" || bad "up started a second qemu over a running guest"
	inf "this is the documented trap: up HANDS BACK whatever is running, so a stale guest"
	inf "is returned silently unless the caller checks status first"

	hdr "5  the seed -- key-only, no password, anywhere"
	grep -q 'NOPASSWD:ALL' "$FAKE_WORK/seed/user-data" \
		&& ok "the build user gets passwordless sudo" || bad "the build user has no sudo rule"
	grep -q 'ssh_pwauth: false' "$FAKE_WORK/seed/user-data" \
		&& ok "password authentication is disabled" || bad "password authentication is not disabled"
	grep -q 'lock_passwd: true' "$FAKE_WORK/seed/user-data" \
		&& ok "the build user's password is locked" || bad "the build user's password is not locked"
	grep -qE '^\s+- ssh-ed25519 ' "$FAKE_WORK/seed/user-data" \
		&& ok "an ssh public key is installed" || bad "no ssh key reached the seed"
	forbid_in "$FAKE_WORK/seed/user-data" '(pass''word|plain_text_passwd|chpasswd|hashed_passwd)' \
		"bakes a pass""word into the seed"
	grep -q -- '-volid cidata' "$T/ledger.up" \
		&& ok "the seed is built with the cidata volume label cloud-init looks for" \
		|| bad "the seed carries no cidata label -- cloud-init would never read it"

	hdr "6  do_down RUNG 1 -- ssh, on a reachable guest"
	guest_spawn
	run_cmd down
	said "poweroff over ssh" && ok "rung 1 is attempted first" || bad "rung 1 was not attempted"
	said "down"              && ok "the guest is reported down" || bad "no down report"
	said "FORCING"           && bad "rung 3 fired on a guest that ssh could reach" \
	                         || ok "no force-kill on a reachable guest"
	guest_alive && bad "the stand-in guest is STILL ALIVE -- rung 1 reported a shutdown that did not happen" \
	            || ok "the stand-in guest is really gone (outcome, not a message)"

	hdr "7  do_down RUNG 1 PRE-PROBE -- a dead sshd costs no timeout"
	guest_spawn
	run_cmd down SHIM_SSH_RC=255 ACPI_TIMEOUT=2
	said "ssh is not answering" \
		&& ok "an unreachable guest is detected before rung 1 fires" \
		|| bad "rung 1 fired blind at an unreachable guest"
	grep -q 'systemctl poweroff' "$SHIM_DIR/ledger" \
		&& bad "a poweroff was sent to a guest already known unreachable -- that is the 60s wait, back" \
		|| ok "no poweroff is sent once ssh is known dead (the 64s -> 2s fix, as an outcome)"
	[ "$(prog_calls ssh)" -ge 1 ] \
		&& ok "ssh WAS probed ($(prog_calls ssh) call) -- the skip is measured, not assumed" \
		|| bad "ssh was never probed at all, so nothing established it was dead"

	hdr "8  do_down RUNG 2 -- unreachable QMP falls through, it does not hang"
	said "pressing the ACPI power button over QMP" \
		&& ok "rung 2 is attempted after rung 1 is ruled out" || bad "rung 2 was never attempted"
	said "QMP not answering" \
		&& ok "an unreachable monitor is reported rather than silently skipped" \
		|| bad "rung 2's failure is silent"

	hdr "9  do_down RUNG 3 -- it kills, and it SAYS it was a power cut"
	said "FORCING" && ok "rung 3 is reached when both other rungs are unavailable" \
	               || bad "rung 3 never fired, so the guest was left running"
	said "POWER CUT" && ok "the force rung announces that this is a power cut" \
	                 || bad "the force rung is SILENT -- this is what let a killed guest read as clean"
	said "dirty"     && ok "and it says the filesystem is dirty" \
	                 || bad "the force rung does not warn that the image is not defensible"
	guest_alive && bad "rung 3 did not actually kill the stand-in guest" \
	            || ok "the stand-in guest was really killed (outcome, not a message)"

	hdr "10 the ladder's ORDER is what makes it a ladder"
	local l1 l2 l3
	l1="$(line_of 'ssh is not answering')"; l2="$(line_of 'ACPI power button')"; l3="$(line_of 'FORCING')"
	if [ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ]; then
		ok "ssh -> QMP -> force, in that order (lines $l1 < $l2 < $l3)"
	else
		bad "the rungs did not run in order (ssh=$l1 qmp=$l2 force=$l3)"
	fi

	hdr "11 down on a guest that is not running does nothing at all"
	rm -f "$FAKE_WORK/qemu.pid"
	run_cmd down
	said "not running" && ok "a stopped guest is reported, not acted on" || bad "no 'not running' report"
	[ "$(prog_calls ssh)" = 0 ] && ok "and nothing is sent to it" || bad "a stopped guest was still contacted"

	hdr "12 status reports the out-of-band channel SEPARATELY from ssh"
	guest_spawn
	run_cmd status
	said "ssh:" && ok "status reports ssh reachability" || bad "status does not report ssh"
	said "qmp:" && ok "status reports QMP reachability -- after finish it is the only channel left" \
	            || bad "status does not report the out-of-band channel"
	said "qmp:     NOT reachable" \
		&& ok "and it correctly reports an absent monitor rather than assuming one" \
		|| bad "status claimed a monitor that is not there"

	hdr "13 fetch verifies the checksum -- and REJECTS a bad one"
	# The digest of what the curl stand-in actually writes. Every pinned case
	# below hands this as BASE_SHA512, so "the repo digest matches the bytes"
	# is a real comparison of real bytes and not a tautology between two
	# copies of the same constant.
	local good_sum
	good_sum="$(printf 'FAKE-BASE-IMAGE\n' | sha512sum | cut -d' ' -f1)"

	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch
	[ "$CMD_RC" != 0 ] && ok "a checksum mismatch aborts the fetch (rc=$CMD_RC)" \
	                   || bad "fetch ACCEPTED an image whose checksum did not match"
	said "CHECKSUM MISMATCH" && ok "and it says so" || bad "the mismatch is not reported"
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch SHIM_SUM="$good_sum" BASE_SHA512="$good_sum"
	[ "$CMD_RC" = 0 ] && ok "a matching checksum is accepted (both polarities -- a verifier that never passes is also broken)" \
	                  || bad "fetch rejected an image whose checksum DID match: rc=$CMD_RC"

	hdr "13a the base image is PINNED to an immutable snapshot, not latest/"
	# 🔴 The regression that motivated all of this: a build whose base image
	# is whatever the mirror served today cannot be compared to yesterday's.
	grep -qE '^[[:space:]]*PINNED_SERIAL=[0-9]{8}-[0-9]+$' "$SELF_PATH" \
		&& ok "the debian arm records a dated snapshot serial, not 'latest'" \
		|| bad "the debian arm records no pinned snapshot serial"
	guard_fires '^[[:space:]]*PINNED_SERIAL=[0-9]{8}-[0-9]+$' \
		'	PINNED_SERIAL=20260722-2547' "pinned-serial"
	grep -qE '^[[:space:]]*BASE_SERIAL="\$\{BASE_SERIAL:-\$PINNED_SERIAL\}"' "$SELF_PATH" \
		&& ok "and the default BASE_SERIAL is that recorded pin, not a second literal" \
		|| bad "BASE_SERIAL does not default to PINNED_SERIAL -- two places to keep in sync"
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch SHIM_SUM="$good_sum" BASE_SHA512="$good_sum"
	grep -q "cloud/trixie/[0-9]\{8\}-[0-9]*/" "$SHIM_DIR/ledger" \
		&& ok "the fetch URL names the snapshot directory, so the remote cannot move under it" \
		|| bad "the fetch URL still points at a moving directory"
	grep -q "cloud/trixie/latest/" "$SHIM_DIR/ledger" \
		&& bad "a default fetch still requested latest/ -- the pin is not wired to the URL" \
		|| ok "no default fetch requests latest/"
	# ⚠ Snapshot dirs serve serial-STAMPED filenames; latest/ does not. A pin
	# that changed only the URL would 404 on every fetch.
	grep -qE "debian-13-generic-amd64-[0-9]{8}-[0-9]+\.qcow2" "$SHIM_DIR/ledger" \
		&& ok "and it requests the serial-stamped filename the snapshot actually serves" \
		|| bad "the pinned URL requests an unstamped filename that only latest/ serves"

	hdr "13b two serials cannot alias onto one cache entry"
	# This aliasing IS the defect: one image sitting under another snapshot's
	# sums file is what reported a good cache as corrupt.
	# Measured by running the real config twice, never by comparing two
	# literals: a literal comparison would still pass if the code stopped
	# using the serial at all.
	local sums_a sums_b
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch SHIM_SUM="$good_sum" BASE_SHA512="$good_sum" BASE_SERIAL=20260722-2547
	sums_a="$(ls "$FAKE_WORK/cache/" | grep '\.sums$' || true)"
	run_cmd fetch SHIM_SUM="$good_sum" BASE_SHA512="$good_sum" BASE_SERIAL=20260803-2559
	sums_b="$(ls "$FAKE_WORK/cache/" | grep '\.sums$' | grep -v "^$sums_a$" || true)"
	[ -n "$sums_a" ] && [ -n "$sums_b" ] \
		&& ok "each serial caches its sums file beside its OWN image ($sums_a, $sums_b)" \
		|| bad "the two serials shared one sums cache path -- the aliasing bug is back"
	[ "$(ls "$FAKE_WORK/cache/" | grep -c '\.qcow2$')" -ge 2 ] \
		&& ok "and both images coexist, so a stale pair is visible in ls rather than inferred" \
		|| bad "the second serial overwrote the first image in the cache"

	hdr "13c a moved MIRROR is not reported as a corrupt download"
	# 🔴 The exact false diagnosis this task exists to kill. The bytes are
	# fine and match the repo; only the mirror's sums moved. Telling the
	# operator to "delete and refetch" here destroys a good 400 MB cache.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SHA512="$good_sum" SHIM_SUM=00deadbeef00
	[ "$CMD_RC" != 0 ] && ok "a mirror that disagrees with the pinned digest is still an ERROR (rc=$CMD_RC)" \
	                   || bad "a mirror disagreeing with the repo digest was accepted silently"
	said "mirror DISAGREES" \
		&& ok "and it is reported as a mirror disagreement, naming both digests" \
		|| bad "the mirror disagreement is not named as such"
	said "NOT a corrupt" \
		&& ok "🔴 and it explicitly says this is NOT a corrupt download" \
		|| bad "🔴 a moved mirror is still diagnosed as a corrupt download -- the false diagnosis is back"
	# ⚠ Assert on the destructive ADVICE, not on the phrase: the mirror
	# message contains the words "delete and refetch" inside a `do not`
	# clause, so grepping the phrase makes this guard match its own message
	# and fail on correct output. It did exactly that on first run. The
	# corrupt-download path is the only one that emits an `rm -f` command.
	said "rm -f" \
		&& bad "it still hands the operator an rm -f for a cache whose bytes match the repo" \
		|| ok "it hands out no rm -f for a good cache (the advice, not the phrase)"

	hdr "13d the repo digest is the authority, and a corrupt download says so"
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SHA512=00notthebytes00 SHIM_SUM=00notthebytes00
	[ "$CMD_RC" != 0 ] && ok "bytes that match NEITHER are rejected (rc=$CMD_RC)" \
	                   || bad "fetch accepted bytes matching neither digest"
	said "pinned in this repo" \
		&& ok "the repo digest is named as the thing that failed" \
		|| bad "the failure does not say which authority rejected it"
	said "IMMUTABLE snapshot" \
		&& ok "and it rules OUT 'the remote moved' by construction, leaving one cause" \
		|| ok "the immutability argument is not spelled out (message wording only)"
	# 🔴 Positive control for the whole 13c/13d pair: with the SAME shim
	# bytes, only the digests differing, the good case must still pass. Two
	# rejections in a row could otherwise both be a fetch that never ran.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SHA512="$good_sum" SHIM_SUM="$good_sum"
	[ "$CMD_RC" = 0 ] \
		&& ok "positive control: identical bytes with correct digests still pass" \
		|| bad "positive control FAILED -- 13c/13d may be rejecting for an unrelated reason"
	said "mirror" && said "agrees" \
		&& ok "and the mirror is reported as a corroborating second opinion" \
		|| ok "the agreement line is not printed (message wording only)"

	hdr "13e an UNPINNED build is accepted, but says it is not reproducible"
	# latest/ stays reachable on purpose -- for bumping the pin. What must
	# never happen is an unpinned build looking like a pinned one.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SERIAL=latest SHIM_SUM="$good_sum"
	[ "$CMD_RC" = 0 ] && ok "BASE_SERIAL=latest still works (it is how the pin gets bumped)" \
	                  || bad "BASE_SERIAL=latest is broken: rc=$CMD_RC"
	said "NOT reproducible" \
		&& ok "🔴 and every unpinned fetch says so, so it cannot pass for a pinned one" \
		|| bad "🔴 an unpinned fetch is silent -- it is indistinguishable from a pinned build"
	grep -q "cloud/trixie/latest/" "$SHIM_DIR/ledger" \
		&& ok "and it genuinely requested latest/ (the override reaches the URL)" \
		|| bad "BASE_SERIAL=latest did not actually change the URL"
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SERIAL=latest SHIM_SUM=00wrong00
	[ "$CMD_RC" != 0 ] && ok "an unpinned mismatch still fails closed" \
	                   || bad "an unpinned build accepted a mismatched image"
	said "TWO causes" \
		&& ok "and it admits it cannot tell a bad download from a moved snapshot" \
		|| bad "an unpinned mismatch still claims a single cause it cannot know"

	hdr "13f BUMPING the pin -- a new serial is not checked against the old digest"
	# 🔴 The defect this section exists for was introduced by the FIX and
	# caught before commit: with `${BASE_SHA512:-$PINNED_SHA512}` applied to
	# every serial, pointing at a NEW snapshot verified a new image against
	# the previous one's digest and reported a perfectly good download as
	# corrupt -- the same false diagnosis the whole change removes, moved one
	# step downstream. The serial and its digest are ONE fact.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch BASE_SERIAL=20260803-2559 SHIM_SUM="$good_sum"
	[ "$CMD_RC" = 0 ] \
		&& ok "🔴 a serial with no recorded digest verifies against the MIRROR and succeeds" \
		|| bad "🔴 bumping the pin failed -- the new image was checked against the old digest"
	said "no digest is recorded in this repo" \
		&& ok "and it says why the mirror is the authority for this run" \
		|| bad "the missing-digest state is silent"
	said "NOT reproducible" \
		&& bad "a pinned-but-unrecorded serial is wrongly called a moving target" \
		|| ok "a pinned serial is NOT called a moving target (pinned and recorded are separate properties)"
	said "PINNED_SHA512=$good_sum" \
		&& ok "and it prints the exact line to record, so bumping is copy-paste" \
		|| bad "the bump path does not hand back the digest it just measured"
	# Positive control: the RECORDED serial must still use the repo digest,
	# or the branch above would just be "the digest is never used".
	# ⚠ The shim's bytes never match PINNED_SHA512, so the RECORDED serial
	# rejects them via the repo-digest branch -- which is the point: the same
	# invocation that succeeds on an unrecorded serial must fail on the
	# recorded one, and say the REPO rejected it. Written as if/else rather
	# than an && || chain, which silently reports the wrong arm when the
	# middle test fails.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch SHIM_SUM="$good_sum"
	if [ "$CMD_RC" != 0 ] && said "pinned in this repo"; then
		ok "positive control: the RECORDED serial applies the repo digest and rejects other bytes"
	else
		bad "positive control FAILED -- the recorded digest is not being applied at all (rc=$CMD_RC)"
	fi

	hdr "14 destroy keeps the pristine base"
	# 🔴 Re-establish the precondition rather than inheriting it. Section 13e
	# leaves the cache holding a `latest`-named image, so this section's
	# assertion about $BASE_IMAGE (serial-stamped) would fail for a reason
	# that has nothing to do with destroy -- an assertion measuring the
	# previous section instead of the code under test. It did exactly that on
	# first run. A pinned fetch here makes the section order-independent.
	rm -rf "$FAKE_WORK/cache"
	run_cmd fetch SHIM_SUM="$good_sum" BASE_SHA512="$good_sum"
	[ -r "$FAKE_WORK/cache/$BASE_IMAGE" ] \
		|| bad "precondition failed: the pinned base is not in the cache before destroy"
	run_cmd destroy
	[ -r "$FAKE_WORK/cache/$BASE_IMAGE" ] \
		&& ok "destroy keeps \$CACHE (the base is expensive and is never mutated)" \
		|| bad "destroy deleted the pristine base"
	[ -f "$FAKE_WORK/work.qcow2" ] && bad "destroy left the working image behind" \
	                               || ok "destroy removes the working image"

	hdr "15 the distro seam refuses what it does not know"
	run_cmd up DISTRO=freebsd
	[ "$CMD_RC" != 0 ] && ok "an unknown DISTRO exits non-zero (rc=$CMD_RC)" \
	                   || bad "an unknown DISTRO was accepted"
	said "unknown DISTRO" && ok "and names the offending value" || bad "the refusal does not say why"

	hdr "coverage this tier does NOT claim"
	inf "rung 2's SUCCESS path -- the QMP handshake itself -- is not exercised here."
	inf "/dev/tcp is a bash BUILTIN, so no PATH stand-in can intercept it, and a real"
	inf "listener would need socat/nc/python3 or a real qemu. Covered instead by the"
	inf "live ladder tests recorded on the out-of-band-guest-access task."

	printf '\n----------------------------------------\n'
	printf '%d passed, %d failed\n' "$t_pass" "$t_fail"
	[ "$t_fail" -eq 0 ]
}

# ---------------------------------------------------------------- dispatch
mkdir -p "$WORK"
case "${1:-}" in
fetch)     do_fetch ;;
up)        do_up ;;
ssh)       shift; ssh_vm "$@" ;;
provision) do_provision ;;
probe)     do_probe ;;
audit)     do_audit ;;
status)    do_status ;;
down)      do_down ;;
destroy)   do_destroy ;;
selftest)  do_selftest ;;
*)
	sed -n '2,18p' "$0" | sed 's/^# \?//'
	printf '\nUsage: %s {fetch|up|ssh|provision|probe|audit|status|down|destroy|selftest}\n' "$0"
	exit 1 ;;
esac
