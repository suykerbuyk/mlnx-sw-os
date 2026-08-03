#!/bin/bash
# S4 stage -- R4 boot policy: the modules-present assertion plus the four-rung
# recovery ladder, and the GRUB boot-policy drop-in that the last rung uses.
#
# 🔴 READ THIS BEFORE CHANGING ANYTHING HERE.
#
# The file name says "grub-fallback" for historical reasons and the name is a
# trap. **A GRUB fallback policy does not mitigate R4 and cannot.** GRUB's
# fallback machinery -- fallback=, next_entry, prev_saved_entry -- reacts only
# to a menu entry whose kernel LOAD fails. R4 is a kernel that boots perfectly
# and merely has no mlxsw modules; to GRUB that is a success, so GRUB never
# sees anything to react to. That claim stood in three places and survived
# three review passes before the mechanism was checked against the failure.
#
# What this stage actually installs is a USERSPACE ladder. GRUB is demoted to
# honouring a one-shot that userspace arms, and appears only at rung 3:
#
#   1. DETECT        mlxsw-modules-present.service asserts that
#                    /lib/modules/$(uname -r)/updates/dkms/mlxsw*.ko* is
#                    non-empty. This is the ONLY thing that detects R4.
#   2. REBUILD       `dkms autoinstall` + `modprobe`. The running kernel is
#                    fine, only its modules are missing, and a THICK image
#                    carries headers and toolchain -- so the data plane comes
#                    back with NO bootloader involvement and no reboot.
#   3. FALL BACK     only if rung 2 fails: arm a `grub-reboot` one-shot to the
#                    last-known-good kernel and reboot once.
#   4. GIVE UP LOUDLY  nothing to fall back to, or the arming failed: log
#                    loudly, FAIL THE UNIT, stay reachable on the management
#                    plane. NEVER refuse to boot.
#
# 🔴 The image never depends on this ladder. Every released artifact ships with
# mlxsw modules built for its own kernel; this stage REFUSES to run if it
# cannot find such a kernel to seed last-known-good with. The ladder is
# strictly post-upgrade recovery, never what makes an image work.
#
# Files this stage installs into the target:
#
#   /etc/default/grub.d/25_switch-boot-policy.cfg   GRUB_DEFAULT/TIMEOUT/STYLE
#   /etc/default/grub.d/15_timeout.cfg              DELETED (it forces timeout=0)
#   /usr/local/sbin/mlxsw-boot-policy               the ladder
#   /etc/systemd/system/mlxsw-modules-present.service  rung 1 at every boot
#   /etc/kernel/postinst.d/zz-mlxsw-modules-present    rung 1 at apt time
#   /var/lib/mlxsw-fallback/last-known-good         state, seeded HERE
#
# Runs inside the guest as root (the vm.sh convention is
# `ssh_vm 'sudo bash -s' < script`, so this file must be self-contained), or
# against a staged root tree with --root DIR, which is also how `selftest`
# exercises it with no VM at all.
#
# Usage: stage-grub-fallback.sh [install|selftest|emit-helper|show] [options]
set -euo pipefail

# ---------------------------------------------------------------- constants
DROPIN_NAME="25_switch-boot-policy.cfg"
DROPIN_DIR="/etc/default/grub.d"
STALE_TIMEOUT_DROPIN="$DROPIN_DIR/15_timeout.cfg"
STATE_DIR="/var/lib/mlxsw-fallback"
STATE_FILE="$STATE_DIR/last-known-good"
HELPER_PATH="/usr/local/sbin/mlxsw-boot-policy"
UNIT_NAME="mlxsw-modules-present.service"
UNIT_DIR="/etc/systemd/system"
HOOK_PATH="/etc/kernel/postinst.d/zz-mlxsw-modules-present"
GRUBENV="/boot/grub/grubenv"
GRUBCFG="/boot/grub/grub.cfg"

# ROOT is a PREFIX, never an identity. Empty means "this running system".
ROOT="${ROOT:-}"
MODE="install"

# Resolve the repo only when this file is on disk. Piped over ssh as
# `bash -s`, BASH_SOURCE is not a readable path and the embedded copy of the
# drop-in is used instead.
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
Usage: stage-grub-fallback.sh [MODE] [options]

Modes:
  install        install the boot policy, the ladder, the unit, the kernel
                 hook, and seed /var/lib/mlxsw-fallback/last-known-good
                 (default)
  selftest       offline proof, no VM and no root: emit the ladder helper,
                 exercise the modules-present assertion against generated
                 module trees that must PASS and against trees that must
                 FAIL, and stage a full install into a scratch root
  emit-helper [PATH]
                 write the ladder helper to PATH (default: stdout)
  show           print the GRUB drop-in that would be installed

Options:
  -r, --root DIR   install into DIR instead of /, and skip everything that
                   only means something on a running system (update-grub,
                   grubenv, daemon-reload). Also settable as ROOT=DIR.
  -h, --help
USAGE
}

