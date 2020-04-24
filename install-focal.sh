#!/usr/bin/env bash

# Install with the following command
# bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-focal.sh)"
# This assumes you are in a livecd environment and want to provision an entire disk to ubuntu

export HOSTNAME="caseybook"
export DISK="/dev/disk/by-id/scsi-SATA_disk1"
export RELEASE="focal"
export DISTRO="ubuntu"
export DOTFILESBRANCH="razer-ubuntu"
export SWAPSIZE="1G"
export TZONE="America/Chicago"
export TARGET_USER="casey"

wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0pre-ubuntu.sh > install-focal.sh
chmod 755 install-focal.sh
sudo -E ./install-focal.sh init
