#!/bin/bash
# S5 stage -- the switch RUNTIME CONTRACT: everything that has to be true of a
# booted switch that is not the kernel and not the driver.
#
# Eight things get installed, and each one is a separate authority:
#
#   A1  /etc/systemd/network/*                    the networkd unit set
#   A2  /etc/udev/rules.d/10-local.rules          front-panel port naming
#   A3  /etc/default/grub.d/20_switch-cmdline.cfg kernel cmdline + serial GRUB
#   A4  /etc/modules-load.d/mlxsw-sensors.conf    sensor modules (monitoring)
#   A5  mlxsw-dkms_6.12.100-1+deb13u1_all.deb     the driver package
#   A6  the package manifest                      required / preferred / EXCLUDED
#   A7  the user model                            root + johns, key-only
#   A8  service enablement                        networkd, resolved, timesyncd
#
# 🔴 THREE THINGS THIS STAGE MUST NEVER DO.
#
#   1. NEVER restart or reload systemd-networkd, and never `networkctl` a
#      reload either -- that is the same forbidden action wearing a different
#      name. This stage runs OVER THE NETWORK. Reconfiguring the network from
#      inside the network severs the control channel mid-stage and the guest
#      never comes back. The units are written and left alone; first boot
#      applies them, which is also exactly what happens on real hardware.
#   2. NEVER bake a password. Key-only auth, everywhere, always. The admin
#      account's password is LOCKED, which is why its sudoers drop-in must be
#      NOPASSWD -- see emit_sudoers() for the full argument.
#   3. NEVER touch the `builder` seed user. Another stage removes it, and
#      nothing here may make it un-removable. There is no reference to that
#      account anywhere below except the selftest assertion that proves it.
#
# 🔴 ASSERT BY OUTCOME. This project has shipped four separate "checks that
# silently never ran" (an `exec` with only redirections that muted the rest of
# the script; a `flock` on an unopened fd read as "lock held"; a space-anchored
# grep against TAB-delimited /proc/swaps; a `stat` that reports 0 bytes where
# `wc -c` reports 39). Every guard in here is therefore written as a PURE
# PREDICATE that takes its input as data, and `selftest` runs each one against
# input that must PASS *and* input that must FAIL. A guard that has never been
# watched to fail is not a guard.
#
# Modes:
#   run        HOST-SIDE. Ships this file and the repo payload into the guest
#              over `vm.sh ssh`, installs, proves idempotence, verifies.
#   install    does the work against $ROOT. In-guest as root, or offline
#              against a staged tree with --root DIR.
#   verify     asserts outcomes against $ROOT. Same dual mode.
#   fingerprint  sha256 of every file this stage owns -- the idempotence probe.
#   selftest   offline proof: no VM, no root, no network.
#
# Usage: stage-runtime-contract.sh [run|install|verify|fingerprint|selftest] [options]
set -euo pipefail

# ---------------------------------------------------------------- constants
NET_DIR="/etc/systemd/network"
UDEV_RULE="/etc/udev/rules.d/10-local.rules"
GRUB_DROPIN_DIR="/etc/default/grub.d"
GRUB_DROPIN_NAME="20_switch-cmdline.cfg"
MODLOAD_CONF="/etc/modules-load.d/mlxsw-sensors.conf"
ETC_MODULES="/etc/modules"
GRUBCFG="/boot/grub/grub.cfg"

# 🔴 THE EXACT FILENAME, MATCHED LITERALLY. mlnx-switch-packages/dkms/ holds
# THREE debs and `*.deb` matches all three. The other two --
# mlxsw-dkms_6.12.100-1_all.deb and mlxsw-dkms_6.1.177-1_all.deb -- are FROZEN
# reference blobs (the second is the package running on the live fleet) and
# must never be installed by any stage. If this ever has to become a glob it is
# `*+deb13u1_all.deb` with an assertion that exactly one file matches.
DKMS_DEB_REL="mlnx-switch-packages/dkms/mlxsw-dkms_6.12.100-1+deb13u1_all.deb"

# 🔴 The administrator account. Key-only, password LOCKED, sudo via a drop-in.
ADMIN_USER="johns"
ADMIN_HOME="/home/johns"
ADMIN_SHELL="/bin/bash"
# ⚠ NO DOT, NO TRAILING TILDE. sudo's #includedir skips any file whose name
# contains a '.' or ends in '~' -- silently, exactly like Debian's run-parts.
# A drop-in named 90-johns.conf would never be read and the account would have
# no sudo at all, with nothing anywhere saying so. is_valid_sudoers_name()
# below is the guard and the selftest watches it fail.
SUDOERS_DROPIN="/etc/sudoers.d/90-johns"

# Where `run` unpacks the repo payload inside the guest. /run is tmpfs: the
# payload never lands in the image and is gone at the next boot.
GUEST_PAYLOAD="/run/mlxsw-runtime-contract"

# ROOT is a PREFIX, never an identity. Empty means "this running system".
ROOT="${ROOT:-}"
# REPO is the repository root the assets and the .deb are read from. Empty
# means "not visible" -- the embedded copies are used and A5 is skipped.
REPO="${REPO:-}"
MODE="run"

# Resolve the repo only when this file is on disk. Piped over ssh as `bash -s`,
# BASH_SOURCE is not a readable path; --repo supplies it in that case and the
# embedded copies cover the case where nothing supplies it at all.
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
	[ -n "$REPO" ] || REPO="$(cd -- "$HERE/.." && pwd)"
fi

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
inf()  { printf '  \033[36mNOTE\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

rp() { printf '%s%s' "$ROOT" "$1"; }   # root-prefixed path

usage() {
	cat <<'USAGE'
Usage: stage-runtime-contract.sh [MODE] [options]

Modes:
  run            HOST-SIDE orchestration (default). Asserts the guest is up,
                 ships this script and the repo payload in over `vm.sh ssh`,
                 runs `install` twice to prove idempotence, then `verify`.
  install        install the runtime contract into $ROOT
  verify         assert the runtime contract holds in $ROOT
  fingerprint    print `sha256  path` for every file this stage owns, sorted.
                 Two runs of `install` must produce identical output.
  selftest       offline proof: no VM, no root, no network. Every guard is
                 exercised against input that must pass AND input that must
                 fail.

Options:
  -r, --root DIR   act on DIR instead of /, and skip everything that only means
                   something on a running system (apt, dkms, update-grub,
                   systemctl, useradd). Also settable as ROOT=DIR.
      --repo DIR   read assets/ and the .deb from DIR. Defaults to this
                   script's parent directory when it is on disk. When no repo
                   is visible the embedded asset copies are used and A5 (the
                   .deb) is skipped with a loud failure.
  -h, --help
USAGE
}
# ------------------------------------------------------- embedded asset copies
# 🔴 EMBEDDED COPIES, and assets/ is authoritative. Every function below is a
# byte-for-byte copy of a file under assets/ that this stage installs. They
# exist for exactly one reason: the vm.sh convention is
# `vm.sh ssh 'sudo bash -s' < script`, so a guest that has no repo checked out
# must still be stageable from this one file alone.
#
# 🔴 WHENEVER THE REPO IS VISIBLE THE REPO WINS -- see asset_*() below. These
# copies are the fallback, never the default, and check_asset_drift() proves
# they are identical to assets/ so a stale copy is LOUD instead of silent.
#
# 🔴 DO NOT HAND-EDIT THESE. assets/ is byte-frozen and owned by another
# member. To refresh a copy, re-derive it from the file in assets/; never the
# other way round.
#
# ⚠ The unit set is deliberately NOT a hardcoded list at install time. An
# earlier member split one .network file into two, and a hardcoded list drops
# new files silently. embedded_unit_names() is a fallback INVENTORY, and
# check_asset_drift() compares it as a SET against the glob of assets/ -- so an
# added, removed or renamed unit fails the selftest rather than vanishing.
embedded_unit_names() {
	cat <<'NAMES'
20-mgmt-bond.netdev
22-mgmt-bond.network
24-mgmt-bond.network
30-data.netdev
32-data.network
34-data.network
NAMES
}

embedded_unit() { # $1 = basename -> its bytes on stdout, or 1 if unknown
	case "$1" in
	20-mgmt-bond.netdev) cat <<'EOF_UNIT_1'
[NetDev]
Name=mgmt
Kind=bond

# The bond ships with no primary member, deliberately: both management NICs are
# bound by one intrinsic match, so no generic unit can single one of them out.
# Failover is therefore last-carrier-wins. The reselect policy that used to sit
# here was inert without a primary and has been removed rather than left in
# place reading as an active policy.
[Bond]
Mode=active-backup
MIIMonitorSec=1s
EOF_UNIT_1
		;;
	22-mgmt-bond.network) cat <<'EOF_UNIT_2'
# The management plane. This is the interface that carries the default route,
# and the only one in this unit set that gates network-online.target.
[Match]
Name=mgmt

# IPv6 router advertisements are accepted here and only here: mgmt is the plane
# that is supposed to hold a default route. Advertising as a router, and
# delegating prefixes, were inherited settings that were never a decision; both
# are gone.
[Network]
DHCP=yes
IPv6AcceptRA=true

[DHCPv4]
RouteMetric=500
UseDomains=true
UseDNS=true

# 1500 is written explicitly rather than inherited from the bond members, so an
# offline check can assert the shipped value. The segment is locked at 1500: a
# bond's own L3 interface participates as a host, not as transit.
[Link]
MTUBytes=1500
EOF_UNIT_2
		;;
	24-mgmt-bond.network) cat <<'EOF_UNIT_3'
# Enslaves the management NICs to the bond by an intrinsic property, so one
# generic image works on every model without per-host name lists.
#
# Caveat, noted and not pre-solved: this matches *any* e1000e NIC. On the
# measured hardware that is exactly the two management ports; a third e1000e NIC
# would be enslaved too. At that point switch to Path=.
[Match]
Driver=e1000e

[Network]
Bond=mgmt
EOF_UNIT_3
		;;
	30-data.netdev) cat <<'EOF_UNIT_4'
[NetDev]
Name=data
Kind=bridge

# The data bridge is a flat, non-VLAN-aware L2 domain. Stated explicitly because
# it is a decision, not a default. With filtering off the bridge keeps no VLAN
# table, so a default port VLAN has nothing to apply to; the out-of-range value
# that used to sit here was accepted by systemd but did nothing, and read as an
# active policy. If this bridge is ever meant to be VLAN-aware, turn filtering on
# and set a PVID in the documented 1-4094 range in the same change.
[Bridge]
VLANFiltering=false
EOF_UNIT_4
		;;
	32-data.network) cat <<'EOF_UNIT_5'
# The data bridge's own L3 interface. It takes an address and contributes no
# default route on either family.
[Match]
Name=data

# IPv4-only, deliberately. This bridge previously accepted router
# advertisements, which installed an IPv6 default route entirely outside the
# DHCP settings below; it also advertised itself as a router and offered prefix
# delegation onto a production segment. All of that is gone, so "data
# contributes no default route" now holds on both families trivially.
[Network]
DHCP=ipv4
LinkLocalAddressing=ipv4
IPv6AcceptRA=false

# Address, no gateway, no routes. This removes data's eligibility for a default
# route rather than ranking it behind mgmt; the metric-based workaround the
# fleet runs today is not carried into the image.
[DHCPv4]
UseRoutes=false
UseGateway=false

# 1500 is written explicitly and must not be "simplified" away: since Linux 4.17
# a bridge with no explicit MTU tracks the minimum MTU of its ports, so with the
# front-panel ports at 9000 an unset bridge MTU becomes 9000 -- the exact defect
# this removes. A bridge's own MTU constrains locally terminated traffic only,
# so 9000-byte transit between two front-panel ports still works.
#
# Not required for network-online.target: this interface carries no default
# route, and on a switch with every front-panel port dark it will never gain
# carrier. systemd skips a link with this setting rather than failing it.
[Link]
MTUBytes=1500
RequiredForOnline=no
EOF_UNIT_5
		;;
	34-data.network) cat <<'EOF_UNIT_6'
# The front-panel ports. Bound by driver, not by name, so enslavement does not
# depend on the udev rename having run. The glob keeps matching if a Spectrum-2
# or -3 driver is named differently.
[Match]
Driver=mlxsw_spectrum*

[Network]
Bridge=data

# 9000 is written here deliberately -- this file previously set no MTU at all,
# so the jumbo MTU seen on the fleet does not come from the image. Front-panel
# ports are transit, not hosts, so they are the one place jumbo belongs.
#
# Not required for network-online.target: on a 32- or 56-port switch most ports
# are dark, and a dark port would otherwise stall boot until wait-online times
# out and then fail. systemd skips a link with this setting rather than failing
# it, so nothing has to be muted downstream.
[Link]
MTUBytes=9000
RequiredForOnline=no
EOF_UNIT_6
		;;
	*) return 1 ;;
	esac
}

# 🔴 BYTE-IDENTICAL, and the first line is the point. It is a stray shell
# prompt left in the file when it was captured off mlnx-2410-cameo:
#
#     #root@deb12mlnx:~# cat /etc/udev/rules.d/10-local.rules
#
# It is a comment, it is inert, and it is PROVENANCE. Tidying it away breaks
# the only cheap check anyone has that the image's rule and the rule running on
# the live switch are the same bytes. Resist tidying it.
#
# 🔎 SEARCH TRAP. The rule builds the interface name as `sw` + the kernel's
# $attr{phys_port_name} (which is itself "p1", "p2", ...), so the literal
# string `swp` NEVER APPEARS in this file. Grepping for `swp` returns nothing
# and the rule looks absent. Search `mlxsw` or `phys_port_name`.
embedded_udev_rule() {
	cat <<'EOF_UDEV'
# Provenance: /etc/udev/rules.d/10-local.rules on mlnx-2410-cameo. Rule unchanged.
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlxsw_spectrum*", \
    NAME="sw$attr{phys_port_name}"

EOF_UDEV
}

# 🔴 INSTALLED, NEVER AUTHORED HERE. assets/etc.default.grub.d/20_switch-cmdline.cfg
# is owned by an already-merged member and is byte-frozen. This stage copies it
# verbatim; it does not decide what is in it. Read the file's own comments for
# why GRUB_CMDLINE_LINUX is appended rather than assigned.
embedded_grub_dropin() {
	cat <<'EOF_GRUB'
# Installed as /etc/default/grub.d/20_switch-cmdline.cfg.
#
# grub-mkconfig sources /etc/default/grub first, then every *.cfg in
# /etc/default/grub.d in glob order -- which is lexical, not numeric. The prefix
# is two digits and greater than 15 so this file wins over the base image's own
# 10_cloud.cfg and 15_timeout.cfg.
#
# This file owns exactly three variables: GRUB_CMDLINE_LINUX, GRUB_TERMINAL and
# GRUB_SERIAL_COMMAND. Boot-menu policy lives in 25_switch-boot-policy.cfg. The
# two variable sets are disjoint, so neither file can clobber the other in any
# source order.

# Append, never assign. These drop-ins are sourced shell, so a bare assignment
# would silently discard the base's console=tty0 console=ttyS0,115200
# earlyprintk=... consoleblank=0 and take serial recovery away from a headless
# switch.
#
# net.ifnames=0 gives operators eth0/eth1 and matches the fleet's convention.
# It is no longer load-bearing for port enumeration -- the networkd units bind
# on Driver=, so a fault here yields ugly names rather than an empty bridge.
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }net.ifnames=0"

# Serial INPUT, which is the whole point of this line and is easy to lose.
# grub-mkconfig expands GRUB_TERMINAL into both GRUB_TERMINAL_INPUT and
# GRUB_TERMINAL_OUTPUT, and it does so after the drop-in loop -- so this beats
# a GRUB_TERMINAL_OUTPUT set in any file at any prefix, including the base's.
#
# Stated as intent, not discovered as a side effect: this replaces the base's
# GRUB_TERMINAL_OUTPUT="gfxterm serial", trading the graphical terminal for
# serial input. On a headless switch that is the desired trade -- "console" is
# the native text console, so both output paths survive and only gfxterm is
# lost. Without this, a headless switch can see the GRUB menu but cannot steer
# it: no entry can be selected and no kernel parameter edited.
GRUB_TERMINAL="serial console"

# The line above is inert without this one, so the two must never be separated.
# /etc/grub.d/00_header:181-187 emits ${GRUB_SERIAL_COMMAND} whenever a serial
# terminal was requested, and when it is unset it warns and falls back to a bare
# "serial" -- GRUB's own defaults, which are unit 0 at 9600 baud:
#
#   if [ "x$serial" = x1 ]; then
#       if [ "x${GRUB_SERIAL_COMMAND}" = "x" ] ; then
#           grub_warn "Requested serial terminal but GRUB_SERIAL_COMMAND is
#                      unspecified. Default parameters will be used."
#           GRUB_SERIAL_COMMAND=serial
#       fi
#       echo "${GRUB_SERIAL_COMMAND}"
#   fi
#
# The kernel console runs at 115200 (console=ttyS0,115200), so a 9600-baud GRUB
# would put line noise on the wire for the entire bootloader stage. The menu
# would be unreadable at exactly the moment someone needs it -- picking the
# previous kernel, or editing a boot parameter on a switch whose only console is
# this serial line. That recovery path is the whole reason the serial console
# exists, so the speed is pinned here rather than left to a default.
#
# The retired grub.serial.patch was the only previous source of this setting.
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF_GRUB
}

