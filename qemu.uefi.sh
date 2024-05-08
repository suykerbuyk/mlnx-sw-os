#!/bin/sh
cp /usr/share/ovmf/x64/OVMF_VARS.fd /tmp/qemu-pxe-OVMF_VARS.fd
#qemu-kvm -cpu host -accel kvm \
qemu-system-x86_64 \
-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
-drive file=/usr/share/ovmf/x64/OVMF_VARS.fd,if=pflash,format=raw,unit=0,readonly=on \
-drive file=/tmp/qemu-pxe-OVMF_VARS.fd,if=pflash,format=raw,unit=1 \
-netdev user,id=net0,net=192.168.88.0/24,tftp=$HOME/configs/tftp/,bootfile=BOOTX64.EFI \
-device virtio-net-pci,netdev=net0 \
-object rng-random,id=virtio-rng0,filename=/dev/urandom \
-device virtio-rng-pci,rng=virtio-rng0,id=rng0,bus=pcie.0,addr=0x9 \
-nographic \
-serial stdio -boot n $@

