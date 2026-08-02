#!/bin/bash
# Build an mlxsw-dkms source package + .deb from Debian's own linux-source.
#
# The object list is DERIVED from the kernel's own shipped mlxsw Makefile
# rather than hand-maintained here. A hardcoded list goes stale silently: the
# 6.1 -> 6.12 bump adds spectrum_port_range.o, and a list that misses it fails
# at modpost with undefined symbols long after the mistake was made.
#
# Layout note: mlxsw does #include "../mlxfw/mlxfw.h", so the driver sources
# live in a mlxsw/ subdirectory with a sibling mlxfw/ holding just that header.
# That satisfies the relative include with ZERO source modification.
set -eu

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$HERE/mlxsw-objs.awk"

# ---------------------------------------------------------------- defaults
SERIES=""
SRC=""
VER=""
KCONFIG=""
MAKEFILE=""
OUTDIR=""
PREFIX="mlxsw/"
MODE="build"

MLXSW_SUBDIR="drivers/net/ethernet/mellanox/mlxsw"

# CONFIG symbols this package supplies ITSELF, because they are absent from a
# stock Debian kernel's config entirely -- CONFIG_MLXSW_CORE is off, and
# kconfig omits invisible unselected symbols, so objagg/parman never appear at
# all (not even as "is not set").
#
# The macro form differs on purpose. Tristate options are declared _MODULE
# because the driver is built as a module; bool sub-options are declared plain.
# IS_ENABLED() accepts either, and getting it backwards silently compiles the
# feature out. Ordered array, not an associative one: this is also the source
# of the ccflags block, and that must be deterministic across runs.
PKG_CONFIG=(
	"MLXSW_CORE:CONFIG_MLXSW_CORE_MODULE"
	"MLXSW_PCI:CONFIG_MLXSW_PCI_MODULE"
	"MLXSW_I2C:CONFIG_MLXSW_I2C_MODULE"
	"MLXSW_SPECTRUM:CONFIG_MLXSW_SPECTRUM_MODULE"
	"MLXSW_MINIMAL:CONFIG_MLXSW_MINIMAL_MODULE"
	"MLXSW_CORE_HWMON:CONFIG_MLXSW_CORE_HWMON"
	"MLXSW_CORE_THERMAL:CONFIG_MLXSW_CORE_THERMAL"
	"MLXSW_SPECTRUM_DCB:CONFIG_MLXSW_SPECTRUM_DCB"
	"OBJAGG:CONFIG_OBJAGG_MODULE"
	"PARMAN:CONFIG_PARMAN_MODULE"
)

# lib/ helpers Debian does not build, because only mlxsw selects them. They are
# not in the mlxsw Makefile, so they are named here rather than derived.
LIB_MODULES=(objagg parman)

usage() {
	cat <<'USAGE'
Usage: mk-mlxsw-dkms.sh [options]

  -s, --src DIR        kernel source tree root
                       (default: /usr/src/linux-source-<series>)
  -S, --series VER     kernel series, e.g. 6.1 or 6.12
                       (default: derived from --version, else 6.1)
  -v, --version VER    package version, e.g. 6.1.177
                       (default: derived from <src>/Makefile)
  -c, --config FILE    target kernel .config, for resolving CONFIG symbols
                       this package does not supply itself
                       (default: /boot/config-$(uname -r))
  -m, --makefile FILE  parse this Makefile instead of the one under --src
  -p, --prefix STR     path prefix for derived objects (default: "mlxsw/";
                       pass "" when re-parsing an already-generated Kbuild)
  -o, --outdir DIR     where to leave the built .deb (default: the stage dir)

      --manifest       print the derived object manifest and exit
      --kbuild         print the derived Kbuild and exit
  -h, --help           this text

Exit 2 means a CONFIG symbol in the Makefile could not be accounted for from
either this package's macro set or the target kernel config. That is a hard
error on purpose: treating an unknown symbol as "disabled" is how objects go
missing silently.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
	case "$1" in
	-s|--src)      SRC="$2"; shift 2 ;;
	-S|--series)   SERIES="$2"; shift 2 ;;
	-v|--version)  VER="$2"; shift 2 ;;
	-c|--config)   KCONFIG="$2"; shift 2 ;;
	-m|--makefile) MAKEFILE="$2"; shift 2 ;;
	-p|--prefix)   PREFIX="$2"; shift 2 ;;
	-o|--outdir)   OUTDIR="$2"; shift 2 ;;
	--manifest)    MODE="manifest"; shift ;;
	--kbuild)      MODE="kbuild"; shift ;;
	-h|--help)     usage; exit 0 ;;
	-*)            die "unknown option: $1 (try --help)" ;;
	*)
		# Positional version, for compatibility with the original
		# "mk-mlxsw-dkms.sh 6.1.177" invocation.
		[ -z "$VER" ] || die "version given twice: $VER and $1"
		VER="$1"; shift ;;
	esac
