#!/usr/bin/env bash

# Install with the following command
# DOTFILESBRANCH=master INSTALLER=debian bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install.sh)"
# This assumes you already have a working OS and user created

set -e
set -o pipefail

export TARGET_USER=$(whoami)
export DOTFILESBRANCH=${DOTFILESBRANCH:-main}
export INSTALLER=${INSTALLER:-arch}
export GRAPHICS=${GRAPHICS:-intel}


echo "* Getting installer scripts"
curl -sLo install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-${INSTALLER}.sh
curl -sLo install-stage1.sh https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install-env

chmod 755 install-stage0.sh install-stage1.sh

echo "* Running stage0 requires sudo, you will be prompted for your password"

sudo ./install-stage0.sh base
sudo ./install-stage0.sh wm
sudo ./install-stage0.sh games
sudo ./install-stage0.sh laptop

echo "* Installing dotfiles"

./install-stage1.sh dotfiles

echo "* Initializing user environment"

cat <<"EOF" | zsh -i -s
./install-stage1.sh tools
./install-stage1.sh vim
./install-stage1.sh emacs
EOF

echo "* Cleaning up"

rm install.sh install-stage0.sh install-stage1.sh

echo "* Done!, Rebooting"

sudo reboot
