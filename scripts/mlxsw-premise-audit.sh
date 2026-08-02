#!/bin/bash
# Phase 1 -- mlxsw source-delta audit. STRICTLY READ-ONLY.
#
# Confirms every premise the mlxsw-dkms packaging depends on, against the
# kernel actually present on THIS machine. Designed to run either inside the
# build VM (scripts/vm.sh audit) or, read-only, on a live switch to re-validate
# the 6.1 baseline -- it writes nothing and installs nothing.
#
# Exit 0 = every premise holds. Exit 1 = at least one premise FAILED, which is
# a finding to stop and report on, not something to work around.
#
# The load-bearing subtlety is the THREE-state classification of a CONFIG
# symbol. "Absent" and "disabled" are different, and conflating them is how
# core_hwmon.o and core_thermal.o get silently dropped:
#
#   enabled   CONFIG_X=y or =m
#   disabled  "# CONFIG_X is not set"   -- kconfig SAW it and turned it off
#   absent    no line at all            -- kconfig never emitted it, because
#                                          it is select-only and unselected
set -uo pipefail   # deliberately NOT -e: every check must run and report

KVER="${KVER:-$(uname -r)}"
CONFIG="${CONFIG:-/boot/config-$KVER}"
HDR="${HDR:-/lib/modules/$KVER/build}"
SERIES="${SERIES:-$(printf '%s' "$KVER" | cut -d. -f1,2)}"
SRC="${SRC:-/usr/src/linux-source-$SERIES}"
MLXSW="$SRC/drivers/net/ethernet/mellanox/mlxsw"