done

[ -r "$PARSER" ] || die "parser not found: $PARSER"

# ---------------------------------------------------------------- resolution
# Derive series from version when possible, then from the RUNNING KERNEL --
# never from a hardcoded default. This script runs in the build VM and on the
# switches, where the correct series is whatever that machine is running; a
# baked-in "6.1" silently pointed a trixie guest at a bookworm source tree.
if [ -z "$SERIES" ] && [ -n "$VER" ]; then
	SERIES="${VER%.*}"
fi
[ -n "$SERIES" ] || SERIES="$(uname -r | cut -d. -f1,2)"
[ -n "$SRC" ] || SRC="/usr/src/linux-source-$SERIES"

if [ -z "$MAKEFILE" ]; then
	MAKEFILE="$SRC/$MLXSW_SUBDIR/Makefile"
fi
[ -r "$MAKEFILE" ] || die "cannot read mlxsw Makefile: $MAKEFILE"

# Version, if still unknown, comes from the kernel tree's own Makefile.
if [ -z "$VER" ]; then
	if [ -r "$SRC/Makefile" ]; then
		_v=$(awk -F' = ' '/^VERSION /{v=$2} /^PATCHLEVEL /{p=$2} /^SUBLEVEL /{s=$2} END{print v"."p"."s}' "$SRC/Makefile")
		case "$_v" in
		[0-9]*.[0-9]*.[0-9]*) VER="$_v" ;;
		esac
	fi
fi
if [ -z "$VER" ] && [ "$MODE" = "build" ]; then
	die "cannot derive version from $SRC/Makefile -- pass --version"
fi

[ -n "$KCONFIG" ] || KCONFIG="/boot/config-$(uname -r)"

# ---------------------------------------------------------------- CONFIG resolution
pkg_macro() { # $1 = bare symbol -> prints the -D macro name, or nothing
	local e
	for e in "${PKG_CONFIG[@]}"; do
		[ "${e%%:*}" = "$1" ] && { printf '%s' "${e#*:}"; return 0; }
	done
	return 1
}

# Returns 0 when enabled, 1 when disabled. Exits 2 when the symbol is
# accounted for by neither source -- see the note in usage().
#
# Deliberately a RETURN CODE, not stdout. An earlier version printed "y"/"n"
# and was called as $(resolve_config ...), which put the fatal path inside a
# command substitution: `exit 2` killed only the subshell, the caller read an
# empty string, and the object was dropped in silence -- precisely the failure
# this function exists to prevent. Callers must use it as an `if` condition so
# that `set -e` does not turn "disabled" into an abort.
resolve_config() {
	local sym="$1"
	pkg_macro "$sym" >/dev/null && return 0
	if [ -r "$KCONFIG" ]; then
		grep -qE "^CONFIG_${sym}=[ym]$" "$KCONFIG" && return 0
		if grep -qE "^CONFIG_${sym}=" "$KCONFIG" ||
		   grep -qE "^# CONFIG_${sym} is not set$" "$KCONFIG"; then
			return 1
		fi
	fi
	cat >&2 <<-EOF
	error: CONFIG_${sym} is referenced by
	         $MAKEFILE
	       but is accounted for by neither source:
	         - not supplied by this package (see PKG_CONFIG in $0)
	         - not present in $KCONFIG$([ -r "$KCONFIG" ] || printf ' (unreadable)')
	       Refusing to guess. An absent symbol is NOT the same as a disabled
	       one: three of the four CONFIG symbols this Makefile tests are
	       absent from Debian's config by design, and treating absent as
	       disabled drops core_hwmon.o and core_thermal.o -- the fan and
	       thermal control -- with no error until modpost.
	       Add it to PKG_CONFIG, or point --config at the right kernel config.
	EOF
	exit 2
}

