#!/bin/env bash

LOCAL_IP="$(ip addr show br0 | grep '   inet ' | awk '{print $2}' | sed 's|/.*||g')"

OS_DISK_BIOS_IMG="switch_boot_bios.img"
OS_DISK_UEFI_IMG="switch_boot_uefi.img"
OS_INSTALL_ISO="/ark01/srv/os/linux/debian/iso/debian-12.5.0-amd64-STICK16GB-1.iso"

#printf 'REDACTED-CREDENTIAL' | mkpasswd2 -5 -s
PASSWD='REDACTED-CREDENTIAL'


BOOT_DRV_PARAMS="node-name=boot-drv,detect-zeroes=on,aio=io_uring,driver=raw,if=ide"
NET_BRG_PARAMS="bridge,id=net0"
NET_DEV_PARAMS="e1000,netdev=net0,mac=52:54:00:12:34:56"
UEFI_VARS_DRV="if=pflash,format=raw,file=${PWD}/OVMF_CODE.4m.fd"

#bash_var=$(tmux split-window -P -F "#{pane_id}")

#   -netdev user,id=eth0_net_dev \
#   -device virtio-net-pci,mac=50:54:00:00:00:42,netdev=eth0_net_dev,id=eth0_net_dev \

#    -netdev bridge,br=br0,id=n1 \
#    -device e1000,netdev=n1 \
#   -netdev bridge,id=n1 -device virtio-net,netdev=n1 \
#   -netdev tap,id=nd0,ifname=tap0 -device e1000,netdev=nd0 \
#   -smbios type=41,designation='Onboard LAN',instance=1,kind=ethernet,pcidev=net0 \


# This is used for the initial install
init_image_uefi() {
	OS_DISK_IMG="${OS_DISK_UEFI_IMG}"
	if [ ! -f ${OS_DISK_IMG} ] ; then
		echo "Creating UEFI OS install image file"
		truncate -s 0 ${OS_DISK_IMG}
		dd if=/dev/zero of=${OS_DISK_IMG} bs=1G count=8 oflag=sync
	fi
	qemu-system-x86_64 -machine type=q35 -m 8G \
		-drive "${BOOT_DRV_PARAMS},file=${OS_DISK_IMG}" \
		-netdev "${NET_BRG_PARAMS}" \
		-device "${NET_DEV_PARAMS}" \
		-drive "${UEFI_VARS_DRV}"   \
		-cdrom "${OS_INSTALL_ISO}"  \
		-append "interface=auto hostname=mlnx locale=en_US console=tty0 console=ttyS0,115200n8d net.ifnames=0" \
		-kernel assets/kernel/deb12.5/vmlinuz \
		-initrd assets/kernel/deb12.5/initrd.gz \
		-boot menu=on -nographic
}
init_image_bios() {
	OS_DISK_IMG="${OS_DISK_BIOS_IMG}"
	if [ ! -f ${OS_DISK_IMG} ] ; then
		echo "Creating BIOS install image file"
		truncate -s 0 ${OS_DISK_IMG}
		dd if=/dev/zero of=${OS_DISK_IMG} bs=1G count=8 oflag=sync
	fi
	qemu-system-x86_64 -machine type=q35 -m 8G \
		-drive  "${BOOT_DRV_PARAMS},file=${OS_DISK_IMG}" \
		-netdev "${NET_BRG_PARAMS}" \
		-device "${NET_DEV_PARAMS}" \
		-cdrom  "${OS_INSTALL_ISO}" \
		-boot menu=on
}
init_image_net_bios() {
	OS_DISK_IMG="${OS_DISK_BIOS_IMG}"
	if [ ! -f ${OS_DISK_IMG} ] ; then
		echo "Creating BIOS install image file"
		truncate -s 0 ${OS_DISK_IMG}
		dd if=/dev/zero of=${OS_DISK_IMG} bs=1G count=8 oflag=sync
	fi
	qemu-system-x86_64 -machine type=q35 -m 8G \
		-drive  "${BOOT_DRV_PARAMS},file=${OS_DISK_IMG}" \
		-netdev "${NET_BRG_PARAMS}" \
		-device "${NET_DEV_PARAMS}" \
		-cdrom  "${OS_INSTALL_ISO}" \
		-kernel assets/kernel/deb12.5/linux     \
		-initrd assets/kernel/deb12.5/initrd.gz \
		-append "auto=false DEBCONF_DEBUG=5 url=http://${LOCAL_IP}:8080/selections.txt checksum=d6b583e85d1617a43adfa3b0bbcf8501 interface=auto hostname=deb12mlnx locale=en_US console=tty0 console=ttyS0,115200n8d net.ifnames=0" \
		-boot menu=on -nographic
}