# ---------------------------------------------------------------- the drop-in
# EMBEDDED COPY. assets/etc.default.grub.d/25_switch-boot-policy.cfg is the
# reviewable original and wins whenever this script can see the repo; this copy
# exists only so the stage still works when the script is piped over ssh with
# no repo in the guest. check_dropin_drift() proves the two are identical.
embedded_dropin() {
	cat <<'DROPIN'
# 25_switch-boot-policy.cfg -- boot policy for the switch image.
# Installs to /etc/default/grub.d/25_switch-boot-policy.cfg
#
# grub-mkconfig sources /etc/default/grub first, then loops over
# ${sysconfdir}/default/grub.d/*.cfg (grub-mkconfig:163-167). These are plain
# shell fragments: last assignment wins, per variable.
#
# NAMING. Glob order is LEXICAL, not numeric, so the prefix is ALWAYS two
# digits -- a "100_" file would sort BEFORE "20_". The prefix must also be
# greater than 15 or the base image's own drop-ins win.
#
# 🔴 THIS FILE OWNS EXACTLY THREE VARIABLES:
#
#     GRUB_DEFAULT   GRUB_TIMEOUT   GRUB_TIMEOUT_STYLE
#
# and must never write any other. THREE variables belong to
# 20_switch-cmdline.cfg: the kernel command line, the combined console terminal
# variable, and the serial-port command. Their names deliberately do not appear
# anywhere in this file, so a plain grep can prove the split.
#
# The two variable sets are DISJOINT, and that is the whole reason neither file
# can clobber the other in any source order -- the "lexical ordering dependency"
# between the two drop-ins recorded in earlier drafts does not exist. It is an
# invariant, though, not a law of nature, and one of the sibling's three
# variables shows exactly what breaking it would cost:
#
#   * the terminal variable has EXPANSION COUPLING -- grub-mkconfig:179-181
#     expands it into the input and output variables AFTER the drop-in loop
#     finishes, so it wins at any prefix regardless of ordering.
#   * the serial-port command has NO such coupling. It is plain
#     last-assignment-wins, so a 25_-prefixed file that set it WOULD silently
#     clobber the 20_ file and drop the console back to a bare 9600-baud serial
#     against a kernel console at 115200. That one variable is the single place
#     where the ordering dependency is real, which is precisely why this file
#     does not go near it.
#
# Plain assignment is correct for the three variables below for the same
# reason: they are scalars this file is the sole authority for, not lists that
# must be appended to.
#
# ⚠ ASSUMPTION, stated rather than assumed: no drop-in shipped by the base
# image sorts after this one. The base's /etc/default/grub.d/ has only ever
# been enumerated as far as 10_cloud.cfg and 15_timeout.cfg, and nothing above
# prefix 15_ was ever looked for. If a future base ships, say, 30_something.cfg
# that sets GRUB_TIMEOUT, it wins and this file loses SILENTLY. The defence is
# not the prefix -- it is that scripts/stage-grub-fallback.sh asserts the
# GENERATED /boot/grub/grub.cfg, which is the only artifact that shows who
# actually won.
#
# 🔴 THIS FILE IS NOT AN R4 MITIGATION. GRUB's fallback machinery reacts only
# to a menu entry whose kernel LOAD fails; R4 is a kernel that boots perfectly
# and merely has no mlxsw modules, which GRUB reads as a success. Detection is
# userspace -- mlxsw-modules-present.service. GRUB's only job is to honour the
# one-shot that /usr/local/sbin/mlxsw-boot-policy arms with grub-reboot.

# The newest kernel, every time. Deliberate, and it is the reason the recovery
# ladder exists rather than a bootloader policy:
#
#   * A switch that upgraded successfully must run the kernel it upgraded to.
#     Pinning an older default would leave a fleet quietly a kernel behind.
#   * GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true CANNOT be used here.
#     `savedefault` stores ${chosen} -- a bare entry TITLE with no submenu path
#     (00_header:108-118) -- and the next boot's top-level `set default`
#     (00_header:37,85) cannot resolve a title that exists only inside the
#     "Advanced options for Debian GNU/Linux" submenu. Previous kernels live
#     ONLY in that submenu, so the saved default silently degrades to entry 0.
#   * grub-reboot needs neither GRUB_DEFAULT=saved nor GRUB_DISABLE_SUBMENU:
#     00_header emits the `next_entry` block unconditionally, and grub-reboot
#     addresses a submenu entry as `Submenu id>entry id`. So the fallback
#     mechanism works with the stock menu shape and stock boot UX intact.
GRUB_DEFAULT=0

# 🔴 The base image ships /etc/default/grub.d/15_timeout.cfg with
# GRUB_TIMEOUT=0, which overrides the GRUB_TIMEOUT=5 in /etc/default/grub. A
# timeout of 0 displays NO MENU AT ALL, so no human can select anything.
#
# scripts/stage-grub-fallback.sh DELETES 15_timeout.cfg rather than shadowing
# it from here. Two files disagreeing about one variable, with the winner
# decided by filename sort, is a second competing authority -- an operator who
# reads 15_timeout.cfg sees 0 and believes it.
#
# 5 seconds, by operator ruling. Switches boot rarely; the retired serial-console
# patch used 2, which is too short for a human to react to
# on a serial line at 115200 in a cold rack. This value governs HUMAN recovery
# only -- the grub-reboot one-shot is honoured at any timeout, including 0.
GRUB_TIMEOUT=5

# Mandatory and explicit. With `hidden` or `countdown` the menu is NOT
# DISPLAYED whatever GRUB_TIMEOUT says (00_header:325-347), which would make
# the value above purely decorative. Cloud images commonly ship a non-menu
# style, so relying on the default is not safe.
#
# ⚠ A displayed menu is still unsteerable without serial INPUT. The base image
# sets only the terminal OUTPUT variable; the combined terminal variable that
# grub-mkconfig:179-181 expands into BOTH input and output is owned by
# 20_switch-cmdline.cfg. Without it this menu renders on the serial console and
# cannot be driven from it.
GRUB_TIMEOUT_STYLE=menu
DROPIN
}

repo_dropin() { [ -n "$HERE" ] && printf '%s/../assets/etc.default.grub.d/%s' "$HERE" "$DROPIN_NAME"; }

# The installed bytes: the repo asset when visible, the embedded copy otherwise.
dropin_source() {
	local r; r="$(repo_dropin)"
	if [ -n "$r" ] && [ -r "$r" ]; then cat "$r"; else embedded_dropin; fi
}

check_dropin_drift() { # 0 = identical or no repo copy to compare against
	local r; r="$(repo_dropin)"
	[ -n "$r" ] && [ -r "$r" ] || { inf "no repo copy of $DROPIN_NAME visible; using the embedded copy"; return 0; }
	if diff -u <(embedded_dropin) "$r" >/dev/null; then
		ok "embedded drop-in is byte-identical to $DROPIN_NAME in assets/"
		return 0
	fi
	bad "embedded drop-in has DRIFTED from assets/etc.default.grub.d/$DROPIN_NAME"
	inf "the repo copy is authoritative and is what gets installed here, but a"
	inf "run piped over ssh has no repo and would install the stale embedded copy"
	diff -u <(embedded_dropin) "$r" | sed 's/^/       /' || true
	return 1
}

