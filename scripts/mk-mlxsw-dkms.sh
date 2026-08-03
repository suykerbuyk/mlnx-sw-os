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
RESTAMP_IN=""
RESTAMP_TMP=""

# Distribution identity. NONE of this comes from `uname -r`: the running
# kernel names a build target, never a suite. A 6.1 kernel booted on a trixie
# rescue system is still trixie, and a mounted foreign source tree has no
# opinion at all about which Debian released it.
OS_RELEASE="/etc/os-release"
SUITE=""
SUITE_TAG=""
# Explicit-intent flags. An operator who states the suite, the suite tag, or
# the series is not second-guessed by the cross-check below.
OS_RELEASE_SET=0
SUITE_SET=0
SUITE_TAG_SET=0
SERIES_SET=0

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
  -o, --outdir DIR     where to leave the built .deb (default: the stage dir,
                       or the input package's directory under --restamp)

      --os-release F   read distribution identity from F
                       (default: /etc/os-release)
      --suite NAME     suite name, e.g. trixie -- bypasses derivation
      --suite-tag TAG  version suffix, e.g. +deb13u1 -- bypasses derivation

      --manifest       print the derived object manifest and exit
      --kbuild         print the derived Kbuild and exit
      --control        print the DEBIAN/control file and exit (needs
                       --version; reads no source tree)
      --restamp DEB    rebuild DEB with a fresh control file and
                       README.Debian under the new version, payload
                       untouched, and exit
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
	-S|--series)   SERIES="$2"; SERIES_SET=1; shift 2 ;;
	-v|--version)  VER="$2"; shift 2 ;;
	-c|--config)   KCONFIG="$2"; shift 2 ;;
	-m|--makefile) MAKEFILE="$2"; shift 2 ;;
	-p|--prefix)   PREFIX="$2"; shift 2 ;;
	-o|--outdir)   OUTDIR="$2"; shift 2 ;;
	--os-release)  OS_RELEASE="$2"; OS_RELEASE_SET=1; shift 2 ;;
	--suite)       SUITE="$2"; SUITE_SET=1; shift 2 ;;
	--suite-tag)   SUITE_TAG="$2"; SUITE_TAG_SET=1; shift 2 ;;
	--manifest)    MODE="manifest"; shift ;;
	--kbuild)      MODE="kbuild"; shift ;;
	--control)     MODE="control"; shift ;;
	--restamp)     MODE="restamp"; RESTAMP_IN="$2"; shift 2 ;;
	-h|--help)     usage; exit 0 ;;
	-*)            die "unknown option: $1 (try --help)" ;;
	*)
		# Positional version, for compatibility with the original
		# "mk-mlxsw-dkms.sh 6.1.177" invocation.
		[ -z "$VER" ] || die "version given twice: $VER and $1"
		VER="$1"; shift ;;
	esac
done

# ---------------------------------------------------------------- resolution
# --control and --restamp read no kernel source at all, so they must not be
# held to a readable Makefile or a present awk parser.
case "$MODE" in
control|restamp) NEEDS_SOURCE=0 ;;
*)               NEEDS_SOURCE=1 ;;
esac

if [ "$NEEDS_SOURCE" -eq 1 ]; then
	[ -r "$PARSER" ] || die "parser not found: $PARSER"

	# Derive series from version when possible, then from the RUNNING
	# KERNEL -- never from a hardcoded default. This script runs in the
	# build VM and on the switches, where the correct series is whatever
	# that machine is running; a baked-in "6.1" silently pointed a trixie
	# guest at a bookworm source tree.
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

	# Series again, now that --version may have filled VER in from the
	# tree. The source tree's own vintage is what the cross-check below
	# weighs against the running kernel's.
	if [ "$SERIES_SET" -eq 0 ] && [ -n "$VER" ]; then
		SERIES="${VER%.*}"
	fi

	[ -n "$KCONFIG" ] || KCONFIG="/boot/config-$(uname -r)"
fi