# ---------------------------------------------------------------- derivation
declare -a MODULES=()
declare -a LIB_EXTRA=()
declare -A OBJS=()
declare -A SEEN=()

derive() {
	local kind mod sym rhs obj macro
	while read -r kind rest; do
		case "$kind" in
		MOD)
			sym="${rest%% *}"; rhs="${rest#* }"
			if [ "$sym" != "-" ]; then
				if ! resolve_config "$sym"; then continue; fi
			fi
			for obj in $rhs; do
				mod="${obj%.o}"
				if [ -z "${SEEN[$mod]:-}" ]; then
					MODULES+=("$mod")
					SEEN[$mod]=1
					OBJS[$mod]="${OBJS[$mod]:-}"
				fi
			done
			;;
		BASE)
			mod="${rest%% *}"; rhs="${rest#* }"
			for obj in $rhs; do
				OBJS[$mod]="${OBJS[$mod]:-}${OBJS[$mod]:+ }${PREFIX}${obj}"
			done
			;;
		COND)
			mod="${rest%% *}"; rest="${rest#* }"
			sym="${rest%% *}"; rhs="${rest#* }"
			if ! resolve_config "$sym"; then continue; fi
			for obj in $rhs; do
				OBJS[$mod]="${OBJS[$mod]:-}${OBJS[$mod]:+ }${PREFIX}${obj}"
			done
			;;
		UNKNOWN)
			printf 'warning: unparsed line in %s: %s\n' "$MAKEFILE" "$rest" >&2
			;;
		esac
	done < <(awk -f "$PARSER" "$MAKEFILE")

	# A module with no -objs line is a single-object module named after
	# itself (objagg, parman, and anything upstream adds in that shape).
	local m
	for m in "${MODULES[@]}"; do
		[ -n "${OBJS[$m]:-}" ] || OBJS[$m]="${m}.o"
	done

	# The lib/ helpers are not in the mlxsw Makefile, so add them here --
	# unless they are already present, which is the case when we are
	# re-parsing a Kbuild this script generated. Without that guard the
	# round-trip test would report them twice and never converge.
	for m in "${LIB_MODULES[@]}"; do
		[ -n "${SEEN[$m]:-}" ] && continue
		LIB_EXTRA+=("$m")
		SEEN[$m]=1
		OBJS[$m]="${m}.o"
	done
}

# Every module the built package will contain, lib helpers first.
all_modules() {
	local m
	for m in ${LIB_EXTRA[@]+"${LIB_EXTRA[@]}"} ${MODULES[@]+"${MODULES[@]}"}; do
		printf '%s\n' "$m"
	done
}

# Canonical, order-independent view: one line per module, objects sorted.
# This is what the regression test diffs, so formatting changes are free and
# a changed object list is not.
emit_manifest() {
	local m
	for m in $(all_modules | sort); do
		printf '%s %s\n' "$m" "$(printf '%s\n' ${OBJS[$m]} | sort | tr '\n' ' ' | sed 's/ $//')"
	done
}