# ---------------------------------------------------------------- the ladder
# Written out rather than shipped as a separate repo file so that this stage
# stays self-contained when piped over ssh. `selftest` emits it and then tests
# THE EMITTED ARTIFACT, so what is proven offline is the same text the image
# receives -- not a second copy of the logic.
emit_helper() {
	cat <<'HELPER'
#!/bin/bash
# mlxsw-boot-policy -- R4 detection and the four-rung recovery ladder.
#
# Installed by scripts/stage-grub-fallback.sh. R4 is a kernel that boots fine
# and has no mlxsw modules: apt exits 0, nothing warns, and the damage shows up
# at the next boot as a switch with no data plane.
#
#   check [KVER]   rung 1 only. Pure assertion, no side effects, no writes.
#                  exit 0 = modules present.  exit 1 = R4 state.
#   run            the full ladder. This is what the systemd unit runs.
#   arm KVER       arm the one-shot for KVER without running the ladder
#                  (recovery tool; prints the resolved menu entry).
#   resolve KVER   print the grub menu entry KVER would be addressed by.
#                  Read-only; honours ROOT, so it can be checked offline.
#   status         print what the policy knows.
#
# Environment:
#   ROOT=DIR   treat DIR as the filesystem root. A PREFIX, never an identity.
#              Makes `check` runnable against a module tree on the build host
#              with no VM. IMPLIES MLXSW_DRY_RUN=1 -- a staged tree is not a
#              running system and must never be rebuilt into or rebooted.
#   KVER=...   the kernel a module tree is built against. `uname -r` is the
#              default and is correct ONLY for that. Nothing here branches on
#              uname -r for IDENTITY -- identity comes from /etc/os-release.
#   MLXSW_DRY_RUN=1     walk every rung and report what each WOULD do, without
#                       running dkms, writing grubenv or rebooting. This is how
#                       rungs 2-4 are exercised with no VM, and it is also the
#                       safe way to ask a live switch what it would do. It
#                       suppresses REMEDIATION only: a dry run that finds the
#                       modules present still records last-known-good, because
#                       that record is simply true.
#   MLXSW_NO_REBOOT=1   arm the one-shot for real, but do not reboot.
#
# Deliberately not `set -e`: every rung must be reached and reported even when
# the rung before it failed.
set -uo pipefail

ROOT="${ROOT:-}"
KVER="${KVER:-$(uname -r)}"
DRY="${MLXSW_DRY_RUN:-0}"
# A staged tree is never a running system: rebuilding into it or rebooting
# because of it would act on the WRONG machine -- the build host.
[ -n "$ROOT" ] && DRY=1

STATE_DIR="$ROOT/var/lib/mlxsw-fallback"
STATE_FILE="$STATE_DIR/last-known-good"
LOCK="$STATE_DIR/.lock"
GRUBENV="$ROOT/boot/grub/grubenv"
GRUBCFG="$ROOT/boot/grub/grub.cfg"
TAG="mlxsw-boot-policy"

log()  { printf '%s: %s\n' "$TAG" "$*" >&2; command -v logger >/dev/null 2>&1 && logger -t "$TAG" -p daemon.notice -- "$*" || true; }
loud() { printf '%s: %s\n' "$TAG" "$*" >&2; command -v logger >/dev/null 2>&1 && logger -t "$TAG" -p daemon.crit   -- "$*" || true; }

moddir()  { printf '%s/lib/modules/%s/updates/dkms' "$ROOT" "$1"; }
treedir() { printf '%s/lib/modules/%s' "$ROOT" "$1"; }

# ---------------------------------------------------------------- rung 1
# The assertion. ⚠ THE GLOB IS 'mlxsw*.ko*', NEVER 'mlxsw*.ko': trixie builds
# with module compression and installs mlxsw_spectrum.ko.XZ, while bookworm
# ships plain .ko. A '*.ko' glob reports the modules missing while they are
# present and loaded -- the worst possible answer, because it would send a
# healthy switch down the ladder. Same idiom as
# scripts/mlxsw-premise-audit.sh:93.
modules_present() { # $1 = kernel version
	local d; d="$(moddir "$1")"
	[ -d "$d" ] || return 1
	find "$d" -maxdepth 1 -name 'mlxsw*.ko*' -print -quit 2>/dev/null | grep -q .
}

# Informational only: if mlxsw ever ships in-tree, the DKMS directory is empty
# and the assertion above is a false alarm. Say so instead of acting on it.
modules_elsewhere() { # $1 = kernel version
	local d; d="$(treedir "$1")"
	[ -d "$d" ] || return 1
	find "$d" -path "$(moddir "$1")" -prune -o -name 'mlxsw*.ko*' -print -quit 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------- state
# Format, owned by this stage. Line-oriented key=value, ASCII, one authority:
# the KERNEL= line. READ WITH grep, NEVER SOURCED -- a state file that is
# sourced is a state file that can execute.
read_good() {
	[ -r "$STATE_FILE" ] || return 1
	local v
	v="$(grep -m1 '^KERNEL=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-)"
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

write_good() { # $1 = kernel version, $2 = provenance
	mkdir -p "$STATE_DIR" || return 1
	local t="$STATE_FILE.tmp.$$"
	{
		printf '# mlxsw last-known-good kernel. Written by %s -- do not hand-edit.\n' "$TAG"
		printf '# KERNEL is the only authoritative line; everything else is provenance.\n'
		printf '# This file is READ, never SOURCED.\n'
		printf 'KERNEL=%s\n' "$1"
		printf 'UPDATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
		printf 'SOURCE=%s\n' "$2"
	} > "$t" || return 1
	mv -f "$t" "$STATE_FILE"
}

# ---------------------------------------------------------------- rung 3 bits
# ⚠ 00_header:46 guards `load_env` behind [ -s $prefix/grubenv ]. A missing or
# ZERO-LENGTH grubenv makes the one-shot a SILENT no-op: grub-reboot appears to
# succeed, nothing reads the variable, and the switch reboots straight back
# into the broken kernel. Create it rather than assume it.
ensure_grubenv() {
	[ -s "$GRUBENV" ] && return 0
	command -v grub-editenv >/dev/null 2>&1 || { loud "no grub-editenv; cannot create $GRUBENV"; return 1; }
	mkdir -p "$(dirname "$GRUBENV")" 2>/dev/null || true
	grub-editenv "$GRUBENV" create >/dev/null 2>&1 || { loud "grub-editenv create failed on $GRUBENV"; return 1; }
	[ -s "$GRUBENV" ]
}

# Resolve the menu entry for a kernel from the GENERATED grub.cfg. Never
# predicted: $menuentry_id_option values carry a filesystem UUID and the
# submenu path, and both are generated. A submenu entry is addressed as
# `submenu id>entry id` -- see grub-reboot(8) -- which is exactly why the
# one-shot can reach the previous kernel and GRUB_SAVEDEFAULT cannot.
resolve_entry() { # $1 = kernel version
	[ -r "$GRUBCFG" ] || return 1
	# Quote-agnostic on purpose: whatever character follows the token is taken
	# as the quote and matched. Written with index/substr rather than a regex
	# so it carries no quote literals of its own -- this runs under mawk on
	# Debian, not gawk, and an escaped-quote regex is where that difference
	# bites.
	awk -v k="$1" '
		function idof(line,   p, s, q) {
			p = index(line, "$menuentry_id_option")
			if (p == 0) return ""
			s = substr(line, p + 20)
			sub(/^[[:space:]]+/, "", s)
			q = substr(s, 1, 1)
			s = substr(s, 2)
			p = index(s, q)
			if (p == 0) return ""
			return substr(s, 1, p - 1)
		}
		/^[[:space:]]*submenu[[:space:]]/ { sm = idof($0); next }
		/^[[:space:]]*menuentry[[:space:]]/ {
			id = idof($0)
			if (id == "") next
			# Never fall back into a recovery entry: single-user mode on a
			# headless switch in a rack is indistinguishable from a hang.
			if (id ~ /recovery/) next
			if (index(id, k) == 0) next
			if (sm != "") print sm ">" id; else print id
			exit
		}
	' "$GRUBCFG" | grep .
}

# M4 corollary: GRUB clears next_entry by writing grubenv from inside GRUB
# (00_header:78-84). If that write ever fails the one-shot becomes PERMANENT --
# every boot bounces to the fallback kernel forever. So a verified boot clears
# it defensively rather than trusting GRUB to have done so.
clear_oneshot() {
	[ "$DRY" = 1 ] && return 0
	command -v grub-editenv >/dev/null 2>&1 || return 0
	[ -s "$GRUBENV" ] || return 0
	grub-editenv "$GRUBENV" list 2>/dev/null | grep -q '^next_entry=' || return 0
	log "clearing a stale next_entry from $GRUBENV"
	grub-editenv "$GRUBENV" unset next_entry >/dev/null 2>&1 || true
}

arm_oneshot() { # $1 = target kernel version
	local target="$1" entry
	if [ "$DRY" = 1 ]; then
		[ -s "$GRUBENV" ] || loud "DRY RUN: $GRUBENV is missing or empty -- would create it first, because 00_header:46 guards load_env behind [ -s ] and the one-shot would otherwise no-op silently"
		entry="$(resolve_entry "$target")" || { loud "DRY RUN: no menu entry in $GRUBCFG matches kernel $target"; return 1; }
		loud "DRY RUN: would run: grub-reboot '$entry'"
		return 0
	fi
	command -v grub-reboot >/dev/null 2>&1 || { loud "grub-reboot is not installed; cannot arm a fallback"; return 1; }
	ensure_grubenv || return 1
	entry="$(resolve_entry "$target")" || { loud "no menu entry in $GRUBCFG matches kernel $target"; return 1; }
	log "arming one-shot boot to: $entry"
	grub-reboot "$entry" >/dev/null 2>&1 || { loud "grub-reboot failed for entry: $entry"; return 1; }
	# Read it back. ⚠ UNRESOLVED: whether the UEFI boot path resolves GRUB's
	# $prefix to this same /boot/grub/grubenv is NOT settled -- the build VM is
	# BIOS-only, so it cannot be settled here. If the read-back fails, the
	# arming is not trustworthy and the ladder degrades to rung 4 instead of
	# rebooting into an unknown state.
	grub-editenv "$GRUBENV" list 2>/dev/null | grep -q '^next_entry=' || {
		loud "armed, but next_entry is not readable back from $GRUBENV -- not trusting it"
		return 1
	}
	return 0
}

# ---------------------------------------------------------------- the ladder
do_run() {
	# One instance at a time. flock on a real file, NEVER pgrep -f / pkill -f:
	# an -f pattern matches the pattern's own shell, so the check would find
	# itself and the kill would kill itself.
	#
	# The fd is opened separately from the lock attempt on purpose. If `exec
	# 9>` fails the fd does not exist, and `flock -n 9` then fails with EBADF
	# -- indistinguishable, to a naive `flock || return 0`, from "someone else
	# holds the lock". That would skip the entire ladder silently, which is the
	# exact defect this stage exists to delete. No fd means no locking, and the
	# ladder still runs.
	#
	# ⚠ The brace group is load-bearing. `exec 9>"$LOCK" 2>/dev/null` is exec
	# with redirections ONLY, so BOTH redirections apply to the shell
	# PERMANENTLY -- stderr would be sent to /dev/null for the rest of the run
	# and every rung, including rung 4's "the switch has no data plane", would
	# be silent. Scoping the 2>/dev/null to a group keeps fd 9 and gives stderr
	# back.
	mkdir -p "$STATE_DIR" 2>/dev/null || true
	if { exec 9>"$LOCK"; } 2>/dev/null; then
		if command -v flock >/dev/null 2>&1; then
			flock -n 9 || { log "another run already holds $LOCK; nothing to do"; return 0; }
		fi
	else
		log "could not open $LOCK for locking; continuing unlocked"
	fi

	# ---- rung 1: detect
	if modules_present "$KVER"; then
		log "mlxsw modules present for $KVER"
		write_good "$KVER" verified-boot || loud "could not update $STATE_FILE"
		rm -f "$STATE_DIR/armed-$KVER" 2>/dev/null || true
		clear_oneshot
		return 0
	fi
	loud "R4: NO mlxsw modules for the running kernel $KVER -- the data plane is down"
	if modules_elsewhere "$KVER"; then
		loud "mlxsw modules exist elsewhere under $(treedir "$KVER") but not in updates/dkms -- driver may have gone in-tree; investigate"
	fi
	[ "$DRY" = 1 ] && loud "DRY RUN: rungs 2-4 will be walked and reported, nothing will be executed"

	# ---- rung 2: rebuild in place. No bootloader involved: the running kernel
	# is fine and a THICK image has headers and toolchain resident. ~1m47s on
	# the fleet's Celeron at -j2, which is why the unit's TimeoutStartSec is
	# generous and why nothing is ordered before this unit.
	if [ "$DRY" = 1 ]; then
		loud "rung 2 DRY RUN: would run: dkms autoinstall -k $KVER, then depmod and modprobe mlxsw_spectrum"
	elif command -v dkms >/dev/null 2>&1; then
		loud "rung 2: rebuilding with dkms autoinstall for $KVER"
		if command -v timeout >/dev/null 2>&1; then
			timeout 900 dkms autoinstall -k "$KVER" || loud "dkms autoinstall reported failure"
		else
			dkms autoinstall -k "$KVER" || loud "dkms autoinstall reported failure"
		fi
		command -v depmod >/dev/null 2>&1 && depmod -a "$KVER" >/dev/null 2>&1
		if modules_present "$KVER"; then
			modprobe mlxsw_spectrum 2>/dev/null || loud "modules rebuilt but modprobe mlxsw_spectrum failed (expected where there is no Spectrum ASIC)"
			loud "rung 2 SUCCEEDED: mlxsw modules rebuilt for $KVER, no reboot needed"
			write_good "$KVER" rebuilt-in-place || loud "could not update $STATE_FILE"
			rm -f "$STATE_DIR/armed-$KVER" 2>/dev/null || true
			clear_oneshot
			return 0
		fi
		loud "rung 2 FAILED: still no mlxsw modules for $KVER after dkms autoinstall"
	else
		loud "rung 2 SKIPPED: dkms is not installed -- this image is not THICK"
	fi

	# ---- rung 3: fall back, once
	local good
	good="$(read_good)" || good=""
	if [ -z "$good" ]; then
		loud "rung 3 SKIPPED: no last-known-good recorded in $STATE_FILE"
	elif [ "$good" = "$KVER" ]; then
		loud "rung 3 SKIPPED: last-known-good IS the running kernel $KVER -- nothing to fall back to (a freshly imaged switch has exactly one kernel)"
	elif ! modules_present "$good"; then
		loud "rung 3 SKIPPED: last-known-good $good has no mlxsw modules either -- rebooting into it would change nothing"
	elif [ -e "$STATE_DIR/armed-$KVER" ]; then
		loud "rung 3 SKIPPED: a fallback was already armed for $KVER and we are running it again -- refusing to loop"
	elif arm_oneshot "$good"; then
		# The stamp is what stops a boot loop: if this same kernel comes up
		# broken again after a fallback, rung 3 refuses to arm a second time
		# and the ladder ends at rung 4 with the box still reachable.
		[ "$DRY" = 1 ] || : > "$STATE_DIR/armed-$KVER" 2>/dev/null || true
		loud "rung 3: falling back to $good on the next boot. REBOOTING."
		if [ "$DRY" = 1 ]; then
			loud "DRY RUN: would reboot now; not rebooting"
			return 1
		fi
		if [ "${MLXSW_NO_REBOOT:-0}" = "1" ]; then
			loud "MLXSW_NO_REBOOT=1: armed but not rebooting"
			return 1
		fi
		# --no-block: this runs inside a systemd unit, and a blocking reboot
		# job would wait on the very transaction it is part of.
		systemctl --no-block reboot 2>/dev/null || reboot
		return 1
	fi

	# ---- rung 4: give up loudly, stay up
	loud "rung 4: NO RECOVERY AVAILABLE for $KVER. The switch has NO DATA PLANE."
	loud "rung 4: the management plane is intentionally left running -- fix with:"
	loud "rung 4:   apt-get install --reinstall linux-headers-amd64 mlxsw-dkms && dkms autoinstall -k $KVER"
	loud "rung 4: NOT refusing to boot. This unit stays failed so it is visible."
	return 1
}

do_check() {
	local k="${1:-$KVER}"
	if modules_present "$k"; then
		printf 'PASS mlxsw modules present: %s\n' "$(moddir "$k")"
		return 0
	fi
	printf 'FAIL no mlxsw*.ko* in %s\n' "$(moddir "$k")" >&2
	return 1
}

do_status() {
	printf 'kernel (uname -r):  %s\n' "$KVER"
	printf 'module dir:         %s\n' "$(moddir "$KVER")"
	printf 'modules present:    %s\n' "$(modules_present "$KVER" && echo yes || echo NO)"
	printf 'last-known-good:    %s\n' "$(read_good || echo '(none recorded)')"
	printf 'grubenv:            %s\n' "$([ -s "$GRUBENV" ] && echo "$GRUBENV" || echo 'MISSING or EMPTY -- a one-shot would silently no-op')"
	if [ -s "$GRUBENV" ] && command -v grub-editenv >/dev/null 2>&1; then
		printf 'next_entry:         %s\n' "$(grub-editenv "$GRUBENV" list 2>/dev/null | grep '^next_entry=' || echo '(not armed)')"
	fi
	# Identity is os-release, never uname -r: trixie's 6.12.100+deb13-amd64 and
	# bookworm's 6.1.0-51-amd64 differ in FORMAT, so a regex against one fails
	# silently on the other.
	if [ -r "$ROOT/etc/os-release" ]; then
		printf 'identity:           %s\n' "$(. "$ROOT/etc/os-release"; printf '%s %s' "${ID:-?}" "${VERSION_CODENAME:-${VERSION_ID:-?}}")"
	fi
}

case "${1:-run}" in
run)     do_run ;;
check)   shift; do_check "${1:-}" ;;
arm)     shift; [ $# -ge 1 ] || { echo "usage: mlxsw-boot-policy arm KVER" >&2; exit 2; }; arm_oneshot "$1" ;;
resolve) shift; [ $# -ge 1 ] || { echo "usage: mlxsw-boot-policy resolve KVER" >&2; exit 2; }; resolve_entry "$1" ;;
status)  do_status ;;
*)       echo "usage: mlxsw-boot-policy {run|check [KVER]|arm KVER|resolve KVER|status}" >&2; exit 2 ;;
esac
HELPER
}