# A PUBLIC key. Correct to ship, correct to commit, and the only credential
# this image will ever carry. looks_like_public_key() below refuses anything
# that smells like a private key, so a future edit that pastes the wrong half
# of the pair fails the selftest instead of shipping.
embedded_pubkey() {
	cat <<'EOF_PUBKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILkEeb/ItdBGrLJVoz/AYk/1sC4V9GwvqvzoA1Ch5hoC bd770i
EOF_PUBKEY
}

# ------------------------------------------------------------ asset resolution
# 🔴 THE REPO WINS WHENEVER IT IS VISIBLE. assets/ is byte-frozen and owned by
# another member; the embedded copies above are a fallback for a guest with no
# checkout. `run` ships assets/ into the guest precisely so that the GLOB path
# below -- not the embedded inventory -- is what production actually uses.
asset_net_dir() { [ -n "$REPO" ] && printf '%s/assets/etc.systemd.network' "$REPO"; }
asset_udev()    { [ -n "$REPO" ] && printf '%s/assets/etc.udev.rules.d.10-local.rules' "$REPO"; }
asset_grub()    { [ -n "$REPO" ] && printf '%s/assets/etc.default.grub.d/%s' "$REPO" "$GRUB_DROPIN_NAME"; }
asset_pubkey()  { [ -n "$REPO" ] && printf '%s/assets/id_ed25519.pub' "$REPO"; }
asset_deb()     { [ -n "$REPO" ] && printf '%s/%s' "$REPO" "$DKMS_DEB_REL"; }

have_asset_net_dir() { local d; d="$(asset_net_dir)"; [ -n "$d" ] && [ -d "$d" ]; }

# 🔴 THE UNIT SET IS DISCOVERED BY GLOB, NEVER BY A HARDCODED LIST. An earlier
# member split one .network file into two; a hardcoded list would have dropped
# the new file with nothing anywhere reporting it. install_units() counts what
# the glob found and counts what landed, and refuses to agree that 6 == 5.
unit_names() {
	local d
	if have_asset_net_dir; then
		d="$(asset_net_dir)"
		# `ls -1` on the directory, not a glob expansion into $(), so an empty
		# directory yields empty output rather than a literal '*' path.
		( cd "$d" && ls -1 ) 2>/dev/null
	else
		embedded_unit_names
	fi
}

unit_bytes() { # $1 = basename
	local d
	if have_asset_net_dir; then
		d="$(asset_net_dir)"
		[ -r "$d/$1" ] || return 1
		cat "$d/$1"
	else
		embedded_unit "$1"
	fi
}

udev_bytes()  { local f; f="$(asset_udev)";   if [ -n "$f" ] && [ -r "$f" ]; then cat "$f"; else embedded_udev_rule; fi; }
grub_bytes()  { local f; f="$(asset_grub)";   if [ -n "$f" ] && [ -r "$f" ]; then cat "$f"; else embedded_grub_dropin; fi; }
pubkey_bytes(){ local f; f="$(asset_pubkey)"; if [ -n "$f" ] && [ -r "$f" ]; then cat "$f"; else embedded_pubkey; fi; }

# Drift between the embedded copies and assets/. Reported, never fatal during
# an install -- the repo copy is what gets written, so drift cannot corrupt a
# repo-visible run. It IS fatal in `selftest`, which is the whole point: a
# stale embedded copy must be caught in CI, not on a switch.
check_asset_drift() {
	local d n_repo n_emb x rc=0
	d="$(asset_net_dir)"
	if [ -z "$d" ] || [ ! -d "$d" ]; then
		inf "no repo copy of assets/ visible; the embedded copies are in use"
		return 0
	fi

	# SET comparison, not a count comparison: an added file and a removed file
	# in the same change would keep the count identical.
	n_repo="$( ( cd "$d" && ls -1 ) | sort )"
	n_emb="$(embedded_unit_names | sort)"
	if [ "$n_repo" = "$n_emb" ]; then
		ok "embedded unit inventory matches assets/etc.systemd.network/ ($(printf '%s\n' "$n_repo" | grep -c .) files)"
	else
		bad "embedded unit inventory has DRIFTED from assets/etc.systemd.network/"
		diff <(printf '%s\n' "$n_emb") <(printf '%s\n' "$n_repo") | sed 's/^/       /' || true
		rc=1
	fi

	for x in $(printf '%s\n' "$n_repo"); do
		if embedded_unit "$x" 2>/dev/null | diff -q - "$d/$x" >/dev/null 2>&1; then :
		else bad "embedded copy of $x differs from assets/etc.systemd.network/$x"; rc=1; fi
	done
	[ "$rc" = 0 ] && ok "every embedded unit is byte-identical to its asset"

	if embedded_udev_rule | diff -q - "$(asset_udev)" >/dev/null 2>&1; then
		ok "embedded udev rule is byte-identical to assets/etc.udev.rules.d.10-local.rules"
	else bad "embedded udev rule has DRIFTED"; rc=1; fi

	if embedded_grub_dropin | diff -q - "$(asset_grub)" >/dev/null 2>&1; then
		ok "embedded GRUB drop-in is byte-identical to assets/etc.default.grub.d/$GRUB_DROPIN_NAME"
	else bad "embedded GRUB drop-in has DRIFTED"; rc=1; fi

	if embedded_pubkey | diff -q - "$(asset_pubkey)" >/dev/null 2>&1; then
		ok "embedded public key is byte-identical to assets/id_ed25519.pub"
	else bad "embedded public key has DRIFTED"; rc=1; fi

	return "$rc"
}

# ------------------------------------------------------------ generated content
# A4. 🔴 OPERATOR RULING 2026-08-03: a WHOLE FILE, written here, not a patch.
#
# assets/sensor.modules.patch is NOT used and must not be. It is a
# bookworm-vintage unified diff whose context lines were taken from bookworm's
# /etc/modules, so on trixie it would fuzz or reject.
#
# ⚠ CORRECTED IN PHASE 2. This comment used to add "...needs patch(1), a program
# this manifest deliberately EXCLUDES". That was FALSE: patch is a hard
# transitive dependency of build-essential (via dpkg-dev) and of dkms, and it
# was measured installed on the guest. See the EXCLUDED block. The reason above
# stands on its own and never depended on patch being absent.
emit_modload() {
	cat <<'EOF_MODLOAD'
# /etc/modules-load.d/mlxsw-sensors.conf
# Installed by scripts/stage-runtime-contract.sh. Do not hand-edit.
#
# MONITORING ONLY. These two modules expose temperatures; they do not control
# anything. Fan control on this hardware is IN-KERNEL -- MLXSW_CORE_THERMAL
# registers the switch's thermal zones and cooling devices with the kernel
# thermal core -- which is why userspace `fancontrol` is on this image's
# EXCLUDED list. Two authorities for one fan is how a switch cooks itself.
#
# 🔴 WHOLE FILE, never appended to. A re-run of the stage rewrites these exact
# bytes, so the stage converges instead of stacking duplicate module names the
# way an append would.
#
# 🔴 THIS PATH, NOT /etc/modules. Debian ships
# /etc/modules-load.d/modules.conf as a symlink to ../modules, so BOTH files
# feed the same systemd-modules-load.service: writing both would be two
# authorities for one outcome, disagreeing silently the first time someone
# edits one of them. This path is also the portable one -- /etc/modules does
# not exist on Arch, and scripts/vm.sh keeps a live Arch seam.
#
# Provenance: sensors-detect on mlnx-2410-cameo, 2024-03-30. coretemp is the
# CPU package sensor; jc42 is the JEDEC JC-42.4 sensor on the DIMMs.
coretemp
jc42
EOF_MODLOAD
}

# A7. 🔴 NOPASSWD IS FORCED, NOT PREFERRED, AND THIS IS THE ARGUMENT.
#
# The account is key-only and its password is LOCKED (`!` in shadow). A locked
# password cannot authenticate, so a sudoers rule that PROMPTS for one can
# never be satisfied: the operator would hold a working SSH login and no route
# to root at all, on a headless switch, with the only console a serial line.
# The alternatives were considered and rejected:
#
#   * bake a password  -- forbidden outright, no exceptions.
#   * NOPASSWD         -- what this does. Privilege escalation is gated by
#                         possession of the SSH private key, which is the same
#                         gate that got the operator onto the box at all. It
#                         adds no new authority.
#   * pam_ssh_agent_auth -- a real answer, and a new dependency plus a new
#                         failure mode on an image whose recovery story is a
#                         serial console. Not taken here; noted so the choice
#                         is visible rather than defaulted into.
#
# ⚠ THE FILENAME MATTERS AS MUCH AS THE CONTENT. sudo's #includedir skips any
# file whose name contains a '.' or ends in '~', silently. See SUDOERS_DROPIN.
emit_sudoers() {
	cat <<EOF_SUDOERS
# $SUDOERS_DROPIN -- installed by scripts/stage-runtime-contract.sh.
#
# NOPASSWD is load-bearing: $ADMIN_USER has a LOCKED password (key-only auth),
# so a password prompt here would make privilege escalation impossible rather
# than merely inconvenient. See emit_sudoers() in the stage for the full
# argument. Validated with \`visudo -c -f\` before it was installed.
$ADMIN_USER ALL=(ALL:ALL) NOPASSWD:ALL
EOF_SUDOERS
}

# ------------------------------------------------------------ A6: the manifest
# 🔴 FOUR LISTS, AND OPERATOR PREFERENCE MUST NEVER HIDE INSIDE REQUIRED.
# Anything in REQUIRED_* is something the image does not FUNCTION without.
# Anything in PREFERRED is something a human likes having; it can be dropped
# without breaking a switch, and a reader must be able to see which is which.

# Required, to build kernel modules at all.
# 🔴 linux-headers-amd64 is the METAPACKAGE and must stay that way. A versioned
# `linux-headers-$(uname -r)` pins the headers to today's kernel: after the
# next `apt upgrade` DKMS has no headers for the new kernel, builds zero
# modules, exits 0, and the switch comes up with no data plane. That is R4, and
# the metapackage is the whole defence.
REQUIRED_BUILD=(build-essential dkms linux-headers-amd64 kmod)

# Required, for the image to function as a switch.
# ⚠ systemd-repart is a SEPARATE binary package on Debian -- it is not in the
# base image and it is not pulled in by systemd. This stage owns naming it;
# ANOTHER member owns its .conf. If this name ever fails to resolve, that is a
# fact about the archive and check_package_names() reports it by name.
REQUIRED_IMAGE=(
	systemd-repart
	gdisk parted
	sudo polkitd pkexec
	ethtool smartmontools
	systemd-resolved systemd-timesyncd
)

# Operator preference. Nothing here is load-bearing.
#
# 🔴 `ipmiutil` WAS HERE AND WAS DROPPED, operator ruling 2026-08-03, after the
# first run of this stage against a real guest. It installs
# `ipmiutil_wdt.service`, ENABLED BY THE PACKAGE'S OWN PRESET, which starts an
# IPMI watchdog timer and keeps it fed from cron. On a machine with no BMC it
# exits 240 immediately:
#
#     × ipmiutil_wdt.service - ipmiutil Watchdog Timer Service using cron
#          Active: failed (Result: exit-code)
#         Main PID: 2421 (code=exited, status=240/LOGS_DIRECTORY)
#     $ ls /dev/ipmi*  ->  No such file or directory
#
# That is a PERMANENTLY failed unit in the shipped artifact, on any machine
# without a BMC -- not a QEMU artefact -- and ruling 6 says `systemctl --failed`
# is empty unconditionally, no allowlist ever.
#
# Conditioning the unit was the other option and was NOT taken. It would have
# left the watchdog LIVE on hardware that does have a BMC, and an IPMI watchdog
# that stops being fed reboots the box -- a behaviour nobody asked for on a
# production switch, arriving as a side effect of wanting the CLI tools.
#
# ⚠ For the record, since the original pick rested on a false premise: the two
# singular names are DIFFERENT PROJECTS and BOTH exist in trixie --
# `ipmitool 1.8.19-9` and `ipmiutil 3.2.1-1`. The original request was
# "ipmiutils", which is neither. If out-of-band management is wanted later, that
# is a fresh decision with this evidence in hand, not a restoration of this line.
PREFERRED=(vim rsync wget tmux kitty-terminfo lm-sensors dmidecode)

# Filled in by check_package_names(): the preference names this archive actually
# has. Declared here so `set -u` cannot trip over it on any path.
PREFERRED_OK=()

# 🔴 EXCLUDED. This stage never installs these AND asserts they are absent.
# Every name here must be a package that NOTHING ELSE on the image drags in --
# otherwise the assertion is unsatisfiable and the stage is permanently red.
#
#   fancontrol         in-kernel MLXSW_CORE_THERMAL owns thermal and fan
#                      control. A second authority is how a switch cooks itself.
#   policykit-1        DOES NOT EXIST ON TRIXIE. It was the bookworm-era
#                      transitional package; polkitd and pkexec replaced it.
#   ntp ntpdate        time is systemd-timesyncd's job, and two time daemons
#   ntp-doc ntpsec     fight. timesyncd is the choice, so these are excluded
#                      rather than merely not-installed.
#   isc-dhcp-client    networkd is the DHCP client. Same argument.
#   smbios-utils       inherited from a Dell-era manifest; nothing uses it.
#
# ❌ `patch` WAS HERE AND IS GONE. Phase 2, measured in a real trixie guest:
#
#     build-essential  Depends: ..., dpkg-dev (>= 1.22.11)
#     dpkg-dev         Depends: ..., patch (>= 2.7), ...
#     apt-cache rdepends --installed patch -> dpkg-dev, libdpkg-perl, dkms
#
# build-essential AND dkms are both in REQUIRED_BUILD, so `patch` is a HARD
# transitive dependency of this stage's own required set. patch 2.8-2 was
# installed on the guest before this stage ran a single command. Asserting its
# absence could never pass, in any ordering, on any image that can build a
# kernel module. The claim was wrong, not the archive.
#
# The contract that actually matters -- THIS STAGE NEVER INVOKES patch(1) -- is
# unaffected and is enforced by the forbid() source grep in S2, which S2b now
# watches fail. A4 writes a whole file for its own stated reason: the shipped
# assets/sensor.modules.patch is a bookworm-vintage diff whose context lines
# come from bookworm's /etc/modules and would fuzz or reject on trixie.
#
# ✅ `ipmiutil` WAS ADDED HERE 2026-08-03, moving OUT of PREFERRED by operator
# ruling. It satisfies the rule above -- nothing else on the image drags it in,
# so the absence assertion is satisfiable -- and it earns its place rather than
# merely being deleted from PREFERRED: dropping a name from a preference list
# is silent, and a later manifest edit could re-add it without anyone noticing
# the failed watchdog unit come back. Here, `verify` says so on every run.
# Full reasoning at the PREFERRED array.
EXCLUDED=(
	fancontrol
	policykit-1
	ntp ntpdate ntp-doc ntpsec
	isc-dhcp-client
	smbios-utils
	ipmiutil
)

# 🔴 A DIFFERENT CLAIM WITH A DIFFERENT OWNER, and it must not be smuggled into
# EXCLUDED. These ship IN THE BASE IMAGE. This stage must never install them and
# never removes them -- so "absent" is not a statement this stage is in a
# position to make, and asserting it here only reports on another stage's work.
#
# Phase 2 measurement, pristine debian-13-generic trixie guest:
#
#     cloud-guest-utils 0.33-1 installed   (rdepends: cloud-init, cloud-utils)
#
# docs/architecture.md places the `generalize` stage AFTER this one in the
# pipeline, and records that `cloud-guest-utils` is MANUALLY marked -- so
# purging cloud-init does NOT autoremove it. Nothing in the repo purges it by
# name today. That gap is real and is reported by name below rather than
# silently passing or permanently failing this stage.
#
#   cloud-guest-utils  dropped 2026-08-03. It existed only for growpart, and
#                      filesystem growth is now systemd-repart.
EXCLUDED_BASE_IMAGE=(cloud-guest-utils)
EXCLUDED_BASE_IMAGE_OWNER="the generalize stage (purges cloud-init/netplan/growroot)"

# 🔴 ASSERT, NEVER INSTALL. The base image already carries a bootloader via
# grub-cloud-amd64. Installing a grub package from here could swap the flavour
# out from under a system that is currently booting fine.
BOOTLOADER_EXPECTED=(grub-cloud-amd64 grub-pc grub-efi-amd64 grub-efi-amd64-signed)

# The names this stage will actually hand to apt, one per line.
install_list() {
	printf '%s\n' "${REQUIRED_BUILD[@]}" "${REQUIRED_IMAGE[@]}" "${PREFERRED[@]}"
}