pass=0; fail=0; note=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf()  { printf '  \033[36mNOTE\033[0m %s\n' "$*"; note=$((note+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -r "$CONFIG" ] || { echo "error: no kernel config at $CONFIG" >&2; exit 2; }

cfg_state() { # $1 = symbol without CONFIG_ ; prints enabled|disabled|other|absent
	local s="$1"
	if   grep -qE "^CONFIG_${s}=[ym]$"        "$CONFIG"; then echo enabled
	elif grep -qE "^CONFIG_${s}="             "$CONFIG"; then echo other
	elif grep -qE "^# CONFIG_${s} is not set$" "$CONFIG"; then echo disabled
	else echo absent; fi
}

expect() { # $1 = symbol, $2 = expected state, $3 = why it matters
	local got; got=$(cfg_state "$1")
	if [ "$got" = "$2" ]; then
		ok "CONFIG_$1 is $got"
	else
		bad "CONFIG_$1 is $got, expected $2 -- $3"
	fi
}

printf '\033[1mmlxsw premise audit\033[0m  kernel=%s series=%s\n' "$KVER" "$SERIES"
printf 'config=%s\nheaders=%s\nsource=%s\n' "$CONFIG" "$HDR" "$SRC"

# ---------------------------------------------------------------- 1
hdr "1. Debian still does not ship the mlxsw driver"
# If this ever flips to enabled, the driver ships stock and most of this
# architecture dissolves -- verify hard before celebrating, and revisit AD-1.
expect MLXSW_CORE disabled "if ENABLED, the driver ships stock and AD-1 must be revisited"
for s in MLXSW_PCI MLXSW_I2C MLXSW_SPECTRUM MLXSW_MINIMAL; do
	st=$(cfg_state "$s")
	[ "$st" = enabled ] && bad "CONFIG_$s is enabled -- unexpected" || ok "CONFIG_$s is $st"
done

# ---------------------------------------------------------------- 2
hdr "2. objagg/parman are ABSENT ENTIRELY (not 'is not set')"
# lib/Kconfig gives both a prompt only under COMPILE_TEST, so they are
# select-only symbols and kconfig omits invisible unselected symbols. A grep
# expecting "# CONFIG_OBJAGG is not set" reports a FALSE FAILURE.
expect OBJAGG absent "select-only symbol; 'disabled' would mean Debian now sees it"
expect PARMAN absent "select-only symbol; 'disabled' would mean Debian now sees it"

# ---------------------------------------------------------------- 3
hdr "3. objagg/parman headers are missing from the headers package"
for h in include/linux/objagg.h include/linux/parman.h include/trace/events/objagg.h; do
	if [ -e "$HDR/$h" ]; then
		bad "$h EXISTS in the headers package -- the package may no longer need to ship it"
	else
		ok "$h absent from headers (package must ship it)"
	fi
done

# ---------------------------------------------------------------- 4
hdr "4. mlxfw.h absent from headers while mlxfw.ko still ships"
if [ -e "$HDR/drivers/net/ethernet/mellanox/mlxfw/mlxfw.h" ]; then
	bad "mlxfw.h EXISTS in headers -- the sibling-dir layout may be unnecessary"
else
	ok "mlxfw.h absent from headers (hence the mlxfw/ sibling dir)"
fi
expect MLXFW enabled "mlxsw links against it"
if find "/lib/modules/$KVER" -name 'mlxfw.ko*' -print -quit 2>/dev/null | grep -q .; then
	ok "mlxfw.ko ships in linux-image"
else
	bad "mlxfw.ko NOT found under /lib/modules/$KVER"
fi

# ---------------------------------------------------------------- 5
hdr "5. every mlxsw dependency is still enabled"
for s in NET_SWITCHDEV NET_DEVLINK PSAMPLE VXLAN NET_IPGRE IPV6_GRE \
         BRIDGE_VLAN_FILTERING PTP_1588_CLOCK; do
	expect "$s" enabled "mlxsw depends on it"
done

# ---------------------------------------------------------------- 6
hdr "6. the shipped Makefile's object list"
if [ ! -r "$MLXSW/Makefile" ]; then
	bad "no Makefile at $MLXSW -- is linux-source-$SERIES extracted?"
else
	# All four conditional lines must be PRESENT. The package supplies their
	# CONFIG macros itself, so what matters here is that none has silently
	# disappeared or gained a sibling we do not know about.
	# `obj-$(CONFIG_X) += foo.o` declares a MODULE; `foo-$(CONFIG_X) += bar.o`
	# adds an OBJECT to one. Only the latter is what this check counts, so
	# obj- must be excluded or every module declaration inflates the total.
	conds=$(grep -E '^[a-z_]+-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=' "$MLXSW/Makefile" \
		| grep -v '^obj-')
	nconf=$(printf '%s\n' "$conds" | grep -c . )
	if [ "$nconf" = "4" ]; then
		ok "4 conditional object lines, as expected"
	else
		bad "$nconf conditional object lines, expected 4 -- investigate before proceeding"
	fi
	printf '%s\n' "$conds" | sed 's/^/       /'

	# Object count with every conditional resolved ON (which is what the
	# package's -D macros do), compared against the .c files actually present.
	nobj=$(sed -e :a -e '/\\$/{N;s/\\\n//;ta' -e '}' "$MLXSW/Makefile" \
		| grep -oE '[a-z0-9_]+\.o' | sort -u | grep -vcE '^mlxsw_(core|pci|i2c|spectrum|minimal)\.o$')
	ncfile=$(ls "$MLXSW"/*.c 2>/dev/null | wc -l)
	if [ "$nobj" = "$ncfile" ]; then
		ok "$nobj objects == $ncfile .c files present"
	else
		bad "$nobj objects vs $ncfile .c files -- they should correspond exactly"
	fi
fi

# ---------------------------------------------------------------- 7
hdr "7. size of the driver set (for the architecture appendix)"
if [ -d "$MLXSW" ]; then
	# Report .c-only AND .c+.h separately. The 6.1 baseline recorded in
	# docs/architecture.md is a single "67 342 lines" with no stated scope,
	# so a single number here is not comparable to it -- give both and let
	# the appendix be corrected to say which it means.
	inf "$(ls "$MLXSW"/*.c 2>/dev/null | wc -l) .c files, $(ls "$MLXSW"/*.h 2>/dev/null | wc -l) .h files"
	inf "$(cat "$MLXSW"/*.c 2>/dev/null | wc -l) lines in .c only"
	inf "$(cat "$MLXSW"/*.[ch] 2>/dev/null | wc -l) lines in .c + .h"
	inf "$(du -sh "$MLXSW" 2>/dev/null | cut -f1) on disk"
	inf "6.1 baseline recorded as: 49 .c files, 67342 lines (scope unstated), 2.7 MB"
fi

# ---------------------------------------------------------------- 8
hdr "8. module signing posture (R2)"
# SIG=y with SIG_FORCE unset means unsigned OOT modules LOAD and merely taint.
# If SIG_FORCE ever becomes set, unsigned modules stop loading and the whole
# DKMS delivery model needs MOK enrollment or signing.
expect MODULE_SIG enabled "expected on Debian"
st=$(cfg_state MODULE_SIG_FORCE)
case "$st" in
disabled|absent) ok "CONFIG_MODULE_SIG_FORCE is $st -- unsigned OOT modules load, tainting only" ;;
*)               bad "CONFIG_MODULE_SIG_FORCE is $st -- unsigned modules will NOT load; R2 becomes blocking" ;;
esac
expect MODVERSIONS enabled "ABI mismatch should fail at load, not corrupt silently"

# ---------------------------------------------------------------- summary
printf '\n%s\n' "----------------------------------------"
printf '%d passed, %d failed, %d notes\n' "$pass" "$fail" "$note"
[ "$fail" -eq 0 ] || {
	printf '\n\033[31mA premise FAILED. Stop and report it -- do not work around it.\033[0m\n'
	exit 1
}
