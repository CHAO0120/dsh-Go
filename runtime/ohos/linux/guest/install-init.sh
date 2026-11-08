#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
failed() { echo __DSH_INSTALL_FAILED__; while :; do sleep 3600; done; }
echo __DSH_INSTALL_BEGIN__
mount -t ext4 /dev/vdc /target || failed
tar xzf /dev/vdb -C /target || failed
echo __DSH_INSTALL_BASE__
tar xzf /dev/vdd -C /target || failed
echo __DSH_INSTALL_TOOLS__
mkdir -p /target/oldroot
mount --move /dev /target/dev || failed
umount /proc || failed
umount /sys || failed
cd /target || failed
pivot_root . oldroot || failed
exec /bin/sh -c 'umount /oldroot || { echo __DSH_INSTALL_FAILED__; while :; do sleep 3600; done; }; echo __DSH_INSTALL_PIVOT__; exec /sbin/dsh-init'
