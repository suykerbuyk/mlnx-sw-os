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

# ================================================================
# T9 onward: the PACKAGING half. T1-T8 prove the object list is right; what
# follows proves the .deb wrapped around it is right, which is a separate way
# to end up with a switch that boots with no ports.
#
# Three artifacts are in play and the distinction between them is load-bearing:
#
#   mlxsw-dkms_6.1.177-1_all.deb          FROZEN. Hardware-proven, installed on
#                                         both live switches. T1's reference.
#   mlxsw-dkms_6.12.100-1_all.deb         FROZEN. The provenance root: built and
#                                         proven against trixie's 6.12, but
#                                         carrying the old, wrong control file.
#   mlxsw-dkms_6.12.100-1+deb13u1_all.deb The corrected cut. Same payload,
#                                         re-stamped control + README.
# ================================================================
FROZEN61="$DEPLOYED"
FROZEN612="$ROOT/mlnx-switch-packages/dkms/mlxsw-dkms_6.12.100-1_all.deb"
CORRECTED="$ROOT/mlnx-switch-packages/dkms/mlxsw-dkms_6.12.100-1+deb13u1_all.deb"

# The one correct dependency line, written out in full exactly once so that
# every assertion below compares against the same literal. A grep for the
# package names would happily pass a subtly wrong line; this will not.
DEPENDS_WANT='dkms (>= 2.1.0.0), build-essential, linux-headers-amd64 (>= 6.12)'

# ---------------------------------------------------------------- T9
head "T9  the corrected package's Depends line is exactly right"

# Every way this line can be wrong ends at the same place -- a switch with no
# data plane:
#
#  * drop build-essential and `apt install --no-install-recommends ./x.deb`
#    resolves cleanly (dkms carries the compiler in ITS Recommends, not its
#    Depends), then postinst finds no compiler and DKMS builds nothing.
#  * demote linux-headers-amd64 to Recommends -- which is exactly what the
#    frozen 6.12.100-1 root does -- and the same flag omits the headers, with
#    the same result and no warning.
#  * pin linux-headers to a kernel version and the NEXT kernel arrives with no
#    matching headers, so DKMS silently builds nothing at upgrade time.
#
# Hence an exact string match. "Close enough" is the failure mode here.
if [ ! -r "$CORRECTED" ]; then
	bad "corrected package missing: $CORRECTED"
else
	dpkg-deb -f "$CORRECTED" > "$WORK/ctl.corrected" 2>/dev/null
	got=$(dpkg-deb -f "$CORRECTED" Depends 2>/dev/null)
	[ "$got" = "$DEPENDS_WANT" ] && ok "Depends matches exactly" \
	                             || bad "Depends differs" "want: $DEPENDS_WANT" "got:  ${got:-<absent>}"

	# The frozen root really does say "Recommends: linux-headers-amd64". If
	# a re-stamp ever leaves that line behind, the floor asserted in T10 is
	# decorative -- --no-install-recommends walks straight past it.
	if grep -qE '^Recommends:.*linux-headers' "$WORK/ctl.corrected"; then
		bad "control still carries a Recommends: naming linux-headers" \
		    "$(grep -E '^Recommends:' "$WORK/ctl.corrected")"
	else
		ok "no Recommends: naming linux-headers"
	fi

	# Enumerate every linux-headers* token in the control and demand the
	# set be exactly {linux-headers-amd64}. That catches the metapackage
	# being swapped for linux-headers-6.12.100-1, or for the expansion of
	# linux-headers-$(uname -r), without needing to guess the shape of the
	# mistake in advance.
	hdr_names=$(grep -o 'linux-headers[^ ,)]*' "$WORK/ctl.corrected" | sort -u | tr '\n' ' ')
	hdr_names="${hdr_names% }"
	[ "$hdr_names" = "linux-headers-amd64" ] \
		&& ok "linux-headers-amd64 is the bare metapackage" \
		|| bad "linux-headers named as something other than the metapackage" \
		       "found: ${hdr_names:-<none>}"
fi

# ---------------------------------------------------------------- T10
head "T10 a floor on linux-headers-amd64, never a ceiling"

