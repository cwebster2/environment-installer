#!/usr/bin/env bash

# Install with the following command
# bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-focal.sh)"
# This assumes you are in a livecd environment and want to provision an entire disk to ubuntu

HOSTNAME="caseybook"
DISK="/dev/disk/by-id/scsi-SATA_disk1"
RELEASE="focal"
DISTRO="ubuntu"
DOTFILESBRANCH="razer-ubuntu"
SWAPSIZE="1G"
TZONE="America/Chicago"
TARGET_USER="casey"

wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0pre-ubuntu.sh > install-focal.sh
chmod 755 install-focal.sh
./install-focal.sh
