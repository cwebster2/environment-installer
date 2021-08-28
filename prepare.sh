#!/usr/bin/env bash

# Install with the following command
# bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/prepare.sh)"
# This assumes you already have a working OS and user created

set -e
set -u
set -o pipefail

export TARGET_USER
export INSTALLER=${INSTALLER:-arch}
export SWAPSIZE=${SWAPSIZE:-32}
export SSID
export WPA_PASSPHRASE
export HOSTNAME

echo "* Validating system was booted in UEFI mode"
if [ ! -d "/sys/firmware/efi" ]; then
  echo "ERROR: Please reboot in UEFI mode."
  exit 1
fi

echo "* Setting system time"
systemctl start systemd-timesyncd

echo "* Getting installer scripts"
curl -sLo install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-${INSTALLER}.sh
chmod 755 install-stage0.sh

echo "* Running stage0 prepare.  You will be prompted for zfs passphrase and user password"

./install-stage0.sh prepare

echo "* Cleaning up and rebooting the system"
rm install-stage0.sh

cat <<-EOF > "/home/${TARGET_USER}/.zshrc
export INSTALLER=${INSTALLER}
./install.sh
EOF

reboot