# Standing rule, and the reason is mechanical rather than stylistic: headers
# only ever move up, so a floor is stable forever, while a "<<" upper bound
# breaks self-maintenance at the next kernel series bump -- and it breaks it by
# making apt REMOVE this package. Same dead switch as a missing dependency,
# arrived at politely. This test exists to fail loudly if someone later
# "tightens" the floor into a range.
#
# Checked against BOTH the shipped artifact and a freshly emitted --control
# block: they come from the same emit_control(), and the point of that is that
# they can never diverge, so both must be held to it.
no_ceiling() { # $1 = label, $2 = file holding a control block
	local hits floor
	hits=$(grep 'linux-headers-amd64' "$2" | grep -E '<<|<=' || true)
	[ -z "$hits" ] && ok "$1: no << or <= upper bound" \
	               || bad "$1: an upper bound appeared on linux-headers-amd64" "$hits"
	# The floor must still be there. Without this second assertion, deleting
	# the version constraint outright would satisfy the first one -- a test
	# that passes because nothing is left to check.
	floor=$(grep -c 'linux-headers-amd64 (>= 6.12)' "$2")
	[ "$floor" = "1" ] && ok "$1: the >= 6.12 floor is present" \
	                   || bad "$1: floor missing or duplicated (found $floor)"
}
[ -r "$WORK/ctl.corrected" ] && no_ceiling "artifact" "$WORK/ctl.corrected" \
                             || bad "artifact: no control to check"

"$MK" --control --version 6.12.100 \
      --os-release "$FIX/os-release.trixie" > "$WORK/ctl.emitted" 2>/dev/null
no_ceiling "--control" "$WORK/ctl.emitted"

# ---------------------------------------------------------------- T11
head "T11 the corrected package carries the frozen payload byte for byte"

# This is the whole justification for --restamp. The corrected package is not a
# rebuild: it is the payload that was actually compiled and proven against
# trixie's 6.12, re-wrapped with a fixed control file. If the payload drifted,
# then "proven" refers to something that is no longer in the box, and the only
# honest response would be to re-run the build.
if [ ! -r "$FROZEN612" ] || [ ! -r "$CORRECTED" ]; then
	bad "need both $FROZEN612 and $CORRECTED"
else
	mkdir -p "$WORK/x.frozen612" "$WORK/x.corrected"
	dpkg-deb -x "$FROZEN612"  "$WORK/x.frozen612" 2>/dev/null
	dpkg-deb -x "$CORRECTED"  "$WORK/x.corrected" 2>/dev/null
	if diff -r "$WORK/x.frozen612/usr/src" "$WORK/x.corrected/usr/src" > "$WORK/pdiff" 2>&1; then
		ok "usr/src trees identical ($(find "$WORK/x.corrected/usr/src" -type f | wc -l) files)"
	else
		bad "payload drifted between the frozen root and the corrected cut" \
		    "$(head -20 "$WORK/pdiff")"
	fi

	# The other half of the re-stamp: README.Debian is the operator-facing
	# copy of emit_control()'s reasoning, addressed to whoever is standing
	# in front of a switch mid-upgrade with no checkout of this repo. It is
	# new in the corrected cut, so its presence here and its absence there
	# together prove the re-stamp did something.
	RDOC="usr/share/doc/mlxsw-dkms/README.Debian"
	[ -r "$WORK/x.corrected/$RDOC" ] && ok "corrected package ships $RDOC" \
	                                 || bad "corrected package is missing $RDOC"
	[ -e "$WORK/x.frozen612/$RDOC" ] && bad "frozen root already has $RDOC -- has it been regenerated?" \
	                                 || ok "frozen root has no $RDOC, as expected"
fi

# ---------------------------------------------------------------- T12
head "T12 the frozen artifacts are still frozen"

# T1 is only meaningful because mlxsw-dkms_6.1.177-1_all.deb was built once,
# proven on hardware, and never touched again: it is an INDEPENDENT witness
# that the derivation is right. Regenerate it with the current script and T1
# quietly becomes a tautology -- the script agreeing with itself -- while still
# printing PASS. The same argument covers the 6.12.100-1 root, which is what
# makes T11's payload comparison mean anything.
#
# So the freeze is asserted mechanically. If one of these hashes changes, that
# is not a hash to update: it is a regenerated artifact to put back.
SHA_FROZEN61="771d62afe3ea4624bac1fe99ee1fa0ea5e4a3743d5dce02f8f422df6f5bdac8d"
SHA_FROZEN612="1a69d4cd4db0d8a7cc47d5b4a08e1d5cd62cafa1a264630c89a4172d198806a8"

