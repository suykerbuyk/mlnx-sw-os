#!/bin/bash
set -e
cp tmux.conf /root/.tmux.conf
cp tmux.conf /home/alt/.tmux.conf
chown alt:alt /home/alt/.tmux.conf
cp termsize /usr/bin/
cp tm /usr/bin
chmod +x /usr/bin/tm
chmod +x /usr/bin/termsize

cat << EOF >/etc/apt/sources.list
deb [trusted=yes] file:/root/assets ./

deb http://deb.debian.org/debian/ bookworm main non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main non-free-firmware

# bookworm-updates, to get updates before a point release is made;
# see https://www.debian.org/doc/manuals/debian-reference/ch02.en.html#_updates_and_backports
deb http://deb.debian.org/debian/ bookworm-updates main non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main non-free-firmware
EOF

apt update
apt install -y vim rsync wget ifupdown2 tmux patch smartmontools \
               bridge-utils ethtool isc-dhcp-client 

patch /etc/default/grub <grub.serial.patch
patch /etc/network/interfaces <etc.network.interfaces.patch
cp etc.udev.rules.d.10-local.rules /etc/udev/rules.d/10-local.rules
patch /etc/modules <sensor.modules.patch

apt install -y \
	linux-headers-6.1.85-mlnx_6.1.85-mlnx-5_amd64.deb \
	linux-image-6.1.85-mlnx_6.1.85-mlnx-5_amd64.deb \
	linux-libc-dev_6.1.85-mlnx-5_amd64.deb \
	./linux-headers-*.deb ./linux-image-*mlnx_*.deb

echo "linux-headers-6.1.85-mlnx_6.1.85-mlnx-5_amd64.deb install" | dpkg --set-selections
echo "linux-image-6.1.85-mlnx_6.1.85-mlnx-5_amd64.deb install" | dpkg --set-selections
echo "linux-libc-dev_6.1.85-mlnx-5_amd64.deb install" | dpkg --set-selections