emit_kbuild() {
	local e m obj
	cat <<-'HEAD'
	# GENERATED by scripts/mk-mlxsw-dkms.sh -- do not edit by hand.
	# The object lists below are derived from the kernel's own mlxsw Makefile.
	#
	# CONFIG_MLXSW_* is absent from a stock Debian kernel's autoconf.h, so the
	# driver's IS_ENABLED() guards must be supplied here or the code silently
	# compiles itself out.
	HEAD
	printf 'ccflags-y += -I$(src)/include'
	for e in "${PKG_CONFIG[@]}"; do
		printf ' \\\n\t-D%s=1' "${e#*:}"
	done
	printf '\n\n'

	if [ ${#LIB_EXTRA[@]} -gt 0 ]; then
		printf '# lib/ helpers Debian does not build, because only mlxsw selects them\n'
		for m in "${LIB_EXTRA[@]}"; do
			printf 'obj-m += %s.o\n' "$m"
		done
	fi

	for m in "${MODULES[@]}"; do
		printf '\nobj-m += %s.o\n' "$m"
		# One object per line: when the list changes between kernel
		# series, the diff names the object instead of reflowing a
		# paragraph.
		printf '%s-objs := \\\n' "$m"
		local -a list=(${OBJS[$m]})
		local i n=${#list[@]}
		for ((i = 0; i < n; i++)); do
			if [ $((i + 1)) -lt "$n" ]; then
				printf '\t%s \\\n' "${list[$i]}"
			else
				printf '\t%s\n' "${list[$i]}"
			fi
		done
	done
}

emit_dkms_conf() {
	local m i=0
	cat <<-DKMSHEAD
	PACKAGE_NAME="mlxsw"
	PACKAGE_VERSION="$VER"
	AUTOINSTALL="yes"

	MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
	CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"

	DKMSHEAD
	# Derived from the module list, so a module upstream adds is packaged
	# without anyone remembering to extend this block.
	for m in $(all_modules); do
		printf 'BUILT_MODULE_NAME[%d]="%s"\nDEST_MODULE_LOCATION[%d]="/updates"\n' "$i" "$m" "$i"
		i=$((i + 1))
	done
}

derive

case "$MODE" in
manifest) emit_manifest; exit 0 ;;
kbuild)   emit_kbuild;   exit 0 ;;
esac

# ---------------------------------------------------------------- stage
PKGVER="${VER}-1"
STAGE="${STAGE:-/root/mlxsw-dkms-build}"
TREE="$STAGE/mlxsw-$VER"
[ -n "$OUTDIR" ] || OUTDIR="$STAGE"

[ -d "$SRC/$MLXSW_SUBDIR" ] || die "no mlxsw sources under $SRC -- is linux-source-$SERIES extracted?"

rm -rf "$STAGE"
mkdir -p "$TREE"/{mlxsw,mlxfw,include/linux,include/trace/events}

cp "$SRC/$MLXSW_SUBDIR"/*.[ch]                        "$TREE/mlxsw/"
cp "$SRC"/drivers/net/ethernet/mellanox/mlxfw/mlxfw.h "$TREE/mlxfw/"
cp "$SRC"/lib/objagg.c "$SRC"/lib/parman.c            "$TREE/"
cp "$SRC"/include/linux/objagg.h "$SRC"/include/linux/parman.h "$TREE/include/linux/"
cp "$SRC"/include/trace/events/objagg.h               "$TREE/include/trace/events/"

emit_kbuild     > "$TREE/Kbuild"
emit_dkms_conf  > "$TREE/dkms.conf"

# ---------------------------------------------------------------- .deb
DEB="$STAGE/deb"
mkdir -p "$DEB/DEBIAN" "$DEB/usr/src"
cp -a "$TREE" "$DEB/usr/src/"

cat > "$DEB/DEBIAN/control" <<CONTROL
Package: mlxsw-dkms
Version: $PKGVER
Section: kernel
Priority: optional
Architecture: all
Depends: dkms (>= 2.1.0.0)
Recommends: linux-headers-amd64
Maintainer: mlnx project <root@localhost>
Description: Mellanox Spectrum switch ASIC drivers (DKMS)
 Debian ships every dependency mlxsw needs but disables the driver itself
 (CONFIG_MLXSW_CORE is not set). This package rebuilds the mlxsw switchdev
 driver set, plus the objagg and parman lib helpers Debian omits, against
 whatever kernel apt installs -- so switch hardware keeps working across
 normal kernel upgrades without a forked kernel or a re-image.
 .
 Covers Spectrum-1/2/3/4 (SN2xxx, SN3xxx, SN4xxx).
CONTROL

cat > "$DEB/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    dkms add     -m mlxsw -v $VER || true
    dkms build   -m mlxsw -v $VER
    dkms install -m mlxsw -v $VER --force
    depmod -a
fi
POSTINST

cat > "$DEB/DEBIAN/prerm" <<PRERM
#!/bin/sh
set -e
dkms remove -m mlxsw -v $VER --all || true
PRERM

chmod 0755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/prerm"
mkdir -p "$OUTDIR"
dpkg-deb --build --root-owner-group "$DEB" "$OUTDIR/mlxsw-dkms_${PKGVER}_all.deb" >/dev/null

printf 'built: %s/mlxsw-dkms_%s_all.deb\n' "$OUTDIR" "$PKGVER"
printf 'modules (%d): %s\n' "$(all_modules | wc -l)" "$(all_modules | tr '\n' ' ')"
printf 'objects: %d\n' "$(emit_manifest | awk '{s += NF - 1} END {print s}')"
ls -la "$OUTDIR"/*.deb