# ---------------------------------------------------------------- the unit
# 🔴 Unit A -- modules-present -- ONLY. It is hardware-INDEPENDENT and PASSES
# in QEMU on a correct image, so it needs no condition and there is no
# allowlist: `systemctl --failed` must be empty unconditionally, and this unit
# failing means the image is broken.
#
# A data-plane check (mlxsw_pci bound, swp* present) is a DIFFERENT unit and is
# deliberately not shipped. If one is ever wanted it must carry
# `ConditionPathExistsGlob=/sys/bus/pci/drivers/mlxsw_pci/0000:*` so that it
# reports SKIPPED where there is no ASIC. A failed Condition* marks a unit
# skipped; a failed Assert* marks it FAILED. Never use Assert* for this.
emit_unit() {
	cat <<'UNIT'
[Unit]
Description=mlxsw modules present for the running kernel (R4 detection and recovery)
Documentation=file:///usr/local/sbin/mlxsw-boot-policy
After=local-fs.target systemd-modules-load.service
# Nothing is ordered AFTER this unit, on purpose. Rung 2 can take ~2 minutes on
# the fleet's Celeron, and the management plane must come up regardless -- the
# whole point of the ladder is that the switch stays reachable while it heals.

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mlxsw-boot-policy run
# Generous: rung 2 is a full DKMS rebuild. The default 90s would kill it at
# roughly the halfway mark and leave the failure looking like a timeout.
TimeoutStartSec=900
# Rung 4 must be visible to a human on the serial console, not only in the
# journal of a switch nobody can reach.
StandardOutput=journal
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
}

