#!/usr/bin/env bash

# Install with the following command
# bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/prepare.sh)"

# set -e
set -u
# set -o pipefail

export TARGET_USER
export SSID
export WPA_PASSPHRASE
export HOSTNAME
export INSTALLER=${INSTALLER:-arch}
export SWAPSIZE=${SWAPSIZE:-64}
export DOTFILESBRANCH=${DOTFILESBRANCH:-main}
export INSTALLER=${INSTALLER:-arch}
export DISK=CHANGE_ME

echo "* Validating system was booted in UEFI mode"
if [ ! -d "/sys/firmware/efi" ]; then
  echo "ERROR: Please reboot in UEFI mode."
  exit 1
fi

echo "* Setting system time"
systemctl start systemd-timesyncd

echo "* Checking installer scripts"
if [ ! -f ./install-stage0.sh ]; then
  curl -sLo install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/prepare-${INSTALLER}.sh
  chmod 755 install-stage0.sh
fi

echo "* Running stage0 prepare.  You will be prompted for zfs passphrase and user password"

./install-stage0.sh prepare | tee prepare.log

echo "* Reboot into the system"
