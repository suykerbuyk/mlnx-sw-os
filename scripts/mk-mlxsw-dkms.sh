#!/bin/bash
# Build an mlxsw-dkms source package + .deb from Debian's own linux-source.
#
# Layout note: mlxsw does #include "../mlxfw/mlxfw.h", so the driver sources
# live in a mlxsw/ subdirectory with a sibling mlxfw/ holding just that header.
# That satisfies the relative include with ZERO source modification.
set -e

SRC=/usr/src/linux-source-6.1
VER="${1:-6.1.177}"
PKGVER="${VER}-1"
STAGE=/root/mlxsw-dkms-build
TREE="$STAGE/mlxsw-$VER"

rm -rf "$STAGE"
mkdir -p "$TREE"/{mlxsw,mlxfw,include/linux,include/trace/events}

cp "$SRC"/drivers/net/ethernet/mellanox/mlxsw/*.[ch]  "$TREE/mlxsw/"
cp "$SRC"/drivers/net/ethernet/mellanox/mlxfw/mlxfw.h "$TREE/mlxfw/"
cp "$SRC"/lib/objagg.c "$SRC"/lib/parman.c            "$TREE/"
cp "$SRC"/include/linux/objagg.h "$SRC"/include/linux/parman.h "$TREE/include/linux/"
cp "$SRC"/include/trace/events/objagg.h               "$TREE/include/trace/events/"

# ---------------------------------------------------------------- Kbuild
cat > "$TREE/Kbuild" <<'KBUILD'
# CONFIG_MLXSW_* is absent from a stock Debian kernel's autoconf.h, so the
# driver's IS_ENABLED() guards must be supplied here or the code silently
# compiles itself out.
ccflags-y += -I$(src)/include \
	-DCONFIG_MLXSW_CORE_MODULE=1 \
	-DCONFIG_MLXSW_PCI_MODULE=1 \
	-DCONFIG_MLXSW_I2C_MODULE=1 \
	-DCONFIG_MLXSW_SPECTRUM_MODULE=1 \
	-DCONFIG_MLXSW_MINIMAL_MODULE=1 \
	-DCONFIG_MLXSW_CORE_HWMON=1 \
	-DCONFIG_MLXSW_CORE_THERMAL=1 \
	-DCONFIG_MLXSW_SPECTRUM_DCB=1 \
	-DCONFIG_OBJAGG_MODULE=1 \
	-DCONFIG_PARMAN_MODULE=1

# lib/ helpers Debian does not build, because only mlxsw selects them
obj-m += objagg.o
obj-m += parman.o

obj-m += mlxsw_core.o
mlxsw_core-objs := mlxsw/core.o mlxsw/core_acl_flex_keys.o \
	mlxsw/core_acl_flex_actions.o mlxsw/core_env.o \
	mlxsw/core_linecards.o mlxsw/core_linecard_dev.o \
	mlxsw/core_hwmon.o mlxsw/core_thermal.o

obj-m += mlxsw_pci.o
mlxsw_pci-objs := mlxsw/pci.o

obj-m += mlxsw_i2c.o
mlxsw_i2c-objs := mlxsw/i2c.o

obj-m += mlxsw_minimal.o
mlxsw_minimal-objs := mlxsw/minimal.o

obj-m += mlxsw_spectrum.o
mlxsw_spectrum-objs := mlxsw/spectrum.o mlxsw/spectrum_buffers.o \
	mlxsw/spectrum_switchdev.o mlxsw/spectrum_router.o \
	mlxsw/spectrum1_kvdl.o mlxsw/spectrum2_kvdl.o mlxsw/spectrum_kvdl.o \
	mlxsw/spectrum_acl_tcam.o mlxsw/spectrum_acl_ctcam.o \
	mlxsw/spectrum_acl_atcam.o mlxsw/spectrum_acl_erp.o \
	mlxsw/spectrum1_acl_tcam.o mlxsw/spectrum2_acl_tcam.o \
	mlxsw/spectrum_acl_bloom_filter.o mlxsw/spectrum_acl.o \
	mlxsw/spectrum_flow.o mlxsw/spectrum_matchall.o \
	mlxsw/spectrum_flower.o mlxsw/spectrum_cnt.o \
	mlxsw/spectrum_fid.o mlxsw/spectrum_ipip.o \
	mlxsw/spectrum_acl_flex_actions.o mlxsw/spectrum_acl_flex_keys.o \
	mlxsw/spectrum1_mr_tcam.o mlxsw/spectrum2_mr_tcam.o \
	mlxsw/spectrum_mr_tcam.o mlxsw/spectrum_mr.o \
	mlxsw/spectrum_qdisc.o mlxsw/spectrum_span.o \
	mlxsw/spectrum_nve.o mlxsw/spectrum_nve_vxlan.o \
	mlxsw/spectrum_dpipe.o mlxsw/spectrum_trap.o \
	mlxsw/spectrum_ethtool.o mlxsw/spectrum_policer.o \
	mlxsw/spectrum_pgt.o mlxsw/spectrum_dcb.o mlxsw/spectrum_ptp.o
KBUILD

# ---------------------------------------------------------------- dkms.conf
cat > "$TREE/dkms.conf" <<DKMSCONF
PACKAGE_NAME="mlxsw"
PACKAGE_VERSION="$VER"
AUTOINSTALL="yes"

MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"

BUILT_MODULE_NAME[0]="objagg"
DEST_MODULE_LOCATION[0]="/updates"
BUILT_MODULE_NAME[1]="parman"
DEST_MODULE_LOCATION[1]="/updates"
BUILT_MODULE_NAME[2]="mlxsw_core"
DEST_MODULE_LOCATION[2]="/updates"
BUILT_MODULE_NAME[3]="mlxsw_pci"
DEST_MODULE_LOCATION[3]="/updates"
BUILT_MODULE_NAME[4]="mlxsw_i2c"
DEST_MODULE_LOCATION[4]="/updates"
BUILT_MODULE_NAME[5]="mlxsw_minimal"
DEST_MODULE_LOCATION[5]="/updates"
BUILT_MODULE_NAME[6]="mlxsw_spectrum"
DEST_MODULE_LOCATION[6]="/updates"
DKMSCONF

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
dpkg-deb --build --root-owner-group "$DEB" "$STAGE/mlxsw-dkms_${PKGVER}_all.deb" >/dev/null

echo "built: $STAGE/mlxsw-dkms_${PKGVER}_all.deb"
ls -la "$STAGE"/*.deb