# ---------------------------------------------------------------- the hook
# ⚠ TWO run-parts traps, both silent:
#   1. NO DOT in the filename. Debian's run-parts, without --lsbsysinit, skips
#      any name containing a dot -- `zz-mlxsw-modules-present.sh` would never
#      run and nothing would say so.
#   2. MUST EXIT 0. linux-image's postinst calls run-parts --exit-on-error, so
#      a non-zero exit fails the dpkg transaction and leaves the kernel package
#      half-configured. That is the opposite of "keep the box recoverable". The
#      hook WARNS; only the systemd unit is allowed to hold a failed state.
# 'zz-' sorts after 'dkms', which is the ordering requirement.
emit_hook() {
	cat <<'HOOK'
#!/bin/sh
# /etc/kernel/postinst.d/zz-mlxsw-modules-present
#
# Runs at `apt upgrade` time, after /etc/kernel/postinst.d/dkms, so the
# operator learns about R4 while still logged in -- instead of discovering it
# after the next reboot as a switch with no ports.
#
# run-parts passes the NEW kernel's version as $1. That is the tree to check;
# `uname -r` is still the OLD kernel at this point in the transaction.
#
# 🔴 ALWAYS EXITS 0. See the trap notes in scripts/stage-grub-fallback.sh.
set -u
KVER="${1:-}"
[ -n "$KVER" ] || KVER="$(uname -r)"
POLICY=/usr/local/sbin/mlxsw-boot-policy

[ -x "$POLICY" ] || exit 0

if "$POLICY" check "$KVER" >/dev/null 2>&1; then
	exit 0
fi

cat >&2 <<EOF
*******************************************************************************
mlxsw: NO DRIVER MODULES WERE BUILT FOR KERNEL $KVER

This kernel will boot with NO DATA PLANE -- every swp* port will be missing.
apt is exiting 0 anyway; this warning is the only notice you get.

Check, before rebooting:
  dkms status
  apt-get install linux-headers-amd64      # the METAPACKAGE, never -\$(uname -r)
  dkms autoinstall -k $KVER

mlxsw-modules-present.service will retry the rebuild at the next boot and will
fall back to the last known-good kernel if it cannot.
*******************************************************************************
EOF
exit 0
HOOK
}

# ---------------------------------------------------------------- install
# The kernel to seed last-known-good with. NOT discovered on a first successful
# boot: the image ships good, so the shipped kernel IS the known-good one from
# the moment it is written. Prefer the running kernel; otherwise the highest
# version present that actually has modules.
pick_good_kernel() {
	local running="" k best=""
	[ -z "$ROOT" ] && running="$(uname -r)"
	if [ -n "$running" ] && helper_modules_present "$running"; then
		printf '%s' "$running"; return 0
	fi
	for k in $(ls -1 "$(rp /lib/modules)" 2>/dev/null | sort -V); do
		helper_modules_present "$k" && best="$k"
	done
	[ -n "$best" ] || return 1
	printf '%s' "$best"
}

# The same assertion the helper makes, applied from the stage. Kept to one
# expression so there is one glob, not two that can disagree.
helper_modules_present() { # $1 = kernel version
	local d; d="$(rp "/lib/modules/$1/updates/dkms")"
	[ -d "$d" ] || return 1
	find "$d" -maxdepth 1 -name 'mlxsw*.ko*' -print -quit 2>/dev/null | grep -q .
}