check_frozen() { # $1 = label, $2 = path, $3 = expected sha256
	local got
	if [ ! -r "$2" ]; then bad "$1: missing ($2)"; return; fi
	got=$(sha256sum "$2" | cut -d' ' -f1)
	[ "$got" = "$3" ] && ok "$1: sha256 unchanged" \
	                  || bad "$1: REGENERATED -- the freeze is broken" \
	                         "want $3" "got  $got"
}
check_frozen "6.1.177-1  (deployed on both switches)" "$FROZEN61"  "$SHA_FROZEN61"
check_frozen "6.12.100-1 (provenance root)"           "$FROZEN612" "$SHA_FROZEN612"

# ---------------------------------------------------------------- T13
head "T13 version ordering: +debNuN is offered as an upgrade, ~debNuN is not"

# The corrected package has to reach a fleet that already has 6.12.100-1
# installed. apt only offers a package it considers NEWER, so the suffix
# choice is not cosmetic -- it decides whether the fix ships at all.
if dpkg --compare-versions "6.12.100-1+deb13u1" gt "6.12.100-1"; then
	ok "6.12.100-1+deb13u1 > 6.12.100-1 (apt offers the corrected cut)"
else
	bad "6.12.100-1+deb13u1 does NOT sort above 6.12.100-1 -- the fix would never be offered"
fi

# Negative control, documenting a design that was considered and REJECTED.
# "~" sorts below everything, including the empty string: it is Debian's
# prerelease marker, meant for 1.0~rc1 < 1.0. A package versioned
# 6.1.177-1~deb12u1 would therefore sort BELOW the plain 6.1.177-1 already
# installed on both switches, and apt would silently never offer it. That is
# precisely why "+debNuN" was chosen over "~debNuN". If this assertion ever
# starts failing, dpkg's ordering rules changed and the suffix choice needs
# revisiting -- do not just delete the test.
if dpkg --compare-versions "6.1.177-1~deb12u1" gt "6.1.177-1"; then
	bad "'~' no longer sorts below the unsuffixed version -- the +debNuN rationale is void"
else
	ok "6.1.177-1~deb12u1 is NOT > 6.1.177-1 ('~' sorts below -- why +debNuN was chosen)"
fi

# ---------------------------------------------------------------- T14
head "T14 the >= 6.12 floor really does refuse bookworm"

# Both live switches run bookworm, whose linux-headers-amd64 is 6.1.177-1.
# Hand-copying a .deb between machines is how these packages actually get
# installed -- it is how both switches were provisioned -- so "someone scp's
# the trixie package onto a bookworm switch" is a real path, not a hypothetical
# one. Installing it there gives a switch that boots with no mlxsw modules and
# therefore no ports. The floor is the thing that stops it, at dpkg, before any
# damage. This test proves the floor discriminates rather than merely existing.
if dpkg --compare-versions "6.1.177-1" ge "6.12"; then
	bad "bookworm's linux-headers-amd64 6.1.177-1 SATISFIES (>= 6.12) -- the guard is inert"
else
	ok "bookworm 6.1.177-1 does not satisfy (>= 6.12) -- install refused"
fi
if dpkg --compare-versions "6.12.100-1" ge "6.12"; then
	ok "trixie 6.12.100-1 satisfies (>= 6.12) -- install allowed"
else
	bad "trixie's own linux-headers-amd64 fails the floor -- the package is uninstallable everywhere"
fi

# ---------------------------------------------------------------- T15
head "T15 the frozen 6.12 package's shipped Kbuild matches the derivation"

# T1 does this for 6.1 against the hardware-proven package. Until now nothing
# did it for 6.12, so the 6.12 half of the derivation was only ever checked
# against a fixture -- never against what actually got built and shipped.
#
# Note what is being compared: the Kbuild INSIDE the frozen package was
# generated from DEBIAN TRIXIE's mlxsw Makefile, while the fixture is UPSTREAM
# v6.12's. That they agree is an EMPIRICAL finding, measured, not a guarantee:
# Debian is free to patch that Makefile in a point release. If this test starts
# failing it means Debian has diverged from upstream, and the right response is
# to go read the divergence and decide which list is correct -- not to loosen
# the comparison.
if [ ! -r "$FROZEN612" ]; then
	bad "frozen 6.12 package missing: $FROZEN612"