# ---------------------------------------------------------------- identity
# Read one key out of an os-release file WITHOUT sourcing it.
#
# os-release is shell syntax by specification, but --os-release points at an
# arbitrary path, and a plain `.` of that path would let the file assign
# SERIES, VER, PKGVER or OUTDIR behind this script's back -- silently
# repackaging the wrong tree under the wrong name. Parsing keeps it a data
# file. Quotes (either kind) are stripped; nothing is evaluated.
os_release_get() { # $1 = key, $2 = file -> prints value, empty if absent
	[ -r "$2" ] || return 1
	awk -v k="$1" '
		/^[[:space:]]*#/ { next }
		{
			eq = index($0, "=")
			if (eq == 0) next
			key = substr($0, 1, eq - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			if (key != k) next
			val = substr($0, eq + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			f = substr(val, 1, 1); l = substr(val, length(val), 1)
			if (length(val) >= 2 && f == l && (f == "\"" || f == "\047"))
				val = substr(val, 2, length(val) - 2)
			print val
			exit
		}' "$2"
}

# Suite name and version suffix, per the ruled derivation:
#
#   suite = VERSION_CODENAME, else VERSION_ID, else BUILD_ID, else "unknown"
#
# The fallback chain exists because rolling distributions (this build host is
# Arch) carry no VERSION_CODENAME and no VERSION_ID at all.
derive_suite() {
	local id vid cn bid
	[ "$SUITE_SET" -eq 1 ] && [ "$SUITE_TAG_SET" -eq 1 ] && return 0

	if [ ! -r "$OS_RELEASE" ]; then
		printf 'warning: cannot read %s -- no suite identity derived\n' \
			"$OS_RELEASE" >&2
		[ "$SUITE_SET" -eq 1 ] || SUITE="unknown"
		return 0
	fi

	id=$(os_release_get ID "$OS_RELEASE" || true)
	cn=$(os_release_get VERSION_CODENAME "$OS_RELEASE" || true)
	vid=$(os_release_get VERSION_ID "$OS_RELEASE" || true)
	bid=$(os_release_get BUILD_ID "$OS_RELEASE" || true)

	[ "$SUITE_SET" -eq 1 ] || SUITE="${cn:-${vid:-${bid:-unknown}}}"

	if [ "$SUITE_TAG_SET" -eq 0 ]; then
		# +debNuM is a Debian convention and only a Debian convention.
		# Stamping it onto anything else would assert a provenance the
		# package does not have, so emit nothing and say so.
		if [ "$id" = "debian" ] && [ -n "$vid" ]; then
			SUITE_TAG="+deb${vid}u1"
		else
			SUITE_TAG=""
			printf 'warning: %s reports ID=%s (not debian) -- no +debNuM version suffix; pass --suite-tag to set one\n' \
				"$OS_RELEASE" "${id:-<unset>}" >&2
		fi
	fi
	return 0
}

# The suite label comes from the HOST's os-release; the source tree being
# packaged comes from wherever --src points. Nothing connects the two, so a
# build against a mounted foreign tree happily stamps the host's suite onto
# someone else's kernel vintage: a package named +deb13u1 carrying 6.1
# sources, or a bookworm-labelled package carrying 6.12.
#
# The running kernel's series is the one honest witness available to the
# derivation: the host whose os-release we just read is booted on it. So the
# assertion is table-free -- compare the packaged tree's series against the
# running kernel's series, and demand an explicit acknowledgement when they
# differ. No suite->series map to go stale, and it stays correct for kernel
# series that do not exist yet.
#
# The comparison is on the SERIES, not the full version, and that is what keeps
# it quiet in normal use. The routine case on this project -- the trixie base
# ships 6.12.96 while the archive is at 6.12.100, so you `apt full-upgrade`
# before building -- leaves both sides at 6.12 and does NOT fire, rebooted or
# not. Only a series bump (6.1 vs 6.12) trips it, i.e. a Debian major
# dist-upgrade before reboot, which is exactly the case worth stopping on. Do
# not weaken this check on the belief that it is noisy; measure first.
check_series_against_host() {
	local host
	# An operator who states the identity has already made the call.
	if [ "$SERIES_SET" -eq 1 ] || [ "$SUITE_SET" -eq 1 ] || [ "$SUITE_TAG_SET" -eq 1 ]; then
		return 0
	fi
	# With a foreign os-release the running kernel is, by construction,
	# not a witness for it. Warn rather than assert on a false premise.
	if [ "$OS_RELEASE_SET" -eq 1 ]; then
		printf 'warning: --os-release given; skipping the source-tree/running-kernel series cross-check\n' >&2
		return 0
	fi
	host="$(uname -r | cut -d. -f1,2)"
	case "$host" in
	[0-9]*.[0-9]*) ;;
	*)  printf 'warning: cannot read a kernel series out of "%s" -- skipping the series cross-check\n' \
			"$(uname -r)" >&2
	    return 0 ;;
	esac
	[ "$host" = "$SERIES" ] && return 0

	die "$(cat <<-MSG
	source tree is Linux $SERIES but this host is running $host.
	           tree:  $SRC
	           suite: ${SUITE:-unknown}  (derived from $OS_RELEASE)
	       The suite label is derived from THIS host, so building a foreign
	       source tree here stamps this host's distribution onto someone
	       else's kernel vintage -- here, a package labelled
	       "${SUITE:-unknown}"${SUITE_TAG:+ / \"$SUITE_TAG\"} carrying Linux $SERIES sources.
	       Refusing to guess which of the two is wrong.
	       If this is deliberate, say so: pass --suite / --suite-tag (to name
	       the distribution the tree really belongs to) or --series (to
	       confirm the tree's vintage).
	MSG
	)"
}

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

# The ONE writer of DEBIAN/control. Both the from-source build path and the
# --restamp path call this, so a generated package and a re-stamped one cannot
# drift apart in their dependencies -- which is the whole point, because the
# Depends line below is the only thing standing between an operator and a
# switch that boots with no data plane.
#
# Three rules are encoded here and none of them are stylistic:
#
#  * build-essential is a HARD dependency, not a Recommends. Debian's dkms
#    package carries "gcc | c-compiler" in Recommends, not Depends
#    (trixie: Depends: kmod, dpkg-dev, make | build-essential, patch). So
#    `apt install --no-install-recommends ./mlxsw-dkms.deb` resolves cleanly
#    and then fails in postinst with no compiler -- no ports, no warning.
#
#  * linux-headers-amd64 stays the METAPACKAGE. Never linux-headers-$(uname -r).
#    The metapackage tracks linux-image-amd64, so headers land in the SAME apt
#    transaction as a new kernel; that is precisely what lets DKMS rebuild
#    unattended. Pinning it to a running kernel reproduces "boots with zero
#    modules" at the next upgrade.
#
#  * ">= 6.12" is a FLOOR and there must NEVER be a ceiling. Headers only move
#    up, so a floor is stable forever; a "<<" upper bound breaks
#    self-maintenance at the next kernel series bump, and it breaks it by
#    making apt REMOVE this package. The floor also does real work today: it
#    makes a hand-copied trixie .deb refuse to install on the two live
#    bookworm switches, whose linux-headers-amd64 is 6.1.177-1. Hand-copy is
#    how both were installed, so that path is not hypothetical.
emit_control() {
	cat <<CONTROL
Package: mlxsw-dkms
Version: $PKGVER
Section: kernel
Priority: optional
Architecture: all
Depends: dkms (>= 2.1.0.0), build-essential, linux-headers-amd64 (>= 6.12)
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
}

# emit_control()'s sibling: the same reasoning, addressed to whoever is
# standing in front of a switch mid-upgrade with no checkout of this repo.
# Quoted heredoc on purpose -- $(uname -r) must reach the file literally.
emit_readme() {
	cat <<'README'
mlxsw-dkms
==========

This is a DKMS package. It ships the mlxsw switchdev driver sources, not
prebuilt modules, and rebuilds them against whatever kernel apt installs.
That rebuild is what keeps the switch ports alive across an ordinary kernel
upgrade.

Why the headers dependency looks the way it does
------------------------------------------------
The dependency is on the METAPACKAGE linux-headers-amd64, deliberately. That
metapackage tracks linux-image-amd64, so the matching headers arrive in the
SAME apt transaction as a new kernel and DKMS can rebuild before you reboot
into it.

Do not "tighten" it to linux-headers-$(uname -r), or to any exact version.
A versioned headers dependency means the next kernel shows up with no headers,
DKMS builds nothing, and the switch comes back with no mlxsw modules and
therefore no ports.

For the same reason the "(>= 6.12)" is a FLOOR and there is deliberately no
upper bound. Headers only ever move up. A ceiling would make apt REMOVE this
package at the next kernel series bump -- the same dead switch, arrived at
politely.

Do not install this on a pre-trixie system
------------------------------------------
These sources are Debian 13 (trixie) / Linux 6.12 vintage. The
linux-headers-amd64 (>= 6.12) floor makes dpkg refuse this package on
Debian 12 (bookworm), whose linux-headers-amd64 is 6.1.177-1. That refusal is
the feature, not an obstacle: installing it there gives you a switch that
boots with no mlxsw modules and no ports. Hand-copying the .deb between
machines is how these actually get installed, so this is a real path.

If the modules go missing after a kernel upgrade
------------------------------------------------
    dkms status
    dkms autoinstall
    modprobe mlxsw_spectrum
    ls /lib/modules/$(uname -r)/updates/dkms/mlxsw*

NOTE: on trixie the modules are installed COMPRESSED, as .ko.xz, not plain
.ko. Any glob you write must be mlxsw*.ko* -- something looking for a bare
*.ko will report the modules missing while they are present and loaded.
README
}

# ---------------------------------------------------------------- restamp
# Re-cut an existing .deb under a new version, replacing ONLY DEBIAN/control
# and README.Debian. The payload is carried across untouched, which is the
# entire point: this corrects metadata on a package whose sources were already
# built and proven, without reopening the build.
do_restamp() {
	local in="$1" pkg out in_ver up_ver s
	[ -n "$in" ]  || die "--restamp needs a .deb path"
	[ -r "$in" ]  || die "cannot read package: $in"
	command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found"

	in_ver="$(dpkg-deb -f "$in" Version)"
	[ -n "$in_ver" ] || die "no Version field in $in"
	up_ver="${in_ver%%-*}"          # 6.12.100-1 -> 6.12.100
	[ -n "$VER" ] || VER="$up_ver"

	derive_suite
	PKGVER="${VER}-1${SUITE_TAG}"
	[ "$PKGVER" != "$in_ver" ] || die "restamped version is identical to the input's ($in_ver) -- refusing to overwrite in place"

	# Global, not local: the EXIT trap runs after this function's locals
	# have gone out of scope, and under `set -u` a trap referring to a
	# dead local aborts the script AFTER the package was written -- an
	# exit 1 on a run that actually succeeded.
	RESTAMP_TMP="$(mktemp -d)"
	trap 'rm -rf "$RESTAMP_TMP"' EXIT
	pkg="$RESTAMP_TMP/pkg"
	dpkg-deb -R "$in" "$pkg"

	# The maintainer scripts hardcode the UPSTREAM version (dkms -v), not
	# the Debian revision, so re-stamping the revision leaves them correct.
	# That is a property of these particular scripts, not a law -- verify
	# it rather than assume it, because silently shipping a postinst that
	# names a version DKMS does not have is a switch with no modules.
	for s in postinst prerm postrm preinst; do
		[ -f "$pkg/DEBIAN/$s" ] || continue
		if grep -qF -- "$in_ver" "$pkg/DEBIAN/$s"; then
			die "DEBIAN/$s in $in references the full Debian version '$in_ver'. Re-stamping would leave it stale, and editing maintainer scripts is out of scope for --restamp. Rebuild from source instead."
		fi
		grep -qF -- "$up_ver" "$pkg/DEBIAN/$s" ||
			printf 'warning: DEBIAN/%s does not mention the upstream version %s\n' "$s" "$up_ver" >&2
	done

	emit_control > "$pkg/DEBIAN/control"
	mkdir -p "$pkg/usr/share/doc/mlxsw-dkms"
	emit_readme > "$pkg/usr/share/doc/mlxsw-dkms/README.Debian"
	chmod 0644 "$pkg/usr/share/doc/mlxsw-dkms/README.Debian"

	[ -n "$OUTDIR" ] || OUTDIR="$(cd -- "$(dirname -- "$in")" && pwd)"
	mkdir -p "$OUTDIR"
	out="$OUTDIR/mlxsw-dkms_${PKGVER}_all.deb"
	dpkg-deb --build --root-owner-group "$pkg" "$out" >/dev/null

	printf 'restamped: %s\n' "$in"
	printf '       ->: %s\n' "$out"
	printf '   version: %s -> %s (upstream %s unchanged)\n' "$in_ver" "$PKGVER" "$up_ver"
	printf '     suite: %s   tag: %s\n' "${SUITE:-unknown}" "${SUITE_TAG:-<none>}"
}

case "$MODE" in
manifest) derive; emit_manifest; exit 0 ;;
kbuild)   derive; emit_kbuild;   exit 0 ;;
control)
	[ -n "$VER" ] || die "--control needs --version (this mode reads no source tree)"
	derive_suite
	PKGVER="${VER}-1${SUITE_TAG}"
	emit_control
	exit 0 ;;
restamp)
	do_restamp "$RESTAMP_IN"
	exit 0 ;;
esac

derive

# ---------------------------------------------------------------- stage
derive_suite
check_series_against_host
PKGVER="${VER}-1${SUITE_TAG}"
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

emit_control > "$DEB/DEBIAN/control"

mkdir -p "$DEB/usr/share/doc/mlxsw-dkms"
emit_readme > "$DEB/usr/share/doc/mlxsw-dkms/README.Debian"
chmod 0644 "$DEB/usr/share/doc/mlxsw-dkms/README.Debian"

# NOTE: the maintainer scripts below name the UPSTREAM version ($VER), never
# $PKGVER. --restamp depends on that: it rewrites only the Debian revision, so
# these stay correct without being touched. Keep it that way.
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