do_install() {
	hdr "stage-grub-fallback -- R4 boot policy and recovery ladder"
	if [ -n "$ROOT" ]; then
		[ -d "$ROOT" ] || die "--root $ROOT does not exist"
		inf "staging into ROOT=$ROOT (nothing on this host is touched)"
	else
		[ "$(id -u)" = 0 ] || die "must run as root (or use --root DIR)"
	fi
	if [ -r "$(rp /etc/os-release)" ]; then
		# Identity from os-release. Never from uname -r.
		inf "target identity: $(. "$(rp /etc/os-release)"; printf '%s %s' "${ID:-?}" "${VERSION_CODENAME:-${VERSION_ID:-?}}")"
	fi

	hdr "1. GRUB boot-policy drop-in"
	check_dropin_drift || true          # reported, never fatal: the repo copy wins
	install -d -m 0755 "$(rp "$DROPIN_DIR")"
	dropin_source > "$(rp "$DROPIN_DIR/$DROPIN_NAME")"
	chmod 0644 "$(rp "$DROPIN_DIR/$DROPIN_NAME")"
	ok "installed $DROPIN_DIR/$DROPIN_NAME (GRUB_DEFAULT, GRUB_TIMEOUT, GRUB_TIMEOUT_STYLE)"

	# 🔴 DELETED, not shadowed. Shadowing would leave two files disagreeing
	# about GRUB_TIMEOUT with the winner decided by filename sort -- a second
	# competing authority, and an operator reading 15_timeout.cfg would see 0
	# and believe it.
	if [ -e "$(rp "$STALE_TIMEOUT_DROPIN")" ]; then
		rm -f "$(rp "$STALE_TIMEOUT_DROPIN")"
		ok "deleted $STALE_TIMEOUT_DROPIN (it forced GRUB_TIMEOUT=0: no menu at all)"
	else
		inf "$STALE_TIMEOUT_DROPIN absent already"
	fi
	# 10_cloud.cfg (GRUB_DISABLE_LINUX_UUID=true) is NOT touched here -- it is
	# ruled on by stage-generalize.
	if [ -e "$(rp "$DROPIN_DIR/10_cloud.cfg")" ]; then
		inf "$DROPIN_DIR/10_cloud.cfg left alone (owned by stage-generalize)"
	fi

	hdr "2. the recovery ladder"
	install -d -m 0755 "$(rp "$(dirname "$HELPER_PATH")")"
	emit_helper > "$(rp "$HELPER_PATH")"
	chmod 0755 "$(rp "$HELPER_PATH")"
	if bash -n "$(rp "$HELPER_PATH")" 2>/dev/null; then
		ok "installed $HELPER_PATH (bash -n clean)"
	else
		bad "$HELPER_PATH does not parse -- refusing to continue"
		return 1
	fi

	hdr "3. detection at boot and at apt time"
	install -d -m 0755 "$(rp "$UNIT_DIR")"
	emit_unit > "$(rp "$UNIT_DIR/$UNIT_NAME")"
	chmod 0644 "$(rp "$UNIT_DIR/$UNIT_NAME")"
	# Enable by writing the wants symlink directly rather than shelling out to
	# `systemctl enable`: identical result, works against a staged root, and
	# does not depend on the build host's systemd.
	install -d -m 0755 "$(rp "$UNIT_DIR/multi-user.target.wants")"
	ln -sfn "../$UNIT_NAME" "$(rp "$UNIT_DIR/multi-user.target.wants/$UNIT_NAME")"
	ok "installed and enabled $UNIT_NAME (multi-user.target.wants)"

	install -d -m 0755 "$(rp "$(dirname "$HOOK_PATH")")"
	emit_hook > "$(rp "$HOOK_PATH")"
	chmod 0755 "$(rp "$HOOK_PATH")"
	case "$(basename "$HOOK_PATH")" in
	*.*) bad "hook name contains a dot -- run-parts would silently skip it" ;;
	zz-*) ok "installed $HOOK_PATH (no dot; 'zz-' sorts after 'dkms')" ;;
	*)   bad "hook name does not sort after 'dkms'" ;;
	esac

	hdr "4. last-known-good, seeded at build time"
	local good
	if good="$(pick_good_kernel)"; then
		install -d -m 0755 "$(rp "$STATE_DIR")"
		{
			printf '# mlxsw last-known-good kernel. Written by stage-grub-fallback.sh -- do not hand-edit.\n'
			printf '# KERNEL is the only authoritative line; everything else is provenance.\n'
			printf '# This file is READ, never SOURCED.\n'
			printf 'KERNEL=%s\n' "$good"
			printf 'UPDATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'SOURCE=image-build\n'
		} > "$(rp "$STATE_FILE")"
		chmod 0644 "$(rp "$STATE_FILE")"
		ok "seeded $STATE_FILE with KERNEL=$good"
		inf "a freshly imaged switch has exactly ONE kernel, so this equals the"
		inf "running kernel and rung 3 correctly degrades to rung 4 until the"
		inf "first upgrade adds a second entry to the menu"
	else
		# 🔴 We do not ship broken switch images. An artifact with no mlxsw
		# modules for any kernel it carries is a defective artifact, and this
		# is where that is caught -- offline, at build time.
		bad "NO kernel under $(rp /lib/modules) has mlxsw modules in updates/dkms"
		bad "this image would boot with no data plane -- install mlxsw-dkms first"
		return 1
	fi

	hdr "5. regenerate and assert the GENERATED grub.cfg"
	if [ -n "$ROOT" ]; then
		inf "ROOT is set: skipping update-grub, grubenv and daemon-reload"
		inf "(they describe a running system, not a staged tree)"
	else
		# ⚠ 00_header:46 guards load_env behind [ -s $prefix/grubenv ]. Without
		# a non-empty grubenv the whole one-shot mechanism is a silent no-op.
		if [ -s "$GRUBENV" ]; then
			ok "$GRUBENV exists and is non-empty (load_env will run)"
		elif command -v grub-editenv >/dev/null 2>&1 && grub-editenv "$GRUBENV" create && [ -s "$GRUBENV" ]; then
			ok "created $GRUBENV (was missing or empty -- the one-shot would have no-opped)"
		else
			bad "$GRUBENV is missing or empty and could not be created -- rung 3 cannot work"
		fi

		if command -v update-grub >/dev/null 2>&1; then
			update-grub >/dev/null 2>&1 && ok "update-grub regenerated $GRUBCFG" \
			                            || bad "update-grub failed"
		elif command -v grub-mkconfig >/dev/null 2>&1; then
			grub-mkconfig -o "$GRUBCFG" >/dev/null 2>&1 && ok "grub-mkconfig regenerated $GRUBCFG" \
			                                            || bad "grub-mkconfig failed"
		else
			bad "neither update-grub nor grub-mkconfig is installed"
		fi

		# Assert the GENERATED file, not the input. A future base drop-in that
		# sorts after ours would win silently, and only the output shows it.
		if [ -r "$GRUBCFG" ]; then
			grep -qE '^[[:space:]]*set timeout=5$'            "$GRUBCFG" && ok "grub.cfg: set timeout=5"           || bad "grub.cfg does not set timeout=5 -- something outranks $DROPIN_NAME"
			grep -qE '^[[:space:]]*set timeout_style=menu$'   "$GRUBCFG" && ok "grub.cfg: set timeout_style=menu"  || bad "grub.cfg does not set timeout_style=menu -- the menu would not display"
			grep -qE "^[[:space:]]*set default=\"?0\"?$"      "$GRUBCFG" && ok "grub.cfg: set default=0"            || inf "grub.cfg default is not a literal 0 -- check it is not 'saved'"
			grep -qE '^[[:space:]]*if \[ "\$\{next_entry\}" \]' "$GRUBCFG" && ok "grub.cfg honours next_entry (the one-shot is live)" || bad "grub.cfg has no next_entry block -- grub-reboot would do nothing"
			inf "grub.cfg: $(grep -c '^[[:space:]]*menuentry ' "$GRUBCFG") menuentries, $(grep -c '^[[:space:]]*submenu ' "$GRUBCFG") submenu(s)"
		else
			bad "no $GRUBCFG to assert against"
		fi

		command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

		hdr "6. the assertion, run for real on this system"
		if "$HELPER_PATH" check; then ok "rung 1 assertion passes on the running kernel"
		else bad "rung 1 assertion FAILS on the running kernel -- this image is not shippable"; fi
	fi

	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- selftest
# L3: the assertion must be exercisable with no VM, and it must be PROVEN
# capable of failing. An assertion that cannot fail is worse than none -- it
# reports success forever, including on a switch with no data plane.
#
# What is tested is the EMITTED helper, byte for byte the file the image gets,
# not a second copy of the logic living in this script.
SELFTEST_WORK=""
cleanup_selftest() { [ -n "$SELFTEST_WORK" ] && rm -rf "$SELFTEST_WORK"; }