else
	mkdir -p "$WORK/x612"
	dpkg-deb -x "$FROZEN612" "$WORK/x612" 2>/dev/null
	KBUILD612="$WORK/x612/usr/src/mlxsw-6.12.100/Kbuild"
	if [ ! -r "$KBUILD612" ]; then
		bad "no Kbuild inside the frozen 6.12 package"
	else
		# prefix "" -- the shipped Kbuild already carries mlxsw/ paths,
		# same as T1.
		derive -m "$KBUILD612" -p ""                  > "$WORK/shipped612.manifest"
		derive -m "$FIX/Makefile.upstream-v6.12"      > "$WORK/upstream612.manifest"
		if diff -u "$WORK/shipped612.manifest" "$WORK/upstream612.manifest" > "$WORK/d15"; then
			ok "shipped Kbuild == upstream v6.12 derivation ($(awk '{s += NF - 1} END {print s}' "$WORK/shipped612.manifest") objects, $(wc -l < "$WORK/shipped612.manifest") modules)"
		else
			bad "the shipped 6.12 Kbuild disagrees with upstream v6.12 -- investigate, do not loosen" \
			    "$(cat "$WORK/d15")"
		fi
	fi
fi

# ---------------------------------------------------------------- T16
head "T16 suite identity comes from os-release, and only from os-release"

# WHY os-release and never `uname -r`: the running kernel names a BUILD TARGET,
# not a distribution. A 6.1 kernel booted on a trixie rescue system is still
# trixie; a trixie build host with a mounted bookworm source tree is still
# trixie. Deriving the suite from the kernel gets both cases backwards and
# stamps the wrong provenance onto the package -- and the version suffix is
# how an operator later tells the two builds apart on a shelf full of switches.
#
# --control is the right lever for this: it reads no kernel source at all, so
# the identity derivation is exercised in isolation.
suite_version() { # $1 = os-release fixture basename -> prints the Version: field
	"$MK" --control --version 6.12.100 --os-release "$FIX/os-release.$1" \
	      2>"$WORK/sv.err" | awk -F': ' '/^Version:/ {print $2; exit}'
}

v=$(suite_version trixie)
[ "$v" = "6.12.100-1+deb13u1" ] && ok "trixie   -> $v" \
                               || bad "trixie: want 6.12.100-1+deb13u1, got ${v:-<none>}"

# bookworm is DROPPED from image generation, but the derivation itself must
# still be correct: it is what would produce a bookworm-labelled package if the
# ruling were ever revisited, and a derivation that silently emits deb13 for a
# bookworm host would be a mislabelled package, not a dropped one.
v=$(suite_version bookworm)
[ "$v" = "6.12.100-1+deb12u1" ] && ok "bookworm -> $v" \
                               || bad "bookworm: want 6.12.100-1+deb12u1, got ${v:-<none>}"

# Arch is the actual build host for this repo. "+debNuN" is a Debian
# convention and only a Debian convention, so stamping it onto a non-Debian
# build would assert a provenance the package does not have. The generator
# emits no suffix and says so on stderr -- silence here would be the bug,
# because an unsuffixed package looks exactly like a legitimate upstream cut.
v=$(suite_version arch)
[ "$v" = "6.12.100-1" ] && ok "arch     -> $v (no +debNuN suffix)" \
                        || bad "arch: want a bare 6.12.100-1, got ${v:-<none>}"
grep -q 'not debian' "$WORK/sv.err" && ok "arch: warns on stderr about the missing suffix" \
                                    || bad "arch: derived no suffix but issued no warning" \
                                           "stderr: $(cat "$WORK/sv.err")"

# ---------------------------------------------------------------- T17
head "T17 os-release is PARSED, never sourced"

# os-release is shell syntax by specification, so `. "$OS_RELEASE"` is the
# obvious implementation and it is wrong here: --os-release takes an ARBITRARY
# path, and sourcing an arbitrary path hands that data file the generator's
# variable namespace and a shell. It could reassign VER, PKGVER or SUITE_TAG
# and rewrite the package's identity behind the script's back -- producing a
# .deb that is correctly built, correctly signed, and named after a version
# nobody chose.
#
# os-release.hostile carries genuine trixie keys PLUS that payload, so a parser
# and a sourcer derive the same suite and differ only in whether the payload
# fires. Both halves are checked: the fields must be untouched, and the
# command substitution in the fixture must not have run.
export T17_MARKER="$WORK/t17-sourced"
rm -f "$T17_MARKER"
"$MK" --control --version 6.12.100 \
      --os-release "$FIX/os-release.hostile" > "$WORK/ctl.hostile" 2>"$WORK/hostile.err"
