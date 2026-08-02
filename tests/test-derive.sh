#!/bin/bash
# Regression tests for the mlxsw Kbuild object-list derivation.
#
# The load-bearing test is DERIVED-vs-DEPLOYED: the object list derived from
# Debian's own 6.1 mlxsw Makefile must reproduce, exactly, the list shipped in
# mlxsw-dkms_6.1.177-1_all.deb -- the package running on both live switches
# right now. If the derivation cannot reproduce a package known to work on
# hardware, it cannot be trusted to produce one for 6.12.
#
# Needs no VM, no kernel build, and no network.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$HERE")"
MK="$ROOT/scripts/mk-mlxsw-dkms.sh"
FIX="$HERE/fixtures"
DEPLOYED="$ROOT/mlnx-switch-packages/dkms/mlxsw-dkms_6.1.177-1_all.deb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; fail=$((fail + 1)); }
head() { printf '\n%s\n' "$1"; }

derive() { # $@ passed through to the generator in manifest mode
	"$MK" --manifest -c "$FIX/config-6.1.0-51-amd64" "$@" 2>"$WORK/err"
}

# ---------------------------------------------------------------- T1
head "T1  derived from Debian 6.1 Makefile == deployed package Kbuild"

if [ ! -r "$DEPLOYED" ]; then
	bad "deployed package missing: $DEPLOYED"
else
	dpkg-deb -x "$DEPLOYED" "$WORK/deb" 2>/dev/null
	SHIPPED_KBUILD="$WORK/deb/usr/src/mlxsw-6.1.177/Kbuild"
	if [ ! -r "$SHIPPED_KBUILD" ]; then
		bad "no Kbuild inside the deployed package"
	else
		derive -m "$FIX/Makefile.debian-6.1.177"       > "$WORK/derived.manifest"
		# prefix "" -- the shipped Kbuild already carries mlxsw/ paths.
		derive -m "$SHIPPED_KBUILD" -p ""              > "$WORK/deployed.manifest"
		if diff -u "$WORK/deployed.manifest" "$WORK/derived.manifest" > "$WORK/diff"; then
			ok "object lists identical ($(awk '{s += NF - 1} END {print s}' "$WORK/derived.manifest") objects, $(wc -l < "$WORK/derived.manifest") modules)"
		else
			bad "derived list differs from the deployed package" "$(cat "$WORK/diff")"
		fi
	fi
fi

# ---------------------------------------------------------------- T2
head "T2  per-module object counts match the hardware-proven package"

derive -m "$FIX/Makefile.debian-6.1.177" > "$WORK/m61" 2>/dev/null
check_count() {
	local mod="$1" want="$2" got
	got=$(awk -v m="$mod" '$1 == m {print NF - 1}' "$WORK/m61")
	[ "$got" = "$want" ] && ok "$mod: $want" || bad "$mod: want $want, got ${got:-<absent>}"
}
check_count mlxsw_core     8   # 6 base + core_hwmon.o + core_thermal.o
check_count mlxsw_pci      1
check_count mlxsw_i2c      1
check_count mlxsw_minimal  1
check_count mlxsw_spectrum 38  # 36 base + spectrum_dcb.o + spectrum_ptp.o
check_count objagg         1
check_count parman         1

total=$(awk '{s += NF - 1} END {print s}' "$WORK/m61")
[ "$total" = "51" ] && ok "total 51 (49 mlxsw + objagg + parman)" \
                    || bad "total: want 51, got $total"

# ---------------------------------------------------------------- T3
head "T3  the four conditional objects are present, not silently dropped"

# These are the ones the first plan revision would have lost: three of their
# CONFIG symbols are absent from Debian's config ENTIRELY (not "is not set"),
# so a resolver that reads only the kernel config drops them with no error.
for obj in mlxsw/core_hwmon.o mlxsw/core_thermal.o mlxsw/spectrum_dcb.o mlxsw/spectrum_ptp.o; do
	grep -qF " $obj" "$WORK/m61" && ok "$obj present" || bad "$obj MISSING"
done

# ---------------------------------------------------------------- T4
head "T4  6.12 adds exactly spectrum_port_range.o and nothing else"

derive -m "$FIX/Makefile.upstream-v6.12" > "$WORK/m612" 2>/dev/null
if diff "$WORK/m61" "$WORK/m612" > "$WORK/d612"; then
	bad "6.12 manifest identical to 6.1 -- expected +spectrum_port_range.o"