do_selftest() {
	local W H k
	# The scratch dir is tracked in a FILE-SCOPE variable, not a local: an EXIT
	# trap fires after this function's locals are gone, and under `set -u` a
	# trap referencing a dead local aborts with "unbound variable".
	SELFTEST_WORK="$(mktemp -d)"
	W="$SELFTEST_WORK"
	trap cleanup_selftest EXIT
	H="$W/mlxsw-boot-policy"
	k="6.12.100+deb13-amd64"       # a trixie-shaped version, deliberately not this host's

	hdr "S0  the emitted ladder parses and the drop-in has not drifted"
	emit_helper > "$H"; chmod 0755 "$H"
	bash -n "$H" && ok "emitted helper is bash -n clean" || bad "emitted helper does not parse"
	emit_hook > "$W/hook"
	sh -n "$W/hook" && ok "emitted kernel hook is sh -n clean" || bad "emitted kernel hook does not parse"
	check_dropin_drift || true

	# fixture builder. $1 = name, $2.. = files to create under updates/dkms
	fixture() {
		local name="$1"; shift
		local d="$W/$name/lib/modules/$k/updates/dkms"
		mkdir -p "$d"
		local f; for f in "$@"; do : > "$d/$f"; done
		printf '%s' "$W/$name"
	}

	hdr "S1  MUST PASS -- module trees that are healthy"
	local r
	r="$(fixture trixie mlxsw_core.ko.xz mlxsw_pci.ko.xz mlxsw_i2c.ko.xz mlxsw_spectrum.ko.xz mlxsw_minimal.ko.xz objagg.ko.xz parman.ko.xz)"
	if ROOT="$r" KVER="$k" "$H" check >/dev/null 2>&1; then ok "trixie shape (.ko.xz, 7 modules) -> assertion passes"
	else bad "trixie shape (.ko.xz) -> assertion FAILED; the glob is probably '*.ko' not '*.ko*'"; fi

	r="$(fixture bookworm mlxsw_core.ko mlxsw_pci.ko mlxsw_spectrum.ko)"
	if ROOT="$r" KVER="$k" "$H" check >/dev/null 2>&1; then ok "bookworm shape (plain .ko) -> assertion passes"
	else bad "bookworm shape (plain .ko) -> assertion FAILED"; fi

	hdr "S2  MUST FAIL -- prove the assertion can fail"
	r="$(fixture empty-dkms)"
	if ROOT="$r" KVER="$k" "$H" check >/dev/null 2>&1; then bad "empty updates/dkms -> assertion passed; it cannot fail, which is worse than no assertion"
	else ok "empty updates/dkms -> assertion fails (this IS the reproduced R4 state)"; fi

	r="$(fixture decoy some-other.ko.xz README)"
	if ROOT="$r" KVER="$k" "$H" check >/dev/null 2>&1; then bad "non-mlxsw files -> assertion passed; the glob is not specific enough"
	else ok "non-mlxsw files only -> assertion fails (glob is mlxsw-specific, not 'dir non-empty')"; fi

	mkdir -p "$W/no-dkms/lib/modules/$k/kernel"
	if ROOT="$W/no-dkms" KVER="$k" "$H" check >/dev/null 2>&1; then bad "no updates/dkms dir -> assertion passed"
	else ok "module tree without updates/dkms -> assertion fails"; fi

	mkdir -p "$W/no-tree"
	if ROOT="$W/no-tree" KVER="$k" "$H" check >/dev/null 2>&1; then bad "no module tree at all -> assertion passed"
	else ok "no /lib/modules tree at all -> assertion fails"; fi

	r="$(fixture other-kernel mlxsw_core.ko.xz)"
	if ROOT="$r" KVER="6.12.101+deb13-amd64" "$H" check >/dev/null 2>&1; then bad "modules for a DIFFERENT kernel -> assertion passed; that is exactly R4"
	else ok "modules present but for a different kernel -> assertion fails (R4 itself)"; fi

	hdr "S3  rung 1 in the ladder: record on success, fail closed on absence"
	r="$(fixture ladder-good mlxsw_spectrum.ko.xz)"
	if ROOT="$r" KVER="$k" "$H" run >/dev/null 2>&1; then ok "run on a healthy tree exits 0 and records last-known-good"
	else bad "run on a healthy tree did not exit 0"; fi
	if [ "$(grep -m1 '^KERNEL=' "$r/var/lib/mlxsw-fallback/last-known-good" 2>/dev/null | cut -d= -f2-)" = "$k" ]; then
		ok "run wrote KERNEL=$k to var/lib/mlxsw-fallback/last-known-good"
	else bad "run did not write the state file"; fi
	r="$(fixture ladder-bad)"
	if ROOT="$r" KVER="$k" "$H" run >/dev/null 2>&1; then bad "run on a broken tree exited 0"
	else ok "run on a broken tree exits non-zero and does not touch the bootloader"; fi

	hdr "S4  the ladder walks rungs 2-4 under a dry run"
	# ROOT implies MLXSW_DRY_RUN=1, so every rung is reached and reported and
	# nothing is executed. Without this the only rung ever exercised offline
	# would be rung 1, and rungs 2-4 would ship entirely unrun.
	local out
	# (a) nothing recorded -> rung 3 has nowhere to go, ends at rung 4
	r="$(fixture rung4)"
	out="$(ROOT="$r" KVER="$k" "$H" run 2>&1 || true)"
	case "$out" in *"rung 2 DRY RUN: would run: dkms autoinstall"*) ok "rung 2 reached: reports the in-place rebuild it would run" ;;
	*) bad "rung 2 not reported"; printf '%s\n' "$out" | sed 's/^/       /' ;; esac
	case "$out" in *"rung 3 SKIPPED: no last-known-good"*) ok "rung 3 skipped with no last-known-good recorded" ;;
	*) bad "rung 3 skip not reported" ;; esac
	case "$out" in *"rung 4: NO RECOVERY AVAILABLE"*) ok "rung 4 gives up LOUDLY" ;;
	*) bad "rung 4 not reached" ;; esac
	case "$out" in *"NOT refusing to boot"*) ok "rung 4 states it does not refuse to boot" ;;
	*) bad "rung 4 does not say it stays bootable" ;; esac

	# (b) last-known-good == the running kernel: a freshly imaged switch. There
	#     is exactly one kernel and nothing to fall back to.
	r="$(fixture rung4-self)"
	mkdir -p "$r/var/lib/mlxsw-fallback"
	printf 'KERNEL=%s\n' "$k" > "$r/var/lib/mlxsw-fallback/last-known-good"
	out="$(ROOT="$r" KVER="$k" "$H" run 2>&1 || true)"
	case "$out" in *"last-known-good IS the running kernel"*) ok "rung 3 refuses to fall back to the kernel it is already running" ;;
	*) bad "rung 3 did not detect the single-kernel case" ;; esac

	# (c) a real fallback target: an older kernel that HAS modules, and a menu
	#     that contains it. This is the only path that reaches grub at all.
	r="$W/rung3"
	mkdir -p "$r/lib/modules/$k/updates/dkms" \
	         "$r/lib/modules/6.12.96+deb13-amd64/updates/dkms" \
	         "$r/var/lib/mlxsw-fallback" "$r/boot/grub"
	: > "$r/lib/modules/6.12.96+deb13-amd64/updates/dkms/mlxsw_spectrum.ko.xz"
	printf 'KERNEL=6.12.96+deb13-amd64\n' > "$r/var/lib/mlxsw-fallback/last-known-good"
	cat > "$r/boot/grub/grub.cfg" <<-'CFG'
	menuentry 'Debian GNU/Linux' $menuentry_id_option 'gnulinux-simple-1111' {
	}
	submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-1111' {
		menuentry 'Debian GNU/Linux, with Linux 6.12.96+deb13-amd64' $menuentry_id_option 'gnulinux-6.12.96+deb13-amd64-advanced-1111' {
		}
	}
	CFG
	out="$(ROOT="$r" KVER="$k" "$H" run 2>&1 || true)"
	case "$out" in *"would run: grub-reboot 'gnulinux-advanced-1111>gnulinux-6.12.96+deb13-amd64-advanced-1111'"*)
		ok "rung 3 resolves the previous kernel INSIDE the submenu and would arm it" ;;
	*) bad "rung 3 did not arm the submenu entry"; printf '%s\n' "$out" | sed 's/^/       /' ;; esac
	case "$out" in *"DRY RUN: would reboot now; not rebooting"*) ok "rung 3 stops at the reboot under a dry run" ;;
	*) bad "rung 3 dry run did not stop at the reboot" ;; esac
	[ -e "$r/var/lib/mlxsw-fallback/armed-$k" ] && bad "a dry run wrote the armed stamp" \
	                                            || ok "a dry run leaves no armed stamp behind"
	case "$out" in *"missing or empty -- would create it"*) ok "rung 3 notices an absent grubenv (00_header:46 would no-op the one-shot)" ;;
	*) bad "rung 3 did not check grubenv" ;; esac

	# (d) the fallback target is itself broken -- rebooting into it changes nothing
	rm -f "$r/lib/modules/6.12.96+deb13-amd64/updates/dkms/mlxsw_spectrum.ko.xz"
	out="$(ROOT="$r" KVER="$k" "$H" run 2>&1 || true)"
	case "$out" in *"has no mlxsw modules either"*) ok "rung 3 refuses a last-known-good that is itself broken" ;;
	*) bad "rung 3 armed a fallback to a kernel with no modules" ;; esac

	# (e) the loop guard: a stamp for this kernel means we already fell back once
	: > "$r/lib/modules/6.12.96+deb13-amd64/updates/dkms/mlxsw_spectrum.ko.xz"
	: > "$r/var/lib/mlxsw-fallback/armed-$k"
	out="$(ROOT="$r" KVER="$k" "$H" run 2>&1 || true)"
	case "$out" in *"refusing to loop"*) ok "rung 3 refuses a second fallback for the same kernel (no boot loop)" ;;
	*) bad "rung 3 would arm a second time and could loop" ;; esac

	hdr "S5  a full install into a scratch root"
	local FR="$W/fakeroot"
	mkdir -p "$FR/etc/default/grub.d" "$FR/lib/modules/$k/updates/dkms"
	: > "$FR/lib/modules/$k/updates/dkms/mlxsw_spectrum.ko.xz"
	printf 'GRUB_TIMEOUT=0\n' > "$FR/etc/default/grub.d/15_timeout.cfg"
	printf 'GRUB_DISABLE_LINUX_UUID=true\n' > "$FR/etc/default/grub.d/10_cloud.cfg"
	if ( ROOT="$FR" do_install >"$W/install.log" 2>&1 ); then ok "install --root exits 0"
	else bad "install --root failed"; sed 's/^/       /' "$W/install.log"; fi
	[ -f "$FR$DROPIN_DIR/$DROPIN_NAME" ]                && ok "installed $DROPIN_DIR/$DROPIN_NAME"          || bad "drop-in missing"
	[ ! -e "$FR$STALE_TIMEOUT_DROPIN" ]                 && ok "deleted 15_timeout.cfg (not shadowed)"        || bad "15_timeout.cfg survived"
	[ -f "$FR$DROPIN_DIR/10_cloud.cfg" ]                && ok "10_cloud.cfg untouched (stage-generalize owns it)" || bad "10_cloud.cfg was removed"
	[ -x "$FR$HELPER_PATH" ]                            && ok "installed $HELPER_PATH executable"            || bad "helper missing or not executable"
	[ -f "$FR$UNIT_DIR/$UNIT_NAME" ]                    && ok "installed $UNIT_NAME"                         || bad "unit missing"
	[ -L "$FR$UNIT_DIR/multi-user.target.wants/$UNIT_NAME" ] && ok "unit enabled via multi-user.target.wants" || bad "unit not enabled"
	[ -x "$FR$HOOK_PATH" ]                              && ok "installed $HOOK_PATH executable"              || bad "kernel hook missing"
	[ "$(grep -m1 '^KERNEL=' "$FR$STATE_FILE" 2>/dev/null | cut -d= -f2-)" = "$k" ] \
		&& ok "seeded $STATE_FILE with the shipped kernel $k"  || bad "last-known-good not seeded"
	# The disjointness invariant, checked as a plain grep: none of the sibling's
	# three variable NAMES may appear in this file at all, not even in a
	# comment, so the check cannot be fooled by prose. The serial-port command
	# is the sharp one -- it has no expansion coupling, so a 25_ file that set
	# it really would clobber the 20_ file on lexical order.
	if grep -qE 'GRUB_CMDLINE_LINUX|GRUB_TERMINAL|GRUB_SERIAL_COMMAND' "$FR$DROPIN_DIR/$DROPIN_NAME"; then
		bad "the drop-in names a variable owned by 20_switch-cmdline.cfg"
	else
		ok "the drop-in names none of the sibling's three variables (cmdline, terminal, serial command)"
	fi
	if [ "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GRUB_' "$FR$DROPIN_DIR/$DROPIN_NAME")" = 3 ]; then
		ok "the drop-in assigns exactly 3 variables"
	else
		bad "the drop-in assigns $(grep -cE '^[[:space:]]*(export[[:space:]]+)?GRUB_' "$FR$DROPIN_DIR/$DROPIN_NAME") variables, expected exactly 3"
	fi

	hdr "S6  submenu addressing, against a generated-grub.cfg shape"
	# The load-bearing half of rung 3. GRUB_SAVEDEFAULT cannot reach these
	# entries at all; grub-reboot addresses them as `submenu id>entry id`. The
	# ids are read from the GENERATED file, never predicted.
	local G="$W/menu"; mkdir -p "$G/boot/grub"
	cat > "$G/boot/grub/grub.cfg" <<-'CFG'
	menuentry 'Debian GNU/Linux' --class debian --class os $menuentry_id_option 'gnulinux-simple-1111-2222' {
		linux /boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111
	}
	submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-1111-2222' {
		menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64' --class debian $menuentry_id_option 'gnulinux-6.12.100+deb13-amd64-advanced-1111-2222' {
			linux /boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111
		}
		menuentry 'Debian GNU/Linux, with Linux 6.12.100+deb13-amd64 (recovery mode)' --class debian $menuentry_id_option 'gnulinux-6.12.100+deb13-amd64-recovery-1111-2222' {
			linux /boot/vmlinuz-6.12.100+deb13-amd64 root=PARTUUID=1111 single
		}
		menuentry 'Debian GNU/Linux, with Linux 6.12.96+deb13-amd64' --class debian $menuentry_id_option 'gnulinux-6.12.96+deb13-amd64-advanced-1111-2222' {
			linux /boot/vmlinuz-6.12.96+deb13-amd64 root=PARTUUID=1111
		}
		menuentry 'Debian GNU/Linux, with Linux 6.12.96+deb13-amd64 (recovery mode)' --class debian $menuentry_id_option 'gnulinux-6.12.96+deb13-amd64-recovery-1111-2222' {
			linux /boot/vmlinuz-6.12.96+deb13-amd64 root=PARTUUID=1111 single
		}
	}
	CFG
	local got want
	want='gnulinux-advanced-1111-2222>gnulinux-6.12.96+deb13-amd64-advanced-1111-2222'
	got="$(ROOT="$G" "$H" resolve '6.12.96+deb13-amd64' 2>/dev/null || true)"
	[ "$got" = "$want" ] && ok "previous kernel resolves to a submenu entry: $got" \
	                     || bad "submenu addressing wrong: got '$got' want '$want'"
	got="$(ROOT="$G" "$H" resolve '6.12.100+deb13-amd64' 2>/dev/null || true)"
	case "$got" in
	*'>gnulinux-6.12.100+deb13-amd64-advanced-'*) ok "newest kernel resolves to its advanced entry, not the simple one" ;;
	*) bad "newest kernel resolved to '$got'" ;;
	esac
	case "$got" in
	*recovery*) bad "resolved to a RECOVERY entry -- single-user on a headless switch is a hang" ;;
	*)          ok "recovery entries are never selected" ;;
	esac
	if ROOT="$G" "$H" resolve '6.11.0-not-in-menu' >/dev/null 2>&1; then
		bad "resolved a kernel that is not in the menu"
	else
		ok "a kernel absent from the menu does not resolve (rung 3 degrades instead of arming garbage)"
	fi

	hdr "S7  an image with no mlxsw modules is REFUSED at staging"
	local BR="$W/badroot"; mkdir -p "$BR/lib/modules/$k/kernel"
	if ( ROOT="$BR" do_install >/dev/null 2>&1 ); then bad "staged an image with no mlxsw modules for any kernel"
	else ok "refused to stage an image with no mlxsw modules (we do not ship broken images)"; fi

	printf '\n%s\n' "----------------------------------------"
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- dispatch
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	install|selftest|emit-helper|show) MODE="$1" ;;
	-r|--root) ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root needs a directory"; shift ;;
	-h|--help) usage; exit 0 ;;
	*) ARGS+=("$1") ;;
	esac
	shift
done
ROOT="${ROOT%/}"

case "$MODE" in
install)     do_install ;;
selftest)    do_selftest ;;
emit-helper) if [ "${#ARGS[@]}" -gt 0 ]; then emit_helper > "${ARGS[0]}"; chmod 0755 "${ARGS[0]}"; else emit_helper; fi ;;
show)        dropin_source ;;
esac
