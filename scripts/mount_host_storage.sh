#!/bin/bash
# Clears Windows Fast Startup flags and mounts /dev/sda2 persistently via UUID
set -e

PARTITION="/dev/sda2"
MOUNT_POINT="/mnt/shared_data"

sudo umount $PARTITION 2>/dev/null || true
sudo ntfsfix -d $PARTITION
sudo mkdir -p $MOUNT_POINT

UUID=$(sudo blkid -s UUID -o value$PARTITION)
echo "UUID=${UUID}${MOUNT_POINT}  ntfs-3g  uid=1000,gid=1000,umask=0022,nofail  0  0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
mkdir -p ${MOUNT_POINT}/VMs${MOUNT_POINT}/ISOs