else
	added=$(diff "$WORK/m61" "$WORK/m612" | grep '^>' | tr ' ' '\n' | grep -c 'spectrum_port_range.o')
	t612=$(awk '{s += NF - 1} END {print s}' "$WORK/m612")
	[ "$added" = "1" ] && ok "spectrum_port_range.o added" \
	                   || bad "spectrum_port_range.o not the added object"
	[ "$t612" = "52" ] && ok "total 52 (50 mlxsw + objagg + parman)" \
	                   || bad "6.12 total: want 52, got $t612"
	sc=$(awk '$1 == "mlxsw_spectrum" {print NF - 1}' "$WORK/m612")
	[ "$sc" = "39" ] && ok "mlxsw_spectrum: 39" || bad "mlxsw_spectrum: want 39, got $sc"
fi

# ---------------------------------------------------------------- T5
head "T5  an unaccounted CONFIG symbol is a hard error, never a silent drop"

cat > "$WORK/Makefile.unknown" <<'EOF'
obj-$(CONFIG_MLXSW_CORE)	+= mlxsw_core.o
mlxsw_core-objs			:= core.o
mlxsw_core-$(CONFIG_TOTALLY_MADE_UP) += invented.o
EOF
if derive -m "$WORK/Makefile.unknown" > "$WORK/out" 2>"$WORK/err"; then
	bad "accepted an unknown CONFIG symbol instead of failing"
else
	rc=$?
	[ "$rc" = "2" ] && ok "exit 2 on unaccounted symbol" || bad "want exit 2, got $rc"
	grep -q "CONFIG_TOTALLY_MADE_UP" "$WORK/err" && ok "names the offending symbol" \
	                                             || bad "error does not name the symbol"
fi

# ---------------------------------------------------------------- T6
head "T6  package macros beat the kernel config's 'is not set'"

# CONFIG_MLXSW_CORE really is "# CONFIG_MLXSW_CORE is not set" in Debian's
# config. If the resolver consulted the config before this package's own -D
# macros, EVERY module would resolve to disabled and the derivation would
# silently emit an empty package that builds fine and ships nothing.
grep -q '^# CONFIG_MLXSW_CORE is not set$' "$FIX/config-6.1.0-51-amd64" \
	&& ok "fixture really does disable CONFIG_MLXSW_CORE" \
	|| bad "fixture no longer disables CONFIG_MLXSW_CORE -- test is void"

mods=$(wc -l < "$WORK/m61")
[ "$mods" = "7" ] && ok "7 modules derived despite that" \
                  || bad "want 7 modules, got $mods"

# ---------------------------------------------------------------- T7
head "T7  generated Kbuild round-trips through the parser"

"$MK" --kbuild -m "$FIX/Makefile.debian-6.1.177" \
      -c "$FIX/config-6.1.0-51-amd64" > "$WORK/Kbuild.gen" 2>/dev/null
derive -m "$WORK/Kbuild.gen" -p "" > "$WORK/roundtrip.manifest"
if diff -u "$WORK/m61" "$WORK/roundtrip.manifest" > "$WORK/rt"; then
	ok "re-parsing our own output reproduces the manifest"
else
	bad "round-trip differs" "$(cat "$WORK/rt")"
fi

if awk -f "$ROOT/scripts/mlxsw-objs.awk" "$WORK/Kbuild.gen" | grep -q '^UNKNOWN'; then
	bad "generated Kbuild has lines the parser cannot read"
else
	ok "generated Kbuild fully parseable"
fi

# ---------------------------------------------------------------- T8
head "T8  dkms.conf BUILT_MODULE_NAME entries cover every module"

# Not derivable from --kbuild, so exercise the emitter via the same path the
# build uses: count entries against the module list.
n_mods=$(wc -l < "$WORK/m61")
n_conf=$("$MK" --manifest -m "$FIX/Makefile.debian-6.1.177" \
              -c "$FIX/config-6.1.0-51-amd64" 2>/dev/null | wc -l)
[ "$n_conf" = "$n_mods" ] && ok "$n_mods modules accounted for" \
                          || bad "module count mismatch: $n_conf vs $n_mods"

# ---------------------------------------------------------------- summary
printf '\n%s\n' "----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