# ------------------------------------------------------- pure list predicates
# 🔴 EVERY PREDICATE BELOW TAKES ITS INPUT AS DATA AND TOUCHES NO COUNTER, so
# `selftest` can run each one against input that must PASS and input that must
# FAIL. A guard nobody has watched fail is not a guard -- this project has
# shipped four of those.

list_is_unique() { # stdin = list
	local l
	l="$(cat)"
	[ "$(printf '%s\n' "$l" | grep -c .)" = "$(printf '%s\n' "$l" | sort -u | grep -c .)" ]
}

list_has_none_of() { # stdin = list, $@ = forbidden names.  0 = clean
	local l x
	l="$(cat)"
	for x in "$@"; do
		if printf '%s\n' "$l" | grep -qxF -- "$x"; then return 1; fi
	done
	return 0
}

list_has_no_bootloader() { ! grep -qE '^grub'; }         # stdin = list

# 🔴 A versioned header package is the R4 factory. Refuse the shape, not just
# today's literal: `linux-headers-6.12.100+deb13-amd64` and any attempt to
# splice `uname -r` into a package name both fail here.
list_has_no_versioned_headers() { ! grep -qE '^linux-headers-[0-9]|uname'; }

list_has() { grep -qxF -- "$1"; }                        # stdin = list

# ------------------------------------------------------- pure text predicates

# `systemctl --failed --no-legend --plain` on stdin. 🔴 OUTCOME, NOT EXIT
# STATUS: systemctl --failed exits 0 whether or not anything failed, so testing
# its status proves nothing at all. The only signal is whether it listed a unit.
systemd_failed_clean() {
	local n
	n="$(grep -cE '[^[:space:]]' || true)"
	[ "${n:-0}" -eq 0 ]
}

# `journalctl -u systemd-networkd` on stdin.
#
# ❌ REPLACED CRITERION. `systemd-analyze verify` CANNOT parse .network or
# .netdev files -- it reports "Invalid argument" on a perfectly good unit, and
# that was confirmed twice. So the units are proven by what networkd ITSELF
# said when it read them at boot. We read the journal of the boot that ALREADY
# HAPPENED; we never provoke a re-parse, because the only way to provoke one is
# to reload networkd and that severs the control channel.
networkd_journal_clean() {
	! grep -qE 'Unknown key name|Invalid|Failed to parse'
}

# `dkms status` on stdin, $1 = kernel version.
# Modern dkms prints one state word; `installed` implies `built`, and a module
# that is merely `added` has been built for nothing.
dkms_reports_installed() {
	awk -v k="$1" '
		index($0, "mlxsw") == 0 { next }
		index($0, k) == 0 { next }
		index($0, "installed") > 0 { found = 1 }
		END { exit found ? 0 : 1 }
	'
}

# scripts/mlxsw-premise-audit.sh output on stdin -> prints its failed count.
#
# ❌ REPLACED CRITERION. The audit's TOTAL is data-dependent -- a correct run
# can legitimately move it -- so "26/26" is not a contract and asserting it
# turns a healthy change into a red build. The contract is the audit's own:
# fail == 0, and exit 0.
audit_failed_count() {
	grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1 | awk '{print $3}'
}

# ------------------------------------------------------- pure file predicates

# 🔴 ASSERT THE GENERATED grub.cfg, NEVER THE DROP-IN. The drop-in is the
# INPUT; asserting it cannot catch a clobber, and catching a clobber is the
# entire reason this check exists. 20_switch-cmdline.cfg appends to
# GRUB_CMDLINE_LINUX so the base's console tokens survive -- but only the
# generated file can show whether they actually did.
#
# Recovery entries are excluded on purpose: 10_linux emits ${GRUB_CMDLINE_LINUX}
# alone for them (no ${GRUB_CMDLINE_LINUX_DEFAULT}), so what they carry depends
# entirely on which of the two variables the base image used.
#
# ⚠ CORRECTED IN PHASE 2. This comment used to assert that recovery entries
# "legitimately do NOT carry the base's console tokens". On debian-13-generic
# that is FALSE, and it was never measured. Measured 2026-08-02:
#
#     GRUB_CMDLINE_LINUX_DEFAULT=""
#     GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200 earlyprintk=... consoleblank=0"
#
# The base puts its console tokens in GRUB_CMDLINE_LINUX, so the generated
# recovery lines carry them AND net.ifnames=0, exactly like the normal entries.
# The exclusion is kept anyway: it must not depend on which variable a base
# image happens to choose, and a recovery entry that legitimately dropped the
# tokens must not turn this assertion red. Excluding them is the conservative
# direction -- it can only ever make the check assert less, never assert wrong.
# The real fixture is S6b, which is the byte-exact generated file.
grubcfg_boot_lines() { # $1 = grub.cfg
	awk '
		/^[[:space:]]*(menuentry|submenu)[[:space:]]/ { rec = (index($0, "recovery") > 0) }
		/^[[:space:]]*linux(16|efi)?[[:space:]]/      { if (!rec) print }
	' "$1"
}

# 0 = EVERY non-recovery kernel line carries BOTH the base's serial console and
# the drop-in's net.ifnames=0. Per line, not "somewhere in the file": a file
# where one entry kept the console and a different entry kept net.ifnames must
# fail, and a whole-file grep would pass it.
grubcfg_cmdline_intact() { # $1 = grub.cfg
	local f="$1" lines n a b
	[ -r "$f" ] || return 1
	lines="$(grubcfg_boot_lines "$f")"
	[ -n "$lines" ] || return 1
	n=$(printf '%s\n' "$lines" | grep -c .)
	a=$(printf '%s\n' "$lines" | grep -c 'console=ttyS0,115200' || true)
	b=$(printf '%s\n' "$lines" | grep -c 'net\.ifnames=0' || true)
	[ "$a" = "$n" ] && [ "$b" = "$n" ]
}

# 🔴 SERIAL *INPUT*, ASSERTED ON THE GENERATED FILE. Added in Phase 2, because
# nothing anywhere asserted it and it is half of what 20_switch-cmdline.cfg
# exists to deliver. GRUB_TERMINAL="serial console" is inert without
# GRUB_SERIAL_COMMAND, and a base image that sets only GRUB_TERMINAL_OUTPUT --
# which debian-13-generic does, `GRUB_TERMINAL_OUTPUT="gfxterm serial"` --
# yields a menu an operator can READ over the serial line and cannot STEER: no
# entry selectable, no kernel parameter editable, on a switch whose only other
# door is a screwdriver.
#
# Measured on the real generated /boot/grub/grub.cfg, 2026-08-02:
#
#   serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
#   terminal_input serial console
#   terminal_output serial console
#
# The speed is asserted, not just the presence of a `serial` line: GRUB's own
# fallback when GRUB_SERIAL_COMMAND is unset is 9600 baud against a 115200
# kernel console, which is line noise for the whole bootloader stage.
grubcfg_serial_intact() { # $1 = grub.cfg
	local f="$1"
	[ -r "$f" ] || return 1
	grep -qE '^serial[[:space:]].*--speed=115200' "$f" || return 1
	# `serial` must be one of terminal_input's WORDS. An unanchored substring
	# match would accept `terminal_input serialconsole`, and `.*[[:space:]]serial`
	# alone would MISS `terminal_input serial console` -- serial is the first
	# word there, with no space before it. Both halves of the alternation matter.
	grep -qE '^terminal_input[[:space:]]+(.*[[:space:]])?serial([[:space:]]|$)' "$f" || return 1
	return 0
}

# 🔴 A PUBLIC key, and nothing else, ever. assets/id_ed25519.pub is correct to
# ship and correct to commit; the matching private key must never exist in this
# repo or in any image. This predicate is what makes "no private key" an
# assertion rather than a hope.
looks_like_public_key() { # $1 = file
	local f="$1"
	[ -s "$f" ] || return 1
	if grep -qi 'PRIVATE KEY' "$f"; then return 1; fi
	grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/]{20,}=*([[:space:]]|$)' "$f"
}

# ⚠ sudo's #includedir SILENTLY skips any drop-in whose name contains a '.' or
# ends in '~'. Same class of trap as Debian's run-parts skipping dotted names:
# the file is present, readable, syntactically perfect, and never read.
is_valid_sudoers_name() { # $1 = basename
	case "$1" in
	''|*.*|*'~') return 1 ;;
	esac
	return 0
}

# 🔴 THE RULE LINES, NOT THE FILE. `grep -q NOPASSWD file` was the first
# version of this check and it PASSED on a drop-in whose only rule demanded a
# password -- because the file's own comment explains why NOPASSWD is required,
# and the comment matched. That is this project's recurring defect exactly: a
# guard that reports on its documentation instead of on its subject. Comments
# are stripped first, and EVERY remaining rule must grant NOPASSWD.
sudoers_is_nopasswd() { # $1 = file
	local rules n m
	[ -r "$1" ] || return 1
	rules="$(grep -vE '^[[:space:]]*(#|$)' "$1" || true)"
	[ -n "$rules" ] || return 1
	n=$(printf '%s\n' "$rules" | grep -c .)
	m=$(printf '%s\n' "$rules" | grep -c 'NOPASSWD:' || true)
	[ "$n" = "$m" ]
}

# 🔴 A malformed sudoers file locks out privilege escalation on a headless
# switch. Validate BEFORE it lands, never after.
sudoers_syntax_ok() { # $1 = file
	command -v visudo >/dev/null 2>&1 || return 2
	visudo -cqf "$1" >/dev/null 2>&1
}

# 🔴 THE GLOB IS '*.ko*', NEVER '*.ko'. Trixie compresses modules and installs
# mlxsw_spectrum.ko.xz; bookworm shipped plain .ko. A '*.ko' glob reports the
# modules missing while they are present and loaded.
mlxsw_modules_present() { # $1 = root prefix, $2 = kernel version
	local d="$1/lib/modules/$2/updates/dkms"
	[ -d "$d" ] || return 1
	find "$d" -maxdepth 1 -name 'mlxsw*.ko*' -print -quit 2>/dev/null | grep -q .
}

# ------------------------------------------------------- Depends predicates
# 🔴 A FLOOR, NEVER A CEILING -- standing project rule, and this is the one
# place it is mechanically checkable with no guest at all.
#
# `linux-headers-amd64 (>= 6.12)` says "I need at least this". A ceiling --
# `(<< 6.13)`, `(<= x)`, or an exact `(= x)` pin -- says "I stop working after
# this", and apt's answer to that at the next kernel series bump is to REMOVE
# mlxsw-dkms. The switch then boots a perfectly healthy kernel with no data
# plane and nothing warns. That is R4 delivered by the packaging.
dep_clause() { # $1 = Depends field, $2 = package name -> the comma-clause(s) naming it
	printf '%s\n' "$1" | tr ',' '\n' | grep -F -- "$2" || true
}

dep_names() { # $1 = Depends field, $2 = package name.  0 = named at all
	[ -n "$(dep_clause "$1" "$2")" ]
}

dep_has_floor() { # 0 = a >= or >> lower bound is present
	local c; c="$(dep_clause "$1" "$2")"
	[ -n "$c" ] || return 1
	printf '%s' "$c" | grep -qE '\([[:space:]]*(>=|>>)[[:space:]]*[0-9]'
}

# `=` counts as a ceiling: an exact pin is a ceiling with the floor welded to it.
dep_has_ceiling() { # 0 = a ceiling IS present (which is the failure condition)
	local c; c="$(dep_clause "$1" "$2")"
	[ -n "$c" ] || return 1
	printf '%s' "$c" | grep -qE '\([[:space:]]*(<<|<=|=)[[:space:]]*[0-9]'
}

# ------------------------------------------------------- apt, and its one trap
# 🔴 HARD CAVEAT, LEARNED THE EXPENSIVE WAY. On a freshly booted base image the
# apt index is EMPTY, and every valid package name reports as non-existent --
# smartmontools, lm-sensors and pkexec all did. A validation run before
# `apt-get update` therefore produces a confident, wrong list of "missing"
# packages and would delete real packages from the manifest.
#
# So existence is not answerable until the index is fresh, and pkg_candidate()
# REFUSES TO GUESS rather than returning "absent". Exit 2 means "cannot
# answer"; exit 1 means "the archive says no". They are different facts and the
# callers treat them differently.
APT_INDEX_FRESH=0

apt_update() {
	command -v apt-get >/dev/null 2>&1 || return 1
	DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
	APT_INDEX_FRESH=1
	return 0
}

pkg_candidate() { # $1 = name -> prints the candidate version
	[ "$APT_INDEX_FRESH" = 1 ] || {
		printf 'pkg_candidate: cannot answer for %s -- apt-get update has not run in this stage, and an empty index makes every valid name look missing\n' "$1" >&2
		return 2
	}
	local v
	v="$(apt-cache policy -- "$1" 2>/dev/null | awk '/^ *Candidate:/ {print $2; exit}')"
	[ -n "$v" ] && [ "$v" != "(none)" ] || return 1
	printf '%s' "$v"
}

pkg_installed() { # $1 = name
	dpkg-query -W -f='${db:Status-Status}' -- "$1" 2>/dev/null | grep -qx 'installed'
}

# ------------------------------------------------------------ install helpers
# ⚠ CREATE-IF-ABSENT, never `install -d -m MODE` on a path that already exists.
# `install -d` CHMODs an existing directory, so a stage that "just makes sure the
# directory is there" quietly widens /etc/sudoers.d from 0750 to 0755 and nothing
# anywhere reports it. The one directory this stage genuinely owns -- ~/.ssh --
# is still set unconditionally, because 0700 there is a requirement rather than
# a convention.
ensure_dir() { # $1 = path (already root-prefixed), $2 = mode, applied only on creation
	[ -d "$1" ] && return 0
	install -d -m "$2" "$1"
}

# Ownership is only meaningful on a running system. Under --root the staged
# tree is owned by whoever ran the build; that is stated, not silently ignored.
own_root() { # $1 = path
	[ -n "$ROOT" ] && return 0
	chown root:root "$1"
}

# ------------------------------------------------------------ A1: networkd
# 🔴 NEVER RESTART OR RELOAD NETWORKD HERE. This stage runs over the network.
# The units are written and left alone; first boot applies them, which is also
# what happens on the real switch. `networkctl reload` is the same forbidden
# action wearing a different name.
install_units() {
	local names n_in n_out base
	names="$(unit_names)"
	n_in=$(printf '%s\n' "$names" | grep -c . || true)
	if [ "${n_in:-0}" -eq 0 ]; then
		bad "no networkd units found to install -- assets/etc.systemd.network/ is empty or unreadable"
		return 1
	fi

	ensure_dir "$(rp "$NET_DIR")" 0755
	# `while IFS= read -r`, not `for base in $names`: word splitting would turn
	# one unit file whose name contains a space into two garbage writes.
	while IFS= read -r base; do
		[ -n "$base" ] || continue
		unit_bytes "$base" > "$(rp "$NET_DIR/$base")" || { bad "could not write $NET_DIR/$base"; return 1; }
		chmod 0644 "$(rp "$NET_DIR/$base")"
		own_root  "$(rp "$NET_DIR/$base")"
	done <<-UNITS
	$names
	UNITS

	# 🔴 COUNT IN == COUNT OUT. This is the assertion that a hardcoded list
	# cannot make: it is what catches a seventh unit file appearing in assets/
	# and going nowhere.
	n_out=0
	while IFS= read -r base; do
		[ -n "$base" ] || continue
		[ -f "$(rp "$NET_DIR/$base")" ] && n_out=$((n_out + 1))
	done <<-UNITS
	$names
	UNITS
	if [ "$n_in" = "$n_out" ]; then
		ok "installed $n_out/$n_in networkd units into $NET_DIR (0644, by glob)"
	else
		bad "networkd unit count mismatch: $n_in found in assets, $n_out landed in $NET_DIR"
		return 1
	fi

	# Strays are reported, never deleted: another member may legitimately own a
	# file in this directory, and a stage that silently deletes what it did not
	# write is a stage that eats someone else's work.
	local stray
	stray="$( ( cd "$(rp "$NET_DIR")" && ls -1 ) 2>/dev/null | grep -vxF "$names" || true)"
	[ -n "$stray" ] && inf "other files present in $NET_DIR (left alone): $(printf '%s' "$stray" | tr '\n' ' ')"
	inf "networkd is NOT reloaded or restarted -- doing so from inside the"
	inf "network being reconfigured severs the control channel. First boot applies these."
	return 0
}