#-display none -chardev stdio,id=char0,logfile=serial.log,signal=off -serial chardev:char0
run_image_uefi() {
	OS_DISK_IMG="${OS_DISK_UEFI_IMG}"
	qemu-system-x86_64 -machine type=q35 -m 8G \
		-drive  "${BOOT_DRV_PARAMS},file=${OS_DISK_IMG}" \
		-netdev "${NET_BRG_PARAMS}" \
		-device "${NET_DEV_PARAMS}" \
		-drive  "${UEFI_VARS_DRV}"  \
		-boot menu=on -nographic
}
run_image_bios() {
	OS_DISK_IMG="${OS_DISK_BIOS_IMG}"
	qemu-system-x86_64 -machine type=q35 -m 8G \
		-drive  "${BOOT_DRV_PARAMS},file=${OS_DISK_IMG}" \
		-netdev "${NET_BRG_PARAMS}" \
		-device "${NET_DEV_PARAMS}" \
		-boot menu=on
}
#init_image_bios
#init_image_net_bios
#run_image_bios
#init_image_uefi
run_image_uefi


# Things to install:
# apt install vim curl wget rsync tmux sudo patch kitty-terminfo psmisc ifstat ethtool lm-sensors debconf-utils
# ssh-keygen -t ed24419
# adduser alt/REDACTED-CREDENTIAL
# cat /etc/sudoers.d/alt
#    alt  ALL=(ALL) NOPASSWD: ALL
#
# patch /etc/default/grub <grub.serial.patch
# update-grub
#
# Fixing up 512G disk after DD
# sgdisk -p /dev/sdg # note begining of second partition!!!
# sgdisk -d 3 /dev/sdg #delete swap - but after removing from /etc/fstab!
# sgdisk -p /dev/sdg # verify
# sgdisk -d 2 /dev/sdg  # remove second partition
# sgdisk -n 2:1050624:+470G /dev/sdg  # Re-add second partition
# sgdisk -p /dev/sdg # verify
# sgdisk -n 3 -t3:8200 /dev/sdg # create 3rd partition for swap.
# sgdisk -p /dev/sdg # verify

# root@deb12mlnx:~# cat /etc/udev/rules.d/10-local.rules
# SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlxsw_spectrum*", \
#    NAME="sw$attr{phys_port_name}"

##Resizing bios partitions 
# ONE_MB="1048576"
# ONE_GB="1073741824"
# ONE_TB="1099511627776"
# CAPACITY=$(lsblk --list -b /dev/sda | grep -E "sda " | awk '{print $4}')
# CAPACITY_MB="$((CAPACITY/1024/1024))"
#
# Turn off swap:
#   sed 's/^[^#]*swap/#&/' -i /etc/fstab
#   swapoff -a
# rm 5
# rm 2
#
echo "Note: After removing and replacing the swap partition to resize the root partition,"
echo "One must either assign the same UUID to new partition or regenerate initramfs"
echo "See: https://www.debian.org/doc/manuals/debian-kernel-handbook/ch-initramfs.html"
