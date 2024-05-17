#!/bin/bash
set -e
cp tmux.conf /root/.tmux.conf
cp tmux.conf /home/alt/.tmux.conf
chown alt:alt /home/alt/.tmux.conf
cp termsize /usr/bin/
cp tm /usr/bin
chmod +x /usr/bin/tm
chmod +x /usr/bin/termsize

if [ ! -d /opt/packages ] ; then
	mkdir /opt/packages
	mv *.deb /opt/packages
	mv Pack* Release* /opt/packages/
fi

cat << EOF >/etc/apt/sources.list
deb [trusted=yes] file:/opt/packages/ ./

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
apt install -y vim rsync wget tmux patch smartmontools \
               bridge-utils ethtool isc-dhcp-client kitty-terminfo \
               sudo ntp ntp-doc ntpdate polkitd pkexec systemd-resolved \
               linux-headers-6.1.85-mlnx \
               linux-image-6.1.85-mlnx

apt-mark hold linux-image-6.1.85-mlnx linux-headers-6.1.85-mlnx

patch /etc/default/grub <grub.serial.patch
grub-mkconfig -o /boot/grub/grub.cfg
cp etc.udev.rules.d.10-local.rules /etc/udev/rules.d/10-local.rules
patch /etc/modules <sensor.modules.patch
mv /etc/network/interfaces /etc/network/interfaces.save
rsync -avr ./etc.systemd.network/ /etc/systemd/network/
apt autoremove -y
apt clean

systemctl enable systemd-networkd
systemctl enable systemd-resolved