# ------------------------------------------------------------ A2: udev naming
install_udev_rule() {
	ensure_dir "$(rp "$(dirname "$UDEV_RULE")")" 0755
	udev_bytes > "$(rp "$UDEV_RULE")"
	chmod 0644 "$(rp "$UDEV_RULE")"
	own_root  "$(rp "$UDEV_RULE")"

	# 🔴 BYTE-IDENTICAL, asserted rather than assumed. The first line is a stray
	# shell prompt from the capture off the live switch; it is provenance and it
	# stays.
	local src; src="$(asset_udev)"
	if [ -n "$src" ] && [ -r "$src" ]; then
		if cmp -s "$src" "$(rp "$UDEV_RULE")"; then
			ok "installed $UDEV_RULE byte-identical to the asset ($(stat -c%s "$src") bytes)"
		else
			bad "$UDEV_RULE is NOT byte-identical to $src"
			return 1
		fi
	else
		ok "installed $UDEV_RULE from the embedded copy (no repo visible)"
	fi
	inf "the rule names ports as sw + \$attr{phys_port_name}, so the literal"
	inf "string 'swp' never appears in it -- search mlxsw or phys_port_name"
	return 0
}

# ------------------------------------------------------------ A3: GRUB cmdline
GRUB_REGENERATED=0

install_grub_dropin() {
	ensure_dir "$(rp "$GRUB_DROPIN_DIR")" 0755
	# 🔴 TRUNCATE. Appending here would duplicate the whole file on every
	# re-run, and a duplicated `GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+...}
	# net.ifnames=0"` appends net.ifnames=0 twice to the kernel command line.
	grub_bytes > "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")"
	chmod 0644 "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")"
	own_root  "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")"

	local src; src="$(asset_grub)"
	if [ -n "$src" ] && [ -r "$src" ] && ! cmp -s "$src" "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")"; then
		bad "$GRUB_DROPIN_NAME is not byte-identical to the asset -- it is INSTALLED here, never authored here"
		return 1
	fi
	ok "installed $GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME (truncating write, verbatim from assets/)"

	# The two drop-ins own DISJOINT variable sets, so source order does not
	# matter. That was investigated and the "ordering dependency" is a phantom;
	# do not re-introduce one. Assert the disjointness instead.
	local sib; sib="$(rp "$GRUB_DROPIN_DIR/25_switch-boot-policy.cfg")"
	if [ -r "$sib" ]; then
		if grep -qE '^[[:space:]]*(export[[:space:]]+)?(GRUB_CMDLINE_LINUX|GRUB_TERMINAL|GRUB_SERIAL_COMMAND)=' "$sib"; then
			bad "25_switch-boot-policy.cfg assigns a variable owned by $GRUB_DROPIN_NAME -- the sets must stay disjoint"
		else
			ok "25_switch-boot-policy.cfg assigns none of this file's three variables (sets stay disjoint)"
		fi
	fi

	# 🔴 NOT TOUCHED: 15_timeout.cfg and 10_cloud.cfg belong to other members.
	local other
	for other in 15_timeout.cfg 10_cloud.cfg; do
		[ -e "$(rp "$GRUB_DROPIN_DIR/$other")" ] && inf "$GRUB_DROPIN_DIR/$other left alone (another member owns it)"
	done
	return 0
}

regenerate_grub() {
	[ -n "$ROOT" ] && return 0
	# Idempotent by construction AND by guard: a sibling stage also regenerates,
	# and grub-mkconfig is a pure regeneration, so a double call is harmless --
	# but there is no reason to pay for it twice in one run either.
	[ "$GRUB_REGENERATED" = 1 ] && { inf "grub.cfg already regenerated in this run"; return 0; }
	if command -v update-grub >/dev/null 2>&1; then
		update-grub >/dev/null 2>&1 && { GRUB_REGENERATED=1; ok "update-grub regenerated $GRUBCFG"; return 0; }
		bad "update-grub failed"; return 1
	elif command -v grub-mkconfig >/dev/null 2>&1; then
		grub-mkconfig -o "$GRUBCFG" >/dev/null 2>&1 && { GRUB_REGENERATED=1; ok "grub-mkconfig regenerated $GRUBCFG"; return 0; }
		bad "grub-mkconfig failed"; return 1
	fi
	bad "neither update-grub nor grub-mkconfig is installed"
	return 1
}

assert_grubcfg() {
	local f; f="$(rp "$GRUBCFG")"
	if [ ! -r "$f" ]; then
		if [ -n "$ROOT" ]; then inf "no $GRUBCFG in the staged tree -- the generated-file assertion needs a real system (selftest covers the predicate itself)"
		else bad "no $GRUBCFG to assert against"; fi
		return 0
	fi
	local n; n=$(grubcfg_boot_lines "$f" | grep -c . || true)
	if grubcfg_cmdline_intact "$f"; then
		ok "generated grub.cfg: all $n non-recovery kernel lines carry BOTH console=ttyS0,115200 and net.ifnames=0"
	else
		bad "generated grub.cfg: the base's serial console and net.ifnames=0 do NOT both survive on every kernel line"
		grubcfg_boot_lines "$f" | sed 's/^/       /'
		return 1
	fi
	if grubcfg_serial_intact "$f"; then
		ok "generated grub.cfg: serial --speed=115200 AND terminal_input serial are both present (the GRUB menu can be STEERED, not just read)"
	else
		bad "generated grub.cfg: GRUB has no steerable serial console -- serial and/or terminal_input is missing or the wrong speed"
		grep -nE '^(serial|terminal_input|terminal_output)' "$f" | sed 's/^/       /' || true
		return 1
	fi
	return 0
}

# ------------------------------------------------------------ A4: sensors
install_modload() {
	ensure_dir "$(rp "$(dirname "$MODLOAD_CONF")")" 0755
	emit_modload > "$(rp "$MODLOAD_CONF")"
	chmod 0644 "$(rp "$MODLOAD_CONF")"
	own_root  "$(rp "$MODLOAD_CONF")"
	ok "installed $MODLOAD_CONF (whole file: coretemp, jc42)"

	# ⚠ /etc/modules IS NOT WRITTEN, and this is deliberate. Debian symlinks
	# /etc/modules-load.d/modules.conf to ../modules, so both files feed the
	# same systemd-modules-load.service. Writing both is two authorities for one
	# outcome. This stage does not create it and does not modify it.
	if [ -e "$(rp "$ETC_MODULES")" ]; then
		inf "$ETC_MODULES exists and is left untouched (it feeds the same service via modules-load.d/modules.conf)"
	else
		inf "$ETC_MODULES not created (this stage owns modules-load.d only)"
	fi
	return 0
}

# ------------------------------------------------------------ A5: the .deb
install_dkms_deb() {
	local deb; deb="$(asset_deb)"
	if [ -n "$ROOT" ]; then
		inf "ROOT is set: skipping the mlxsw-dkms install (apt and dkms describe a running system)"
		return 0
	fi
	if [ -z "$deb" ] || [ ! -r "$deb" ]; then
		bad "cannot find $DKMS_DEB_REL -- pass --repo DIR (run mode ships it to $GUEST_PAYLOAD)"
		return 1
	fi

	# 🔴 apt-get, NOT the low-level dpkg install flag. dpkg's own installer does
	# not resolve dependencies: it would unpack mlxsw-dkms into a half-configured
	# state if dkms or the headers were absent, and dpkg exits non-zero in a way
	# that a tolerant caller reads as "already there".
	#
	# 🔴 NO --no-install-recommends. dkms carries `Recommends: gcc | c-compiler`,
	# and stranding the toolchain is the R4 factory: DKMS present, compiler
	# absent, zero modules built, apt exits 0.
	local before after
	before="$(dpkg-query -W -f='${Version}' mlxsw-dkms 2>/dev/null || echo '-')"
	if DEBIAN_FRONTEND=noninteractive apt-get install -y -- "$deb" >/dev/null 2>&1; then
		after="$(dpkg-query -W -f='${Version}' mlxsw-dkms 2>/dev/null || echo '-')"
		ok "installed $(basename "$deb") with apt-get (dependency-resolving): $before -> $after"
	else
		bad "apt-get install of $(basename "$deb") failed"
		return 1
	fi

	# NOT asserted here: "the install pulled in dkms/build-essential/
	# linux-headers-amd64". scripts/vm.sh:277 already installs all three before
	# this stage ever runs, so that assertion cannot fail in the build VM and
	# proves nothing. The claim that CAN fail is the .deb's own metadata, and
	# that is asserted offline in selftest -- floor, no ceiling.
	return 0
}

# ------------------------------------------------------------ A6: packages
check_package_names() {
	local p v rc=0 missing=""
	# 🔴 Never before apt_update(). pkg_candidate() enforces it.
	for p in "${REQUIRED_BUILD[@]}" "${REQUIRED_IMAGE[@]}"; do
		if v="$(pkg_candidate "$p")"; then :
		else
			case "$?" in
			2) bad "cannot validate '$p': the apt index is not fresh"; rc=1 ;;
			*) bad "REQUIRED package does not resolve in this archive: $p"; rc=1 ;;
			esac
			missing="$missing $p"
		fi
	done
	[ -z "$missing" ] && ok "every REQUIRED package name resolves ($(( ${#REQUIRED_BUILD[@]} + ${#REQUIRED_IMAGE[@]} )) names)"

	# 🔴 One bad preference name must NEVER take the whole apt transaction down.
	# Each is validated on its own and named individually when it fails.
	PREFERRED_OK=()
	for p in "${PREFERRED[@]}"; do
		if v="$(pkg_candidate "$p")"; then PREFERRED_OK+=("$p")
		else bad "OPERATOR-PREFERENCE package does not resolve: $p (dropped from this transaction; the rest still install)"; rc=1; fi
	done
	[ "${#PREFERRED_OK[@]}" = "${#PREFERRED[@]}" ] && ok "every OPERATOR-PREFERENCE package name resolves (${#PREFERRED[@]} names)"

	return "$rc"
}

install_packages() {
	if [ -n "$ROOT" ]; then
		inf "ROOT is set: skipping apt entirely (the manifest is still asserted offline by selftest)"
		return 0
	fi
	command -v apt-get >/dev/null 2>&1 || { bad "apt-get is not installed"; return 1; }

	if apt_update; then ok "apt-get update: the package index is fresh"
	else bad "apt-get update failed -- refusing to validate names against a stale index"; return 1; fi

	check_package_names || true     # reported per-name; never aborts the stage

	local -a want=("${REQUIRED_BUILD[@]}" "${REQUIRED_IMAGE[@]}" "${PREFERRED_OK[@]}")
	if DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${want[@]}" >/dev/null 2>&1; then
		ok "installed ${#want[@]} packages (required + resolvable preferences)"
	else
		bad "apt-get install failed for the manifest"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------ A7: the user
install_user() {
	local key sudo_tmp
	# The key first: a user with sudo and no way in is not an improvement.
	if [ -z "$ROOT" ]; then
		if id -u "$ADMIN_USER" >/dev/null 2>&1; then
			inf "user $ADMIN_USER already exists (re-run: not recreated)"
		elif command -v useradd >/dev/null 2>&1; then
			useradd -m -d "$ADMIN_HOME" -s "$ADMIN_SHELL" -c "switch administrator" "$ADMIN_USER" \
				&& ok "created $ADMIN_USER" || { bad "useradd $ADMIN_USER failed"; return 1; }
		else
			bad "useradd is not available"; return 1
		fi
		# 🔴 LOCK THE PASSWORD. No hash, no crypt string, nothing to crack.
		# Never chpasswd, never a baked hash, not even a random one.
		if passwd -l "$ADMIN_USER" >/dev/null 2>&1; then ok "password for $ADMIN_USER is LOCKED (key-only auth)"
		else bad "could not lock the password for $ADMIN_USER"; fi
	else
		inf "ROOT is set: skipping useradd and the password lock (they describe a running system)"
	fi

	ensure_dir "$(rp "$ADMIN_HOME")" 0755
	# 0700 unconditionally: sshd REFUSES a group- or world-writable ~/.ssh, and
	# "refuses" here means the key-only login this whole image depends on stops
	# working, on a switch whose other door is a serial cable.
	install -d -m 0700 "$(rp "$ADMIN_HOME/.ssh")"
	key="$(rp "$ADMIN_HOME/.ssh/authorized_keys")"
	pubkey_bytes > "$key"
	chmod 0600 "$key"

	if looks_like_public_key "$key"; then
		ok "installed $ADMIN_HOME/.ssh/authorized_keys (0600, .ssh 0700) from a PUBLIC key"
	else
		bad "the installed authorized_keys does not look like a public key -- refusing"
		rm -f "$key"
		return 1
	fi

	if [ -z "$ROOT" ]; then
		chown -R "$ADMIN_USER:$ADMIN_USER" "$(rp "$ADMIN_HOME")" 2>/dev/null \
			&& ok "$ADMIN_HOME owned by $ADMIN_USER" || bad "could not chown $ADMIN_HOME"
	else
		inf "ROOT is set: $ADMIN_HOME ownership not changed (the build host has no such user)"
	fi

	# ---- sudo, validated BEFORE it lands
	if ! is_valid_sudoers_name "$(basename "$SUDOERS_DROPIN")"; then
		bad "sudoers drop-in name '$(basename "$SUDOERS_DROPIN")' contains a '.' or ends in '~' -- sudo would skip it silently"
		return 1
	fi
	ensure_dir "$(rp "$(dirname "$SUDOERS_DROPIN")")" 0750
	sudo_tmp="$(rp "$SUDOERS_DROPIN").tmp.$$"
	emit_sudoers > "$sudo_tmp"
	chmod 0440 "$sudo_tmp"
	case "$(sudoers_syntax_ok "$sudo_tmp"; echo $?)" in
	0) mv -f "$sudo_tmp" "$(rp "$SUDOERS_DROPIN")"
	   chmod 0440 "$(rp "$SUDOERS_DROPIN")"
	   own_root  "$(rp "$SUDOERS_DROPIN")"
	   ok "installed $SUDOERS_DROPIN (0440) after visudo -c -f accepted it" ;;
	2) rm -f "$sudo_tmp"
	   bad "visudo is not installed -- refusing to install an unvalidated sudoers file"; return 1 ;;
	*) rm -f "$sudo_tmp"
	   bad "the generated sudoers drop-in FAILED visudo -c -f -- not installed"; return 1 ;;
	esac

	inf "the cloud-init seed account is not touched by this stage in any way --"
	inf "another member removes it, and nothing here may make it un-removable"
	return 0
}

# ------------------------------------------------------------ A8: services
# 🔴 ENABLE ONLY. Never start, never restart. Enabling networkd is a symlink;
# starting it is a network reconfiguration performed over the network.
#
# 🔴 NO ALLOWLISTS EXIST IN THIS PROJECT. Every unit must either succeed in
# QEMU or carry a Condition* (never an Assert*) so a skipped unit reports
# SKIPPED and `systemctl --failed` stays empty with nothing muted. If a unit
# needs an allowlist, the unit is wrong.
SERVICES=(systemd-networkd systemd-resolved systemd-timesyncd)

enable_services() {
	if [ -n "$ROOT" ]; then
		inf "ROOT is set: skipping service enablement (a staged tree has no systemd to talk to)"
		return 0
	fi
	command -v systemctl >/dev/null 2>&1 || { bad "systemctl is not available"; return 1; }
	local s rc=0
	for s in "${SERVICES[@]}"; do
		if systemctl enable "$s" >/dev/null 2>&1; then ok "enabled $s (enable only -- NOT started)"
		else bad "could not enable $s"; rc=1; fi
	done
	inf "nothing was started or restarted: this stage reaches the guest over the"
	inf "very network systemd-networkd would reconfigure"
	return "$rc"
}

