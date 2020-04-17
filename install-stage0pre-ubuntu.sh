#!/usr/bin/env bash

# This is meant to be run from a liveCD environment
# Onto a machine you want to dedicate the entire disk
# to Linux.  This will erase the entire disk.

# This will erase the entire disk

# This will erase the entire disk

# You've been warned.


apt-add-repository universe
apt update

apt install --yes debootstrap gdisk zfs-initramfs

DISK=${DISK:-"/dev/disk/by-id/scsi-SATA_disk1"}