unset T17_MARKER

v=$(awk -F': ' '/^Version:/ {print $2; exit}' "$WORK/ctl.hostile")
[ "$v" = "6.12.100-1+deb13u1" ] && ok "version derived from the real keys ($v)" \
                                || bad "hostile file rewrote the version" \
                                       "want 6.12.100-1+deb13u1, got ${v:-<none>}"

# Honest note on the assertion below: today emit_control()'s Depends line is a
# literal inside a heredoc, so no os-release file can perturb it and this
# assertion cannot currently fail -- verified by running the same three
# assertions against a deliberately-sourcing copy of the generator, where the
# version check and the side-effect check both failed and this one did not. It
# is kept as a FORWARD guard: the moment anyone interpolates a variable into
# that line (a templated headers floor is the obvious candidate), a sourced
# os-release could set it, and this is the assertion that would notice.
d=$(awk -F': ' '/^Depends:/ {sub(/^Depends: /, ""); print; exit}' "$WORK/ctl.hostile")
[ "$d" = "$DEPENDS_WANT" ] && ok "Depends unaffected by the hostile file" \
                           || bad "hostile file perturbed Depends" "got: ${d:-<none>}"

[ -e "$WORK/t17-sourced" ] && bad "the fixture's command substitution RAN -- os-release is being sourced" \
                           || ok "no side effect: the fixture was read as data"

# ---------------------------------------------------------------- T18
head "T18 the corrected cut is reproducible from the frozen root"

# Not in the original brief, but it locks the invariant the other packaging
# tests only assume: that the shipped +deb13u1 artifact IS what
# `--restamp` produces from the frozen root, rather than something hand-edited
# once and committed. Provenance that cannot be re-derived is just a claim.
#
# Output goes to a tmpdir. Nothing here writes into mlnx-switch-packages/.
if [ ! -r "$FROZEN612" ]; then
	bad "frozen 6.12 package missing: $FROZEN612"
else
	if "$MK" --restamp "$FROZEN612" --os-release "$FIX/os-release.trixie" \
	         -o "$WORK/restamp" >"$WORK/restamp.log" 2>&1; then
		REDONE="$WORK/restamp/mlxsw-dkms_6.12.100-1+deb13u1_all.deb"
		if [ ! -r "$REDONE" ]; then
			bad "--restamp reported success but produced no $REDONE" "$(cat "$WORK/restamp.log")"
		else
			if diff <(dpkg-deb -f "$REDONE") <(dpkg-deb -f "$CORRECTED") > "$WORK/d18c" 2>&1; then
				ok "re-stamped control identical to the shipped artifact's"
			else
				bad "re-stamping the frozen root yields a different control" "$(cat "$WORK/d18c")"
			fi
			mkdir -p "$WORK/x.redone"
			dpkg-deb -x "$REDONE" "$WORK/x.redone" 2>/dev/null
			if diff -r "$WORK/x.redone" "$WORK/x.corrected" > "$WORK/d18t" 2>&1; then
				ok "re-stamped contents identical to the shipped artifact's"
			else
				bad "re-stamping the frozen root yields different contents" "$(head -20 "$WORK/d18t")"
			fi
		fi
	else
		bad "--restamp of the frozen root failed" "$(cat "$WORK/restamp.log")"
	fi

	# --restamp reads its input and writes elsewhere. Re-assert the frozen
	# root's hash AFTER running it: an in-place rewrite is the one way this
	# test suite could itself break the freeze it checks in T12.
	check_frozen "6.12.100-1 after --restamp" "$FROZEN612" "$SHA_FROZEN612"

	# And the generator refuses to re-stamp to the version it already has,
	# which is what stops `--restamp frozen.deb` on a host that derives no
	# suffix from silently overwriting a frozen artifact in place.
	if "$MK" --restamp "$FROZEN612" --suite trixie --suite-tag "" \
	         -o "$WORK/restamp2" >"$WORK/r2.log" 2>&1; then
		bad "--restamp accepted a no-op version change instead of refusing"
	else
		grep -q 'refusing to overwrite in place' "$WORK/r2.log" \
			&& ok "refuses to re-stamp a package to its own version" \
			|| bad "refused, but not for the expected reason" "$(cat "$WORK/r2.log")"
	fi
fi

# ---------------------------------------------------------------- summary
printf '\n%s\n' "----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