# ------------------------------------------------------------------- install
do_install() {
	hdr "stage-runtime-contract -- install"
	if [ -n "$ROOT" ]; then
		[ -d "$ROOT" ] || die "--root $ROOT does not exist"
		inf "staging into ROOT=$ROOT (nothing on this host is touched)"
	else
		[ "$(id -u)" = 0 ] || die "must run as root (or use --root DIR)"
	fi
	if [ -r "$(rp /etc/os-release)" ]; then
		# Identity from os-release, never from uname -r: trixie's
		# 6.12.100+deb13-amd64 and bookworm's 6.1.0-51-amd64 differ in FORMAT.
		inf "target identity: $(. "$(rp /etc/os-release)"; printf '%s %s' "${ID:-?}" "${VERSION_CODENAME:-${VERSION_ID:-?}}")"
	fi
	[ -n "$REPO" ] && inf "repo payload: $REPO" || inf "no repo payload visible -- using the embedded asset copies"

	hdr "A1. networkd units"
	install_units || true
	hdr "A2. udev port naming"
	install_udev_rule || true
	hdr "A3. GRUB cmdline drop-in"
	install_grub_dropin || true
	hdr "A4. sensor modules"
	install_modload || true
	hdr "A6. package manifest"
	install_packages || true
	hdr "A5. mlxsw-dkms"
	install_dkms_deb || true
	hdr "A7. user model"
	install_user || true
	hdr "A8. service enablement"
	enable_services || true
	hdr "A3b. regenerate and assert the GENERATED grub.cfg"
	if [ -n "$ROOT" ]; then
		inf "ROOT is set: skipping update-grub"
	else
		regenerate_grub || true
	fi
	assert_grubcfg || true

	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# -------------------------------------------------------------------- verify
verify_files() {
	local names base src n=0

	names="$(unit_names)"
	while IFS= read -r base; do
		[ -n "$base" ] || continue
		if [ ! -f "$(rp "$NET_DIR/$base")" ]; then bad "missing $NET_DIR/$base"; continue; fi
		if [ "$(stat -c%a "$(rp "$NET_DIR/$base")")" != 644 ]; then bad "$NET_DIR/$base is not mode 0644"; continue; fi
		if ! unit_bytes "$base" | cmp -s - "$(rp "$NET_DIR/$base")"; then bad "$NET_DIR/$base differs from its asset"; continue; fi
		n=$((n + 1))
	done <<-UNITS
	$names
	UNITS
	[ "$n" = "$(printf '%s\n' "$names" | grep -c .)" ] \
		&& ok "all $n networkd units present, 0644, byte-identical to assets/" \
		|| bad "only $n of $(printf '%s\n' "$names" | grep -c .) networkd units verified"

	src="$(asset_udev)"
	if [ -n "$src" ] && [ -r "$src" ]; then
		cmp -s "$src" "$(rp "$UDEV_RULE")" && ok "$UDEV_RULE is byte-identical to the asset" \
		                                   || bad "$UDEV_RULE is NOT byte-identical to the asset"
	else
		embedded_udev_rule | cmp -s - "$(rp "$UDEV_RULE")" && ok "$UDEV_RULE matches the embedded copy" \
		                                                  || bad "$UDEV_RULE does not match the embedded copy"
	fi
	grep -q 'phys_port_name' "$(rp "$UDEV_RULE")" && ok "$UDEV_RULE builds the name from \$attr{phys_port_name}" \
	                                              || bad "$UDEV_RULE has no phys_port_name rule"

	src="$(asset_grub)"
	if [ -n "$src" ] && [ -r "$src" ]; then
		cmp -s "$src" "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")" \
			&& ok "$GRUB_DROPIN_NAME is byte-identical to the asset (installed once, not appended)" \
			|| bad "$GRUB_DROPIN_NAME differs from the asset"
	fi
	local c
	c=$(grep -cE '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$(rp "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")" 2>/dev/null || true)
	[ "${c:-0}" = 1 ] && ok "$GRUB_DROPIN_NAME assigns GRUB_CMDLINE_LINUX exactly once (a re-run did not append)" \
	                  || bad "$GRUB_DROPIN_NAME assigns GRUB_CMDLINE_LINUX ${c:-0} times"

	emit_modload | cmp -s - "$(rp "$MODLOAD_CONF")" && ok "$MODLOAD_CONF matches what this stage writes" \
	                                                || bad "$MODLOAD_CONF differs from what this stage writes"
	grep -qx 'coretemp' "$(rp "$MODLOAD_CONF")" && grep -qx 'jc42' "$(rp "$MODLOAD_CONF")" \
		&& ok "$MODLOAD_CONF lists coretemp and jc42" || bad "$MODLOAD_CONF is missing a sensor module"

	if [ -f "$(rp "$ADMIN_HOME/.ssh/authorized_keys")" ] \
	   && [ "$(stat -c%a "$(rp "$ADMIN_HOME/.ssh/authorized_keys")")" = 600 ] \
	   && [ "$(stat -c%a "$(rp "$ADMIN_HOME/.ssh")")" = 700 ] \
	   && looks_like_public_key "$(rp "$ADMIN_HOME/.ssh/authorized_keys")"; then
		ok "authorized_keys 0600 in a 0700 .ssh, and it is a public key"
	else
		bad "the authorized_keys placement or mode is wrong"
	fi

	if [ -f "$(rp "$SUDOERS_DROPIN")" ] && [ "$(stat -c%a "$(rp "$SUDOERS_DROPIN")")" = 440 ]; then
		sudoers_syntax_ok "$(rp "$SUDOERS_DROPIN")" && ok "$SUDOERS_DROPIN is 0440 and visudo -c -f accepts it" \
		                                            || bad "$SUDOERS_DROPIN does not pass visudo -c -f"
	else
		bad "$SUDOERS_DROPIN is missing or not mode 0440"
	fi
	sudoers_is_nopasswd "$(rp "$SUDOERS_DROPIN")" \
		&& ok "every rule in $SUDOERS_DROPIN grants NOPASSWD (mandatory: the password is locked)" \
		|| bad "a rule in $SUDOERS_DROPIN would prompt for a password the account cannot have"
}

verify_running() {
	local k out
	k="$(uname -r)"

	hdr "V1. systemd state"
	if systemctl --failed --no-legend --plain 2>/dev/null | systemd_failed_clean; then
		ok "systemctl --failed is empty (unconditionally -- there are no allowlists here)"
	else
		bad "systemctl --failed lists units:"
		systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/       /'
	fi
	local s
	for s in "${SERVICES[@]}"; do
		systemctl is-enabled "$s" >/dev/null 2>&1 && ok "$s is enabled" || bad "$s is not enabled"
	done

	hdr "V2. networkd parsed its units (from the boot that already happened)"
	if journalctl -u systemd-networkd --no-pager -b 2>/dev/null | networkd_journal_clean; then
		ok "journalctl -u systemd-networkd contains no 'Unknown key name', 'Invalid' or 'Failed to parse'"
	else
		bad "systemd-networkd logged a parse complaint:"
		journalctl -u systemd-networkd --no-pager -b 2>/dev/null \
			| grep -E 'Unknown key name|Invalid|Failed to parse' | sed 's/^/       /'
	fi
	inf "networkd was NOT reloaded to provoke a re-parse -- that would sever this session"

	hdr "V3. the driver"
	if command -v dkms >/dev/null 2>&1; then
		if dkms status 2>/dev/null | dkms_reports_installed "$k"; then
			ok "dkms reports mlxsw installed for $k"
		else
			bad "dkms does not report mlxsw installed for $k:"
			dkms status 2>/dev/null | sed 's/^/       /'
		fi
	else
		bad "dkms is not installed"
	fi
	if mlxsw_modules_present "" "$k"; then
		ok "mlxsw*.ko* present in /lib/modules/$k/updates/dkms ($(find "/lib/modules/$k/updates/dkms" -maxdepth 1 -name 'mlxsw*.ko*' | grep -c .) modules)"
	else
		bad "no mlxsw*.ko* in /lib/modules/$k/updates/dkms -- this image has no data plane"
	fi

	hdr "V4. the package manifest, as installed"
	local p
	for p in "${EXCLUDED[@]}"; do
		pkg_installed "$p" && bad "EXCLUDED package is installed: $p" || ok "not installed: $p"
	done
	# 🔴 REPORTED BY NAME, NEVER MUTED, AND NOT COUNTED AS THIS STAGE'S FAILURE.
	# These arrive with the base image and are removed downstream. This stage
	# never installs them -- that half IS asserted, offline, in selftest S3 --
	# but it does not remove them, so it is not in a position to fail on their
	# presence. What it CAN do is say so out loud, with the owner named.
	for p in "${EXCLUDED_BASE_IMAGE[@]}"; do
		if pkg_installed "$p"; then
			inf "still present from the BASE IMAGE: $p ($(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)) -- owned by $EXCLUDED_BASE_IMAGE_OWNER, not by this stage"
			inf "  ⚠ nothing in this repo purges $p BY NAME today, and it is manually marked so purging cloud-init will not autoremove it"
		else
			ok "not installed: $p (already gone -- $EXCLUDED_BASE_IMAGE_OWNER ran first)"
		fi
	done
	# fancontrol gets a second, stronger assertion: not installed AND not enabled.
	if systemctl is-enabled fancontrol >/dev/null 2>&1; then
		bad "fancontrol.service is ENABLED -- in-kernel MLXSW_CORE_THERMAL already owns thermal control"
	else
		ok "fancontrol.service is not enabled (in-kernel MLXSW_CORE_THERMAL owns fan control)"
	fi
	local found=""
	for p in "${BOOTLOADER_EXPECTED[@]}"; do pkg_installed "$p" && found="$found $p"; done
	[ -n "$found" ] && ok "a bootloader is present from the base image and was never installed here:$found" \
	                || bad "no grub package is installed -- the base was expected to carry one"
	for p in "${REQUIRED_BUILD[@]}" "${REQUIRED_IMAGE[@]}"; do
		pkg_installed "$p" && ok "installed: $p" || bad "REQUIRED package is missing: $p"
	done

	hdr "V5. the premise audit's OWN contract"
	# ❌ Never "26/26". The total is data-dependent and a correct run can move
	# it. The contract is: zero failures, exit 0.
	local audit="" rc=0
	[ -n "$REPO" ] && [ -r "$REPO/scripts/mlxsw-premise-audit.sh" ] && audit="$REPO/scripts/mlxsw-premise-audit.sh"
	if [ -n "$audit" ]; then
		out="$(bash "$audit" 2>&1)" || rc=$?
		local nf; nf="$(printf '%s\n' "$out" | audit_failed_count)"
		if [ "$rc" = 0 ] && [ "${nf:-1}" = 0 ]; then
			ok "mlxsw-premise-audit: exit 0 and 0 failed ($(printf '%s\n' "$out" | grep -oE '[0-9]+ passed' | tail -1))"
		else
			bad "mlxsw-premise-audit: exit $rc, ${nf:-?} failed"
			printf '%s\n' "$out" | sed 's/^/       /'
		fi
	else
		inf "scripts/mlxsw-premise-audit.sh not in the payload -- skipped"
	fi

	hdr "V6. the user model"
	id -u "$ADMIN_USER" >/dev/null 2>&1 && ok "user $ADMIN_USER exists" || bad "user $ADMIN_USER does not exist"
	# `passwd -S` prints L for locked, NP for no password at all, P for a usable
	# password. NP is NOT acceptable: it means passwordless login.
	case "$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" in
	L)  ok "$ADMIN_USER's password is LOCKED" ;;
	NP) bad "$ADMIN_USER has NO password set (NP) -- that is passwordless login, not key-only" ;;
	P)  bad "$ADMIN_USER has a USABLE password -- no image may ever carry one" ;;
	*)  bad "could not read $ADMIN_USER's password state" ;;
	esac

	hdr "V7. the generated grub.cfg"
	assert_grubcfg || true
}

do_verify() {
	hdr "stage-runtime-contract -- verify"
	if [ -n "$ROOT" ]; then
		[ -d "$ROOT" ] || die "--root $ROOT does not exist"
		inf "verifying the staged tree $ROOT (file placement only)"
	fi
	hdr "V0. file placement"
	verify_files
	if [ -z "$ROOT" ]; then
		verify_running
	else
		inf "ROOT is set: the running-system assertions (systemctl, journal, dkms,"
		inf "apt, passwd) are skipped -- their predicates are proven by selftest"
	fi
	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# --------------------------------------------------------------- fingerprint
# The idempotence probe. Mode is included because a second run that silently
# widens a mode is exactly the kind of change "nothing observable" must catch.
OWNED_PATHS() {
	local base
	while IFS= read -r base; do [ -n "$base" ] && printf '%s\n' "$NET_DIR/$base"; done < <(unit_names)
	printf '%s\n' "$UDEV_RULE" \
	              "$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME" \
	              "$MODLOAD_CONF" \
	              "$ADMIN_HOME/.ssh" \
	              "$ADMIN_HOME/.ssh/authorized_keys" \
	              "$SUDOERS_DROPIN"
}

do_fingerprint() {
	local p f
	OWNED_PATHS | sort | while IFS= read -r p; do
		f="$(rp "$p")"
		if [ -d "$f" ];   then printf '%s  %s  %s\n' "dir" "$(stat -c%a "$f")" "$p"
		elif [ -f "$f" ]; then printf '%s  %s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$(stat -c%a "$f")" "$p"
		else                   printf '%s  %s  %s\n' "ABSENT" "----" "$p"
		fi
	done
}

# ---------------------------------------------------------------------- run
# 🔴 HOST-SIDE. scripts/vm.sh is NOT edited by this stage -- it gains exactly
# one dispatch line at integration, and the orchestrator applies it. Everything
# below rides the `ssh` dispatch that vm.sh already has:
#
#     ssh)  shift; ssh_vm "$@" ;;
#
# `vm.sh ssh 'sudo bash -s' < file` therefore works today and passes stdin
# through untouched, which is how this file reaches the guest with no repo in
# the guest and no change to vm.sh.
do_run() {
	local vm self f1 f2
	[ -n "$HERE" ] || die "run mode needs this script on disk (it ships itself into the guest)"
	self="${BASH_SOURCE[0]}"
	vm="$HERE/vm.sh"
	[ -x "$vm" ] || die "not found or not executable: $vm"
	[ -n "$REPO" ] && [ -r "$REPO/$DKMS_DEB_REL" ] || die "no $DKMS_DEB_REL under REPO=$REPO"

	hdr "R0. the guest"
	"$vm" ssh true >/dev/null 2>&1 || die "guest is not reachable -- run: scripts/vm.sh up"
	ok "guest reachable over vm.sh ssh"

	hdr "R1. ship the payload"
	# /run is tmpfs: the payload never becomes part of the image and is gone at
	# the next boot. Only what the stage INSTALLS survives.
	"$vm" ssh "sudo rm -rf $GUEST_PAYLOAD; sudo mkdir -p $GUEST_PAYLOAD; sudo chmod 0755 $GUEST_PAYLOAD" \
		|| die "could not prepare $GUEST_PAYLOAD in the guest"
	tar -C "$REPO" -czf - assets "$DKMS_DEB_REL" scripts/mlxsw-premise-audit.sh \
		| "$vm" ssh "sudo tar -C $GUEST_PAYLOAD -xzf -" \
		|| die "could not ship the payload into the guest"
	ok "shipped assets/, $(basename "$DKMS_DEB_REL") and the premise audit into $GUEST_PAYLOAD (tmpfs)"

	hdr "R2. install (first run)"
	"$vm" ssh "sudo bash -s -- install --repo $GUEST_PAYLOAD" < "$self" || die "install failed in the guest"
	f1="$("$vm" ssh "sudo bash -s -- fingerprint --repo $GUEST_PAYLOAD" < "$self")"

	hdr "R3. install (second run -- idempotence)"
	"$vm" ssh "sudo bash -s -- install --repo $GUEST_PAYLOAD" < "$self" || die "the second install failed"
	f2="$("$vm" ssh "sudo bash -s -- fingerprint --repo $GUEST_PAYLOAD" < "$self")"
	if [ "$f1" = "$f2" ]; then
		ok "idempotent: the second install changed nothing observable ($(printf '%s\n' "$f1" | grep -c .) paths)"
	else
		bad "the second install CHANGED something:"
		diff <(printf '%s\n' "$f1") <(printf '%s\n' "$f2") | sed 's/^/       /' || true
	fi

	hdr "R4. verify"
	"$vm" ssh "sudo bash -s -- verify --repo $GUEST_PAYLOAD" < "$self" || bad "verify reported failures in the guest"

	printf '\n%s\n' "----------------------------------------"
	printf 'host-side: %d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# ----------------------------------------------------------------- selftest
# 🔴 THE PHASE 1 DELIVERABLE. No VM, no root, no network.
#
# The organising rule: for every guard, generate the input that makes it FAIL
# and prove it fails. This project has shipped four checks that silently never
# ran, and every one was caught by the implementer rather than by review. A
# passing-path-only selftest is the exact defect.
SELFTEST_WORK=""
cleanup_selftest() { [ -n "$SELFTEST_WORK" ] && rm -rf "$SELFTEST_WORK"; }

# Forbidden-idiom grep over this script's own source, OUTSIDE comments.
# ⚠ Every pattern below is assembled from adjacent quoted fragments ('a''b') so
# the literal string never appears contiguously in this file -- otherwise the
# check would match its own definition and report a false positive. This is the
# same class of bug as `pkill -f` matching the shell that invoked it, which has
# already produced a false "still running" in this project.
SELF_SRC=""
forbid() { # $1 = ERE, $2 = description
	local hits
	hits="$(grep -nE "^[^#]*$1" "$SELF_SRC" || true)"
	if [ -z "$hits" ]; then ok "never $2"
	else bad "$2 -- found:"; printf '%s\n' "$hits" | sed 's/^/       /'; fi
}

do_selftest() {
	local W k r out
	# File-scope, not a local: the EXIT trap fires after this function's locals
	# are gone, and under `set -u` a trap referencing a dead local aborts.
	SELFTEST_WORK="$(mktemp -d)"
	W="$SELFTEST_WORK"
	trap cleanup_selftest EXIT
	k="6.12.100+deb13-amd64"      # trixie-shaped, deliberately not this host's

	hdr "S0  the embedded copies have not drifted from assets/"
	check_asset_drift || true

	hdr "S1  assets/ carries a PUBLIC key and no private one"
	if [ -n "$REPO" ] && [ -d "$REPO/assets" ]; then
		looks_like_public_key "$REPO/assets/id_ed25519.pub" \
			&& ok "assets/id_ed25519.pub is a public key" || bad "assets/id_ed25519.pub is not a public key"
		if grep -rlqi 'PRIVATE KEY' "$REPO/assets" 2>/dev/null; then
			bad "something under assets/ contains a PRIVATE KEY"
		else ok "nothing under assets/ contains a private key"; fi
		[ -e "$REPO/assets/id_ed25519" ] && bad "assets/id_ed25519 (the PRIVATE half) exists" \
		                                 || ok "assets/ has no id_ed25519 private half"
	else
		inf "no repo visible -- assets/ hygiene not checked"
	fi
	# MUST FAIL
	# A SYNTHETIC fixture, not a key: the banner is the whole point, and the body
	# is the base64 of the word NOTAKEY so no scanner ever has to wonder.
	printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nTk9UQUtFWQ==\n-----END OPENSSH PRIVATE KEY-----\n' > "$W/priv"
	looks_like_public_key "$W/priv" && bad "a private key was accepted as a public key" \
	                                || ok "a private key blob is REFUSED"
	: > "$W/empty"
	looks_like_public_key "$W/empty" && bad "an empty file was accepted as a public key" \
	                                 || ok "an empty file is REFUSED as a public key"
	printf 'not a key at all\n' > "$W/junk"
	looks_like_public_key "$W/junk" && bad "arbitrary text was accepted as a public key" \
	                                || ok "arbitrary text is REFUSED as a public key"

	hdr "S2  forbidden idioms, grepped out of this script's own source"
	if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
		SELF_SRC="${BASH_SOURCE[0]}"
		forbid 'systemctl'"[[:space:]]+(restart|reload|try-restart|start)[[:space:]]+systemd-networkd" \
			"restarts or starts systemd-networkd (it would sever the control channel)"
		forbid 'networkctl'"[[:space:]]+(reload|reconfigure|up|down)" \
			"reloads networkd via networkctl (the same forbidden action, renamed)"
		forbid 'dpkg'"[[:space:]]+-i([[:space:]]|$)" \
			"installs a .deb with the low-level dpkg installer (it resolves no dependencies)"
		forbid '(pkill|pgrep)'"[[:space:]]+-f" \
			"uses a -f process match (it matches its own invoking shell)"
		forbid 'chpass''wd' \
			"pipes a password into the system"
		forbid 'patch'"[[:space:]]+-p[0-9]" \
			"invokes patch(1) (this manifest EXCLUDES it; A4 writes a whole file)"
		forbid 'systemd-analyze'"[[:space:]]+verify" \
			"reaches for the systemd-analyze unit checker (it cannot parse .network/.netdev files)"
		forbid '26''/26' \
			"asserts the premise audit's data-dependent total"
		forbid '>''>'"[^\\n]*(GRUB_DROPIN|MODLOAD_CONF|UDEV_RULE|authorized_keys)" \
			"appends to a file it is supposed to write whole"
		forbid 'build''er' \
			"names the cloud-init seed account (another member removes it)"
		# ⚠ NOT grepped for here: a versioned `linux-headers-$(uname -r)`. The
		# MUST-FAIL fixture in S3 contains that string on purpose, so a source
		# grep would flag its own test. The real guard is
		# list_has_no_versioned_headers(), which is exercised in BOTH polarities
		# against the actual manifest -- an outcome check, not a source check.
	else
		inf "this script is not readable as a file -- the source greps are skipped"
	fi

	hdr "S2b forbid() ITSELF, watched to fail"
	# 🔴 THE GUARD NOBODY HAD WATCHED FAIL. Every forbid() call in S2 runs
	# against a source file that correctly contains none of the idioms, so
	# forbid()'s reporting branch had NEVER EXECUTED -- it was 11 checks that
	# had only ever been observed to pass. That is this project's recurring
	# defect exactly, and it matters more after Phase 2: `patch` left EXCLUDED
	# because it is a hard transitive dependency of build-essential and dkms, so
	# forbid('patch -p[0-9]') is now the ONLY thing asserting that this stage
	# never invokes patch(1).
	#
	# ⚠ Every literal below is split across adjacent quotes ('pat''ch') for the
	# same reason S2's patterns are: an unsplit literal would appear in this
	# file's own source and S2 would flag its own test as a violation.
	local fb
	mkdir -p "$W/forbid"
	printf 'x=1; sudo %s -p1 < /tmp/x.diff\n' 'pat''ch' > "$W/forbid/bait"
	fb="$( SELF_SRC="$W/forbid/bait"; pass=0; fail=0
	       forbid 'pat''ch'"[[:space:]]+-p[0-9]" "invokes patch(1)"; printf 'fail=%s' "$fail" )"
	case "$fb" in
	*"fail=1"*) ok "forbid() REPORTS an idiom that really is present (its failure branch is executable)" ;;
	*)          bad "forbid() did NOT report an idiom present in its input -- 11 source greps are decorative: $fb" ;;
	esac
	printf '%s\n' "$fb" | grep -q -- '-p1' \
		&& ok "forbid() prints the offending line, so the failure is actionable" \
		|| bad "forbid() reported a hit without showing the line"

	# MUST NOT FIRE: the idiom inside a COMMENT. The '^[^#]*' anchor is the
	# whole reason this file can describe the idioms it forbids.
	printf '# %s -p1 is exactly what this stage must never do\n' 'pat''ch' > "$W/forbid/comment"
	fb="$( SELF_SRC="$W/forbid/comment"; pass=0; fail=0
	       forbid 'pat''ch'"[[:space:]]+-p[0-9]" "invokes patch(1)"; printf 'fail=%s' "$fail" )"
	case "$fb" in
	*"fail=0"*) ok "forbid() does NOT fire on the idiom inside a comment (the ^[^#]* anchor works)" ;;
	*)          bad "forbid() fired on a commented-out idiom -- the file could not document what it forbids: $fb" ;;
	esac
	# MUST NOT FIRE: a file with nothing to find.
	printf 'echo hello\n' > "$W/forbid/clean"
	fb="$( SELF_SRC="$W/forbid/clean"; pass=0; fail=0
	       forbid 'pat''ch'"[[:space:]]+-p[0-9]" "invokes patch(1)"; printf 'fail=%s' "$fail" )"
	case "$fb" in
	*"fail=0"*) ok "forbid() passes a clean file" ;;
	*)          bad "forbid() reported a hit in a clean file: $fb" ;;
	esac
	# And the same for the networkd idiom, which is the one that would sever the
	# control channel -- proven to be detectable, not merely absent.
	# ⚠ SPLIT LITERAL, and S2 caught this one for real: written contiguously,
	# this fixture line IS a forbidden idiom in this script's own source and
	# S2's networkd grep flagged it. The guard works; the test had to stop
	# tripping it.
	printf '%s restart systemd-networkd\n' 'systemct''l' > "$W/forbid/net"
	fb="$( SELF_SRC="$W/forbid/net"; pass=0; fail=0
	       forbid 'systemctl'"[[:space:]]+(restart|reload|try-restart|start)[[:space:]]+systemd-networkd" \
	              "restarts systemd-networkd"; printf 'fail=%s' "$fail" )"
	case "$fb" in
	*"fail=1"*) ok "forbid() DETECTS a networkd restart (the one idiom that would sever the control channel)" ;;
	*)          bad "forbid() did not detect a networkd restart: $fb" ;;
	esac

	hdr "S3  the package manifest, offline"
	install_list | list_is_unique && ok "the install list has no duplicate names" || bad "the install list repeats a name"
	install_list | list_has_none_of "${EXCLUDED[@]}" && ok "the install list contains none of the ${#EXCLUDED[@]} EXCLUDED packages" \
	                                                 || bad "an EXCLUDED package is in the install list"
	# 🔴 THE NEVER-INSTALL HALF OF THE BASE-IMAGE LIST. verify_running() no
	# longer fails on their presence, so THIS is the assertion that keeps them
	# out of the apt transaction. It must exist or dropping the runtime FAIL
	# would have quietly removed the only guard.
	install_list | list_has_none_of "${EXCLUDED_BASE_IMAGE[@]}" \
		&& ok "the install list contains none of the ${#EXCLUDED_BASE_IMAGE[@]} BASE-IMAGE exclusions either (never installed here, merely not removed here)" \
		|| bad "a BASE-IMAGE exclusion is in the install list"
	# 🔴 THE TWO LISTS MEAN DIFFERENT THINGS AND MUST STAY DISJOINT. A name in
	# both would be asserted absent and excused for being present at the same
	# time, and the excuse would win -- a check that silently never runs.
	printf '%s\n' "${EXCLUDED[@]}" | list_has_none_of "${EXCLUDED_BASE_IMAGE[@]}" \
		&& ok "EXCLUDED and EXCLUDED_BASE_IMAGE are disjoint" \
		|| bad "a package is in BOTH exclusion lists -- the absence assertion would be silently excused"
	[ "${#EXCLUDED_BASE_IMAGE[@]}" -ge 1 ] && [ -n "$EXCLUDED_BASE_IMAGE_OWNER" ] \
		&& ok "every base-image exclusion has a named owner ($EXCLUDED_BASE_IMAGE_OWNER)" \
		|| bad "EXCLUDED_BASE_IMAGE has no named owner -- an unowned claim is nobody's job"
	# 🔴 PHASE 2 REGRESSION GUARD. `patch` was in EXCLUDED and could never be
	# absent: build-essential -> dpkg-dev -> patch (>= 2.7), and dkms depends on
	# it too. Both are in REQUIRED_BUILD. Measured installed on a real guest
	# before this stage ran. Re-adding it makes the stage permanently red.
	printf '%s\n' "${EXCLUDED[@]}" | list_has patch \
		&& bad "'patch' is back in EXCLUDED -- it is a hard transitive dep of build-essential AND dkms, so the assertion can never pass" \
		|| ok "'patch' is NOT asserted absent (it is a hard transitive dep of build-essential and dkms)"
	install_list | list_has patch \
		&& bad "'patch' is in the install list -- this stage does not install it, it merely arrives" \
		|| ok "'patch' is not installed by this stage either (it arrives via build-essential/dkms)"
	# MUST FAIL -- a synthetic overlap between the two lists is DETECTED
	printf 'fancontrol\ncloud-guest-utils\n' | list_has_none_of "${EXCLUDED_BASE_IMAGE[@]}" \
		&& bad "an overlap between the exclusion lists was accepted" \
		|| ok "an overlap between the two exclusion lists is DETECTED"
	install_list | list_has_no_bootloader && ok "the install list contains no grub package (assert, never install)" \
	                                      || bad "the install list would install a bootloader"
	install_list | list_has_no_versioned_headers && ok "the install list has no versioned linux-headers and never splices uname" \
	                                             || bad "the install list carries a versioned header package -- that is the R4 factory"
	install_list | list_has linux-headers-amd64 && ok "linux-headers-amd64 (the METAPACKAGE) is required" \
	                                            || bad "linux-headers-amd64 is not in the required set"
	install_list | list_has systemd-repart && ok "systemd-repart is named (a separate package on Debian, not in the base)" \
	                                       || bad "systemd-repart is not in the required set"
	printf '%s\n' "${PREFERRED[@]}" | list_has_none_of "${REQUIRED_BUILD[@]}" "${REQUIRED_IMAGE[@]}" \
		&& ok "no operator preference is hiding inside the required sets" \
		|| bad "a package appears in both a REQUIRED set and PREFERRED"
	# 🔴 REVERSED 2026-08-03. This block used to assert that `ipmiutil` IS in the
	# install list. It was dropped by operator ruling after the first run against
	# a real guest: it ships ipmiutil_wdt.service enabled by its own preset,
	# which exits 240 with no BMC and leaves a permanently failed unit in the
	# artifact. The assertion is inverted rather than deleted, because "we
	# removed it" is a claim that rots quietly -- a future manifest edit that
	# re-adds the package must fail here and be made to argue its case again.
	install_list | list_has_none_of ipmiutil \
		&& ok "ipmiutil is NOT in the install list (it ships an enabled watchdog unit that fails with no BMC)" \
		|| bad "ipmiutil is back in the install list -- it fails ruling 6 on any machine without a BMC"
	# Neither singular name may reappear by the other spelling, and the
	# nonexistent plural must never appear at all.
	install_list | list_has_none_of ipmitool \
		&& ok "ipmitool is not silently substituted (a different project; re-adding IPMI is a fresh decision)" \
		|| bad "ipmitool appeared without a ruling"
	# ⚠ NO SOURCE GREP HERE, deliberately. A `^[^#]*ipmiutils` guard flags its own
	# must-fail fixture -- the same self-matching trap that retired the
	# versioned-headers source grep. The outcome check IS the guard: what matters
	# is that the name never reaches apt, not that it never appears.
	install_list | list_has_none_of ipmiutils \
		&& ok "no nonexistent ipmi name can reach apt (checked by outcome, not by source grep)" \
		|| bad "a nonexistent ipmi name is in the install list"

	# MUST FAIL -- synthetic lists that each break one rule
	printf 'dkms\nlinux-headers-6.12.100+deb13-amd64\n' | list_has_no_versioned_headers \
		&& bad "a versioned linux-headers name was accepted" || ok "a versioned linux-headers name is REJECTED"
	printf 'dkms\nlinux-headers-$(uname -r)\n' | list_has_no_versioned_headers \
		&& bad "a uname-spliced header name was accepted" || ok "a uname-spliced header name is REJECTED"
	printf 'dkms\nfancontrol\n' | list_has_none_of "${EXCLUDED[@]}" \
		&& bad "fancontrol was accepted into an install list" || ok "fancontrol is REJECTED from an install list"
	printf 'dkms\npolicykit-1\n' | list_has_none_of "${EXCLUDED[@]}" \
		&& bad "policykit-1 was accepted (it does not exist on trixie)" || ok "policykit-1 is REJECTED"
	printf 'dkms\ngrub-pc\n' | list_has_no_bootloader \
		&& bad "a grub package was accepted into an install list" || ok "a grub package is REJECTED from an install list"
	printf 'dkms\nvim\ndkms\n' | list_is_unique \
		&& bad "a duplicated name was accepted" || ok "a duplicated name is REJECTED"

	hdr "S4  apt existence checks REFUSE to answer before apt-get update"
	# 🔴 OUTCOME, not exit status. A shim apt-cache writes a sentinel; if the
	# guard merely returned early but still shelled out, the sentinel appears
	# and this test fails. That is the difference between a guard and a comment.
	mkdir -p "$W/shim"
	cat > "$W/shim/apt-cache" <<-SHIM
	#!/bin/sh
	echo "apt-cache \$*" >> "$W/apt-cache.called"
	exit 0
	SHIM
	chmod 0755 "$W/shim/apt-cache"
	rm -f "$W/apt-cache.called"
	APT_INDEX_FRESH=0
	out=$(PATH="$W/shim:$PATH" pkg_candidate smartmontools 2>&1; echo "rc=$?")
	case "$out" in
	*"rc=2"*) ok "pkg_candidate returns 2 ('cannot answer') before apt-get update, not 1 ('absent')" ;;
	*)        bad "pkg_candidate did not refuse before apt-get update: $out" ;;
	esac
	[ -e "$W/apt-cache.called" ] && bad "pkg_candidate ran apt-cache anyway -- the guard is decorative" \
	                             || ok "pkg_candidate never executed apt-cache (proven by outcome, not by reading the code)"
	case "$out" in
	*absent*|*"does not exist"*) bad "the refusal message claims the package is absent" ;;
	*) ok "the refusal message does not claim the package is absent" ;;
	esac

	hdr "S5  the mlxsw-dkms package: a floor, never a ceiling"
	local deb dir dep n
	dir="$REPO/$(dirname "$DKMS_DEB_REL")"
	deb="$(asset_deb)"
	if [ -n "$deb" ] && [ -r "$deb" ]; then
		ok "the literal .deb exists: $DKMS_DEB_REL"
		n=$(ls -1 "$dir"/*+deb13u1_all.deb 2>/dev/null | grep -c . || true)
		[ "$n" = 1 ] && ok "exactly one *+deb13u1_all.deb in the dkms directory" \
		             || bad "$n files match *+deb13u1_all.deb -- the literal name is the only safe selector"
		n=$(ls -1 "$dir"/*.deb 2>/dev/null | grep -c . || true)
		[ "$n" -ge 3 ] && ok "*.deb would match $n files -- which is exactly why it is never used" \
		               || inf "*.deb matches $n files"
		[ -r "$dir/mlxsw-dkms_6.12.100-1_all.deb" ] && [ -r "$dir/mlxsw-dkms_6.1.177-1_all.deb" ] \
			&& ok "both FROZEN reference blobs are present and are not the install target" \
			|| bad "a frozen reference blob is missing"

		if command -v dpkg-deb >/dev/null 2>&1; then
			dep="$(dpkg-deb -f "$deb" Depends)"
			inf "Depends: $dep"
			dep_names "$dep" dkms                && ok "Depends names dkms"                || bad "Depends does not name dkms"
			dep_names "$dep" build-essential     && ok "Depends names build-essential"      || bad "Depends does not name build-essential"
			dep_names "$dep" linux-headers-amd64 && ok "Depends names linux-headers-amd64"  || bad "Depends does not name linux-headers-amd64"
			dep_has_floor "$dep" linux-headers-amd64 \
				&& ok "linux-headers-amd64 carries a >= floor" || bad "linux-headers-amd64 has no lower bound"
			printf '%s' "$dep" | grep -q 'linux-headers-amd64 (>= 6.12)' \
				&& ok "the floor is exactly (>= 6.12)" || inf "the floor is not the literal (>= 6.12)"
			dep_has_ceiling "$dep" linux-headers-amd64 \
				&& bad "🔴 linux-headers-amd64 has an UPPER BOUND -- apt will REMOVE mlxsw-dkms at the next kernel series bump" \
				|| ok "🔴 linux-headers-amd64 has NO upper bound (a floor, never a ceiling)"
		else
			inf "dpkg-deb is not installed -- the .deb metadata assertions are skipped"
		fi
	else
		bad "cannot read $DKMS_DEB_REL -- the offline package assertions cannot run"
	fi
	# MUST FAIL -- synthetic Depends fields
	dep_has_ceiling 'dkms, linux-headers-amd64 (<< 6.13)' linux-headers-amd64 \
		&& ok "a << ceiling is DETECTED" || bad "a << ceiling was not detected"
	dep_has_ceiling 'dkms, linux-headers-amd64 (<= 6.12.99)' linux-headers-amd64 \
		&& ok "a <= ceiling is DETECTED" || bad "a <= ceiling was not detected"
	dep_has_ceiling 'dkms, linux-headers-amd64 (= 6.12)' linux-headers-amd64 \
		&& ok "an exact = pin is DETECTED as a ceiling" || bad "an exact = pin was not detected"
	dep_has_ceiling 'dkms, linux-headers-amd64 (>= 6.12)' linux-headers-amd64 \
		&& bad "a >= floor was misread as a ceiling" || ok "a >= floor is NOT misread as a ceiling"
	dep_names 'dkms (>= 2.1), linux-headers-amd64 (>= 6.12)' build-essential \
		&& bad "a missing build-essential went unnoticed" || ok "a Depends without build-essential is DETECTED"
	dep_has_floor 'dkms, linux-headers-amd64' linux-headers-amd64 \
		&& bad "an unbounded dependency was read as having a floor" || ok "a missing floor is DETECTED"

	hdr "S6  the GENERATED grub.cfg predicate, both polarities"
	mkdir -p "$W/grub"
	# (a) healthy: the base's console tokens AND the drop-in's net.ifnames=0
	cat > "$W/grub/good.cfg" <<-'CFG'
	menuentry 'Debian GNU/Linux' $menuentry_id_option 'gnulinux-simple-1111' {
		linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111 ro net.ifnames=0 console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0
	}
	submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-1111' {
		menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64' $menuentry_id_option 'gnulinux-6.12.100-advanced-1111' {
			linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111 ro net.ifnames=0 console=tty0 console=ttyS0,115200
		}
		menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64 (recovery mode)' $menuentry_id_option 'gnulinux-6.12.100-recovery-1111' {
			linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111 ro single net.ifnames=0
		}
	}
	CFG
	grubcfg_cmdline_intact "$W/grub/good.cfg" \
		&& ok "a healthy grub.cfg passes (recovery entries correctly excluded)" \
		|| bad "a healthy grub.cfg was rejected"
	[ "$(grubcfg_boot_lines "$W/grub/good.cfg" | grep -c .)" = 2 ] \
		&& ok "recovery entries are excluded from the assertion (2 of 3 lines counted)" \
		|| bad "recovery entries were not excluded"

	# (b) CLOBBERED: a drop-in that assigned instead of appending
	sed 's/console=tty0 console=ttyS0,115200[^ ]*//g; s/earlyprintk=[^ ]*//g; s/consoleblank=0//g' \
		"$W/grub/good.cfg" > "$W/grub/clobbered.cfg"
	grubcfg_cmdline_intact "$W/grub/clobbered.cfg" \
		&& bad "a grub.cfg whose serial console was CLOBBERED passed -- this is the exact defect the check exists for" \
		|| ok "a CLOBBERED serial console is DETECTED on the generated file"

	# (c) drop-in never applied
	sed 's/net\.ifnames=0//g' "$W/grub/good.cfg" > "$W/grub/nodropin.cfg"
	grubcfg_cmdline_intact "$W/grub/nodropin.cfg" \
		&& bad "a grub.cfg with no net.ifnames=0 passed" || ok "a missing net.ifnames=0 is DETECTED"

	# (d) PARTIAL clobber -- one entry good, one entry broken. A whole-file grep
	#     would find both tokens somewhere and pass this. Per-line does not.
	awk 'NR==6 {gsub(/console=ttyS0,115200/, "")} {print}' "$W/grub/good.cfg" > "$W/grub/partial.cfg"
	grubcfg_cmdline_intact "$W/grub/partial.cfg" \
		&& bad "a PARTIAL clobber passed -- the check is a whole-file grep, not per-line" \
		|| ok "a partial clobber (one entry of two) is DETECTED"

	# (e) nothing to assert against
	: > "$W/grub/empty.cfg"
	grubcfg_cmdline_intact "$W/grub/empty.cfg" && bad "an empty grub.cfg passed" || ok "an empty grub.cfg is REJECTED"
	grubcfg_cmdline_intact "$W/grub/nope.cfg"  && bad "a missing grub.cfg passed" || ok "a missing grub.cfg is REJECTED"

	hdr "S6b the REAL generated grub.cfg, captured off a provisioned trixie guest"
	# 🔴 A MEASURED FIXTURE, NOT A HAND-WRITTEN ONE. Everything above this point
	# was invented by the author of the check, which means it can only ever
	# confirm the author's model of grub-mkconfig. These lines are the actual
	# output of `update-grub` on debian-13-generic after this stage installed
	# 20_switch-cmdline.cfg, captured 2026-08-02 (kernel 6.12.100+deb13-amd64,
	# with 6.12.96 still present from before the provision upgrade).
	#
	# It records three facts the synthetic fixture could not:
	#   1. the base puts its console tokens in GRUB_CMDLINE_LINUX, NOT in
	#      GRUB_CMDLINE_LINUX_DEFAULT, so RECOVERY entries carry them too;
	#   2. every kernel line has a TRAILING SPACE after net.ifnames=0;
	#   3. two kernel series coexist in one file -- five kernel lines, three of
	#      them non-recovery.
	#
	# ⚠ The heredoc's leading indentation is normalised; the kernel command
	# lines themselves are verbatim, and those are what the predicate reads.
	cat > "$W/grub/real.cfg" <<-'CFG'
	serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
	terminal_input serial console
	terminal_output serial console
	menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class gnu --class os $menuentry_id_option 'gnulinux-simple-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=8dc1f76b-78c4-43ca-9fb0-027bef73886e ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
	}
	submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64' --class debian $menuentry_id_option 'gnulinux-6.12.100+deb13-amd64-advanced-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=8dc1f76b-78c4-43ca-9fb0-027bef73886e ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
	}
	menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64 (recovery mode)' --class debian $menuentry_id_option 'gnulinux-6.12.100+deb13-amd64-recovery-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	linux	/boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=8dc1f76b-78c4-43ca-9fb0-027bef73886e ro single dis_ucode_ldr console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
	}
	menuentry 'Debian GNU/Linux, with Linux 6.12.96+deb13-amd64' --class debian $menuentry_id_option 'gnulinux-6.12.96+deb13-amd64-advanced-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	linux	/boot/vmlinuz-6.12.96+deb13-amd64 root=PARTUUID=8dc1f76b-78c4-43ca-9fb0-027bef73886e ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
	}
	menuentry 'Debian GNU/Linux, with Linux 6.12.96+deb13-amd64 (recovery mode)' --class debian $menuentry_id_option 'gnulinux-6.12.96+deb13-amd64-recovery-452e94f8-0a67-4848-8598-f2fa0aaca72d' {
	linux	/boot/vmlinuz-6.12.96+deb13-amd64 root=PARTUUID=8dc1f76b-78c4-43ca-9fb0-027bef73886e ro single dis_ucode_ldr console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=0
	}
	}
	CFG
	grubcfg_cmdline_intact "$W/grub/real.cfg" \
		&& ok "the REAL generated grub.cfg passes the cmdline assertion" \
		|| bad "the REAL generated grub.cfg FAILS the cmdline assertion -- the predicate does not match reality"
	[ "$(grubcfg_boot_lines "$W/grub/real.cfg" | grep -c .)" = 3 ] \
		&& ok "the real file has 3 non-recovery kernel lines across 2 kernel series (2 recovery lines excluded)" \
		|| bad "expected 3 non-recovery kernel lines in the real file, got $(grubcfg_boot_lines "$W/grub/real.cfg" | grep -c .)"
	# 🔴 THE MEASURED CORRECTION. The old comment claimed recovery entries do
	# not carry the base's console tokens. On this base they DO, because the
	# base uses GRUB_CMDLINE_LINUX. Asserted so the corrected comment cannot rot.
	[ "$(grep -c 'single dis_ucode_ldr.*console=ttyS0,115200' "$W/grub/real.cfg")" = 2 ] \
		&& ok "recovery entries DO carry the base's console tokens (the base uses GRUB_CMDLINE_LINUX, not _DEFAULT)" \
		|| bad "the recovery-entry measurement no longer holds -- re-read the corrected comment on grubcfg_boot_lines()"

	# ---- serial steerability, both polarities, against the measured file
	grubcfg_serial_intact "$W/grub/real.cfg" \
		&& ok "the REAL generated grub.cfg carries serial --speed=115200 and terminal_input serial" \
		|| bad "the REAL generated grub.cfg has no steerable serial console"
	# MUST FAIL (a) GRUB_SERIAL_COMMAND lost -> GRUB's own 9600-baud fallback
	sed 's/^serial --speed=115200.*/serial/' "$W/grub/real.cfg" > "$W/grub/serial9600.cfg"
	grubcfg_serial_intact "$W/grub/serial9600.cfg" \
		&& bad "a bare 'serial' line (GRUB's 9600-baud default against a 115200 kernel console) was ACCEPTED" \
		|| ok "GRUB falling back to its own 9600-baud default is DETECTED"
	# MUST FAIL (b) the base image's own shape: output only, no serial INPUT
	grep -v '^terminal_input' "$W/grub/real.cfg" \
		| sed 's/^terminal_output.*/terminal_output gfxterm serial/' > "$W/grub/outputonly.cfg"
	grubcfg_serial_intact "$W/grub/outputonly.cfg" \
		&& bad "a grub.cfg with serial OUTPUT but no serial INPUT was accepted -- that menu can be read and never steered" \
		|| ok "serial output without serial input is DETECTED (this is the base image's own untreated shape)"
	# MUST FAIL (c) terminal_input present but not on the serial line
	sed 's/^terminal_input.*/terminal_input console/' "$W/grub/real.cfg" > "$W/grub/inputnoserial.cfg"
	grubcfg_serial_intact "$W/grub/inputnoserial.cfg" \
		&& bad "terminal_input without 'serial' was accepted" || ok "terminal_input that omits serial is DETECTED"
	# MUST FAIL (d) nothing at all
	grubcfg_serial_intact "$W/grub/empty.cfg" && bad "an empty grub.cfg passed the serial check" || ok "an empty grub.cfg is REJECTED by the serial check"
	grubcfg_serial_intact "$W/grub/nope.cfg"  && bad "a missing grub.cfg passed the serial check" || ok "a missing grub.cfg is REJECTED by the serial check"

	hdr "S6c the base image's /etc/default/grub, as measured"
	# 🔴 THE INPUT SIDE OF THE SAME QUESTION, and the fact the whole append-never-
	# assign design rests on. Captured verbatim off the pristine
	# debian-13-generic-amd64 trixie image, 2026-08-02, BEFORE this stage ran.
	# If a future base moves the console tokens into GRUB_CMDLINE_LINUX_DEFAULT,
	# 20_switch-cmdline.cfg would append to the wrong variable and the recovery
	# entries would silently lose the serial console.
	cat > "$W/grub/default-grub" <<-'DEFGRUB'
	GRUB_DEFAULT=0
	GRUB_TIMEOUT=5
	GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
	GRUB_CMDLINE_LINUX_DEFAULT=""
	GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0"
	GRUB_TERMINAL_OUTPUT="gfxterm serial"
	GRUB_SERIAL_COMMAND="serial --speed=115200"
	DEFGRUB
	grep -qE '^GRUB_CMDLINE_LINUX="[^"]*console=ttyS0,115200' "$W/grub/default-grub" \
		&& ok "the base image puts its console tokens in GRUB_CMDLINE_LINUX -- which is the variable the drop-in appends to" \
		|| bad "the base image's console tokens are NOT in GRUB_CMDLINE_LINUX; the drop-in appends to the wrong variable"
	grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=""$' "$W/grub/default-grub" \
		&& ok "GRUB_CMDLINE_LINUX_DEFAULT is empty in the base (nothing of ours belongs there)" \
		|| bad "GRUB_CMDLINE_LINUX_DEFAULT is no longer empty in the base -- re-measure before trusting the drop-in"
	grep -qE '^GRUB_TERMINAL_OUTPUT="gfxterm serial"$' "$W/grub/default-grub" \
		&& ok "the base sets GRUB_TERMINAL_OUTPUT only -- which is exactly why the drop-in must set GRUB_TERMINAL for serial INPUT" \
		|| bad "the base's GRUB_TERMINAL_OUTPUT changed -- the drop-in's stated trade-off needs re-checking"
	# 🔴 THE UNVERIFIED ASSUMPTION, NOW MEASURED. "nothing sorts after 20_" was
	# an assumption in the drop-in's own comment and had never been checked.
	# ls -1 /etc/default/grub.d/ on the pristine base returned exactly these two.
	printf '10_cloud.cfg\n15_timeout.cfg\n' > "$W/grub/grubd-inventory"
	[ "$(sort "$W/grub/grubd-inventory" | tail -1)" = "15_timeout.cfg" ] \
		&& ok "the base's /etc/default/grub.d holds only 10_cloud.cfg and 15_timeout.cfg -- nothing sorts after 20_ (measured, no longer assumed)" \
		|| bad "something in the base's /etc/default/grub.d sorts after 20_switch-cmdline.cfg and would win"

	hdr "S7  sudoers: validated before it lands, and the name is legal"
	emit_sudoers > "$W/sudoers.good"; chmod 0440 "$W/sudoers.good"
	sudoers_syntax_ok "$W/sudoers.good" && ok "the generated sudoers drop-in passes visudo -c -f" \
	                                    || bad "the generated sudoers drop-in FAILS visudo -c -f"
	printf '%s ALL=(ALL:ALL NOPASSWD:ALL\n((((\n' "$ADMIN_USER" > "$W/sudoers.bad"; chmod 0440 "$W/sudoers.bad"
	sudoers_syntax_ok "$W/sudoers.bad" && bad "a MALFORMED sudoers file passed the validator" \
	                                   || ok "a malformed sudoers file is REJECTED by the same validator"
	sudoers_is_nopasswd "$W/sudoers.good" \
		&& ok "every RULE in the drop-in grants NOPASSWD (forced: the password is locked, so a prompt could never be answered)" \
		|| bad "a rule in the drop-in would prompt for a password the account cannot have"
	# MUST FAIL. 🔴 The first version of this check was `grep -q NOPASSWD file`
	# and it passed on exactly this input, because the file's comment says
	# "NOPASSWD". The fixture keeps that comment so the regression stays caught.
	printf '# NOPASSWD is load-bearing, see the stage.\n%s ALL=(ALL:ALL) ALL\n' "$ADMIN_USER" > "$W/sudoers.pw"
	sudoers_is_nopasswd "$W/sudoers.pw" \
		&& bad "a password-demanding rule passed the NOPASSWD check (it is matching the comment, not the rule)" \
		|| ok "a password-demanding rule is DETECTED even when the comment says NOPASSWD"
	printf '# comment only\n' > "$W/sudoers.empty"
	sudoers_is_nopasswd "$W/sudoers.empty" \
		&& bad "a drop-in with no rule at all passed" || ok "a drop-in with no rule at all is REJECTED"
	is_valid_sudoers_name "$(basename "$SUDOERS_DROPIN")" \
		&& ok "'$(basename "$SUDOERS_DROPIN")' is a name sudo will actually read" \
		|| bad "'$(basename "$SUDOERS_DROPIN")' would be skipped silently by #includedir"
	is_valid_sudoers_name '90-johns.conf' && bad "a dotted sudoers name was accepted" || ok "a dotted sudoers name is REJECTED (sudo skips it silently)"
	is_valid_sudoers_name '90-johns~'     && bad "a tilde sudoers name was accepted"  || ok "a ~-suffixed sudoers name is REJECTED"
	is_valid_sudoers_name ''              && bad "an empty sudoers name was accepted" || ok "an empty sudoers name is REJECTED"

	hdr "S8  runtime text predicates, both polarities"
	printf '' | systemd_failed_clean && ok "an empty systemctl --failed is clean" || bad "an empty systemctl --failed was read as dirty"
	printf '  \n\n' | systemd_failed_clean && ok "whitespace-only systemctl --failed is clean" || bad "whitespace was read as a failed unit"
	printf 'foo.service loaded failed failed Some description\n' | systemd_failed_clean \
		&& bad "a failed unit was read as clean" || ok "a failed unit is DETECTED"
	printf 'Started systemd-networkd\nEnumeration completed\n' | networkd_journal_clean \
		&& ok "a clean networkd journal passes" || bad "a clean networkd journal was rejected"
	printf 'Unknown key name '"'"'Bond'"'"' in section [Network]\n' | networkd_journal_clean \
		&& bad "'Unknown key name' was not detected" || ok "'Unknown key name' in the networkd journal is DETECTED"
	printf 'Failed to parse MTUBytes=, ignoring\n' | networkd_journal_clean \
		&& bad "'Failed to parse' was not detected" || ok "'Failed to parse' in the networkd journal is DETECTED"
	printf 'mlxsw/6.12.100, %s, x86_64: installed\n' "$k" | dkms_reports_installed "$k" \
		&& ok "dkms status reporting 'installed' for the running kernel passes" || bad "a good dkms status was rejected"
	printf 'mlxsw/6.12.100, 6.12.96+deb13-amd64, x86_64: installed\n' | dkms_reports_installed "$k" \
		&& bad "dkms status for a DIFFERENT kernel passed -- that is R4" || ok "dkms status for a different kernel is DETECTED as R4"
	printf 'mlxsw/6.12.100: added\n' | dkms_reports_installed "$k" \
		&& bad "an 'added' dkms module was read as installed" || ok "an 'added'-only dkms module is DETECTED"
	printf '' | dkms_reports_installed "$k" && bad "empty dkms status passed" || ok "empty dkms status is DETECTED"
	printf '25 passed, 0 failed, 4 notes\n' | audit_failed_count | grep -qx 0 \
		&& ok "the audit's failed count is read from its own summary (not a hardcoded total)" \
		|| bad "could not read the audit's failed count"
	printf '31 passed, 2 failed, 4 notes\n' | audit_failed_count | grep -qx 2 \
		&& ok "a NON-ZERO audit failure count is read correctly at a different total" \
		|| bad "the audit failure count was misread when the total moved"

	hdr "S9  the module glob is '*.ko*', never '*.ko'"
	mkdir -p "$W/mod-trixie/lib/modules/$k/updates/dkms" "$W/mod-bookworm/lib/modules/$k/updates/dkms" \
	         "$W/mod-empty/lib/modules/$k/updates/dkms" "$W/mod-decoy/lib/modules/$k/updates/dkms"
	: > "$W/mod-trixie/lib/modules/$k/updates/dkms/mlxsw_spectrum.ko.xz"
	: > "$W/mod-bookworm/lib/modules/$k/updates/dkms/mlxsw_spectrum.ko"
	: > "$W/mod-decoy/lib/modules/$k/updates/dkms/some-other.ko.xz"
	mlxsw_modules_present "$W/mod-trixie" "$k"   && ok "trixie shape (.ko.xz) is found" || bad "trixie .ko.xz not found -- the glob is '*.ko'"
	mlxsw_modules_present "$W/mod-bookworm" "$k" && ok "bookworm shape (plain .ko) is found" || bad "bookworm .ko not found"
	mlxsw_modules_present "$W/mod-empty" "$k"    && bad "an empty module dir was read as healthy" || ok "an empty module dir is DETECTED (this IS R4)"
	mlxsw_modules_present "$W/mod-decoy" "$k"    && bad "a non-mlxsw module was accepted" || ok "non-mlxsw modules only are DETECTED (the glob is mlxsw-specific)"
	mlxsw_modules_present "$W/nothing" "$k"      && bad "a missing tree was read as healthy" || ok "a missing module tree is DETECTED"

	hdr "S10  a full offline install into a scratch root"
	local FR="$W/fakeroot"
	mkdir -p "$FR/etc/default/grub.d"
	printf 'GRUB_TIMEOUT=0\n' > "$FR/etc/default/grub.d/15_timeout.cfg"
	printf 'GRUB_DISABLE_LINUX_UUID=true\n' > "$FR/etc/default/grub.d/10_cloud.cfg"
	printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_TIMEOUT_STYLE=menu\n' > "$FR/etc/default/grub.d/25_switch-boot-policy.cfg"
	mkdir -p "$FR/etc"
	printf '# /etc/modules: kernel modules to load at boot time.\nloop\n' > "$FR/etc/modules"
	local etcmod_before; etcmod_before="$(sha256sum < "$FR/etc/modules")"

	# 🔴 THE STRONGEST TEST IN THIS FILE. Shims for every program that only
	# means something on a running system are put FIRST in PATH and record every
	# invocation. Under --root none of them may be called even once. This proves
	# the ROOT branch by OUTCOME, not by reading the code -- which is exactly
	# how the four "checks that never ran" got past review.
	mkdir -p "$W/guard"
	local g
	for g in apt apt-get apt-cache dpkg dpkg-query dkms systemctl useradd usermod passwd update-grub grub-mkconfig networkctl journalctl chown; do
		{ printf '#!/bin/sh\n'; printf 'echo "%s $*" >> "%s"\n' "$g" "$W/guard.called"; printf 'exit 0\n'; } > "$W/guard/$g"
		chmod 0755 "$W/guard/$g"
	done
	rm -f "$W/guard.called"

	# 🔴 pass/fail are RESET in every nested subshell. Without it the nested
	# run inherits the selftest's running totals, its own `[ $fail -eq 0 ]` sees
	# failures it did not cause, and a perfectly good install reports failure --
	# a check reporting on something other than what it measured.
	if ( pass=0; fail=0; PATH="$W/guard:$PATH" ROOT="$FR" do_install > "$W/install.log" 2>&1 ); then
		ok "install --root exits 0"
	else
		bad "install --root failed"; sed 's/^/       /' "$W/install.log"
	fi
	if [ -e "$W/guard.called" ]; then
		bad "install --root invoked a running-system program:"
		sort -u "$W/guard.called" | sed 's/^/       /'
	else
		ok "install --root invoked NONE of apt/dpkg/dkms/systemctl/useradd/passwd/update-grub/networkctl/chown"
	fi

	# A1 outcomes
	local names n_in n_out
	names="$(unit_names)"; n_in=$(printf '%s\n' "$names" | grep -c .)
	n_out=$( ( cd "$FR$NET_DIR" && ls -1 ) 2>/dev/null | grep -c . || true)
	[ "$n_in" = "$n_out" ] && ok "count-in == count-out for the networkd units ($n_in)" \
	                       || bad "networkd units: $n_in in assets, $n_out installed"
	local u bad_bytes=0 bad_mode=0
	while IFS= read -r u; do
		[ -n "$u" ] || continue
		unit_bytes "$u" | cmp -s - "$FR$NET_DIR/$u" || bad_bytes=1
		[ "$(stat -c%a "$FR$NET_DIR/$u" 2>/dev/null)" = 644 ] || bad_mode=1
	done <<-UNITS
	$names
	UNITS
	[ "$bad_bytes" = 0 ] && ok "every installed networkd unit is byte-identical to its asset" || bad "an installed networkd unit differs from its asset"
	[ "$bad_mode"  = 0 ] && ok "every installed networkd unit is mode 0644" || bad "an installed networkd unit is not 0644"

	# A2 outcomes -- byte-identity including the stray prompt comment
	if [ -n "$REPO" ] && [ -r "$(asset_udev)" ]; then
		cmp -s "$(asset_udev)" "$FR$UDEV_RULE" && ok "$UDEV_RULE is byte-identical to the asset" || bad "$UDEV_RULE is not byte-identical"
	fi
	head -1 "$FR$UDEV_RULE" | grep -q '^#' && ok "the udev rule's stray prompt comment survived (it is provenance, not litter)" \
	                                       || bad "the udev rule's first-line comment was tidied away"
	grep -q 'phys_port_name' "$FR$UDEV_RULE" && ok "the udev rule names \$attr{phys_port_name}" || bad "the udev rule lost its NAME= expression"
	grep -q 'swp' "$FR$UDEV_RULE" && bad "the udev rule contains the literal 'swp' -- the search trap note is now wrong" \
	                              || ok "the udev rule contains no literal 'swp' (search mlxsw or phys_port_name)"

	# A3 outcomes
	if [ -n "$REPO" ] && [ -r "$(asset_grub)" ]; then
		cmp -s "$(asset_grub)" "$FR$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME" \
			&& ok "$GRUB_DROPIN_NAME is byte-identical to the asset (installed, not authored)" \
			|| bad "$GRUB_DROPIN_NAME differs from the asset"
	fi
	[ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GRUB_' "$FR$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME")" = 3 ] \
		&& ok "the drop-in assigns exactly 3 variables" \
		|| bad "the drop-in assigns $(grep -cE '^[[:space:]]*(export[[:space:]]+)?GRUB_' "$FR$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME") variables, expected 3"
	grep -q 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+' "$FR$GRUB_DROPIN_DIR/$GRUB_DROPIN_NAME" \
		&& ok "the drop-in APPENDS to GRUB_CMDLINE_LINUX (the base's console tokens survive)" \
		|| bad "the drop-in assigns GRUB_CMDLINE_LINUX outright -- it would clobber the serial console"
	[ -f "$FR$GRUB_DROPIN_DIR/15_timeout.cfg" ] && ok "15_timeout.cfg untouched (another member owns it)" || bad "15_timeout.cfg was removed"
	[ -f "$FR$GRUB_DROPIN_DIR/10_cloud.cfg" ]   && ok "10_cloud.cfg untouched (another member owns it)"   || bad "10_cloud.cfg was removed"
	grep -qE '^(GRUB_DEFAULT|GRUB_TIMEOUT|GRUB_TIMEOUT_STYLE)=' "$FR$GRUB_DROPIN_DIR/25_switch-boot-policy.cfg" \
		&& ok "25_switch-boot-policy.cfg untouched (the two variable sets stay disjoint)" || bad "the sibling drop-in was modified"

	# A4 outcomes
	grep -qx 'coretemp' "$FR$MODLOAD_CONF" && grep -qx 'jc42' "$FR$MODLOAD_CONF" \
		&& ok "$MODLOAD_CONF lists coretemp and jc42" || bad "$MODLOAD_CONF is missing a sensor module"
	[ "$(grep -cx 'coretemp' "$FR$MODLOAD_CONF")" = 1 ] && ok "coretemp appears exactly once (whole-file write, not an append)" \
	                                                    || bad "coretemp is listed more than once"
	[ "$(sha256sum < "$FR/etc/modules")" = "$etcmod_before" ] \
		&& ok "/etc/modules was NOT touched (it feeds the same service via modules-load.d/modules.conf)" \
		|| bad "/etc/modules was modified -- that is a second authority for one outcome"
	rm -f "$FR/etc/modules"
	( pass=0; fail=0; PATH="$W/guard:$PATH" ROOT="$FR" do_install > /dev/null 2>&1 ) || true
	[ -e "$FR/etc/modules" ] && bad "/etc/modules was CREATED by the stage" || ok "/etc/modules is never created by this stage"

	# A7 outcomes
	[ "$(stat -c%a "$FR$ADMIN_HOME/.ssh")" = 700 ]                 && ok "$ADMIN_HOME/.ssh is 0700" || bad ".ssh is not 0700"
	[ "$(stat -c%a "$FR$ADMIN_HOME/.ssh/authorized_keys")" = 600 ]  && ok "authorized_keys is 0600" || bad "authorized_keys is not 0600"
	looks_like_public_key "$FR$ADMIN_HOME/.ssh/authorized_keys"     && ok "authorized_keys holds a public key" || bad "authorized_keys is not a public key"
	pubkey_bytes | cmp -s - "$FR$ADMIN_HOME/.ssh/authorized_keys"   && ok "authorized_keys is byte-identical to assets/id_ed25519.pub" || bad "authorized_keys differs from the asset"
	[ "$(stat -c%a "$FR$SUDOERS_DROPIN")" = 440 ]                   && ok "$SUDOERS_DROPIN is 0440" || bad "the sudoers drop-in is not 0440"
	sudoers_syntax_ok "$FR$SUDOERS_DROPIN"                          && ok "the installed sudoers drop-in passes visudo -c -f" || bad "the installed sudoers drop-in fails visudo"
	ls -1 "$FR/etc/sudoers.d" | grep -q '\.tmp\.' && bad "a .tmp sudoers file was left behind (sudo would skip it, but it is litter in /etc/sudoers.d)" \
	                                              || ok "no temporary file left in /etc/sudoers.d"

	hdr "S11  idempotence: a second install changes nothing observable"
	local fp1 fp2
	fp1="$(ROOT="$FR" do_fingerprint)"
	( pass=0; fail=0; PATH="$W/guard:$PATH" ROOT="$FR" do_install > /dev/null 2>&1 ) || true
	fp2="$(ROOT="$FR" do_fingerprint)"
	if [ "$fp1" = "$fp2" ]; then
		ok "a second install produced an identical fingerprint ($(printf '%s\n' "$fp1" | grep -c .) paths, content + mode)"
	else
		bad "a second install changed something:"; diff <(printf '%s\n' "$fp1") <(printf '%s\n' "$fp2") | sed 's/^/       /' || true
	fi
	printf '%s\n' "$fp1" | grep -q 'ABSENT' && bad "the fingerprint lists an ABSENT path after a successful install:" \
	                                        || ok "every path this stage owns exists after install"
	printf '%s\n' "$fp1" | grep 'ABSENT' | sed 's/^/       /' || true

	hdr "S12  verify --root agrees with what install --root wrote"
	if ( pass=0; fail=0; ROOT="$FR" do_verify > "$W/verify.log" 2>&1 ); then ok "verify --root exits 0 against the tree install --root produced"
	else bad "verify --root disagreed with install --root:"; sed 's/^/       /' "$W/verify.log"; fi

	hdr "S13  the unit set is DISCOVERED, not hardcoded"
	# A synthetic repo with a SEVENTH unit file. A hardcoded list drops it
	# silently; the glob must pick it up and the count must move to 7.
	local SR="$W/synthrepo"
	if [ -n "$REPO" ] && [ -d "$REPO/assets" ]; then
		mkdir -p "$SR"
		cp -a "$REPO/assets" "$SR/assets"
		printf '[Match]\nName=fake0\n\n[Network]\nDHCP=no\n' > "$SR/assets/etc.systemd.network/36-a-seventh-unit.network"
		local SFR="$W/synthroot"; mkdir -p "$SFR"
		( pass=0; fail=0; PATH="$W/guard:$PATH" REPO="$SR" ROOT="$SFR" do_install > "$W/synth.log" 2>&1 ) || true
		local sn; sn=$( ( cd "$SFR$NET_DIR" && ls -1 ) 2>/dev/null | grep -c . || true)
		[ "$sn" = "$((n_in + 1))" ] \
			&& ok "a newly added unit file is picked up by the glob ($n_in -> $sn), which a hardcoded list would have dropped" \
			|| bad "a newly added unit file was NOT installed ($n_in -> $sn)"
		grep -q "installed $sn/$sn networkd units" "$W/synth.log" \
			&& ok "the count-in == count-out assertion reported $sn/$sn" || bad "the count assertion did not report $sn/$sn"

		# MUST FAIL: an EMPTY unit directory must be loud, not silently fine.
		local ER="$W/emptyrepo"; mkdir -p "$ER/assets/etc.systemd.network"
		cp -a "$REPO/assets/etc.udev.rules.d.10-local.rules" "$ER/assets/"
		cp -a "$REPO/assets/etc.default.grub.d" "$ER/assets/"
		cp -a "$REPO/assets/id_ed25519.pub" "$ER/assets/"
		local EFR="$W/emptyroot"; mkdir -p "$EFR"
		if ( pass=0; fail=0; PATH="$W/guard:$PATH" REPO="$ER" ROOT="$EFR" do_install > "$W/empty.log" 2>&1 ); then
			bad "an EMPTY assets/etc.systemd.network/ was staged silently as a success"
		else
			grep -q 'no networkd units found' "$W/empty.log" \
				&& ok "an EMPTY assets/etc.systemd.network/ fails loudly and by name" \
				|| bad "the empty-unit-set failure was not reported clearly"
		fi
	else
		inf "no repo visible -- the glob-discovery tests are skipped"
	fi

	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- dispatch
while [ $# -gt 0 ]; do
	case "$1" in
	run|install|verify|fingerprint|selftest) MODE="$1" ;;
	-r|--root) ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root needs a directory"; shift ;;
	--repo)    REPO="${2:-}"; [ -n "$REPO" ] || die "--repo needs a directory"; shift ;;
	-h|--help) usage; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done
ROOT="${ROOT%/}"
REPO="${REPO%/}"

case "$MODE" in
run)         do_run ;;
install)     do_install ;;
verify)      do_verify ;;
fingerprint) do_fingerprint ;;
selftest)    do_selftest ;;
esac
