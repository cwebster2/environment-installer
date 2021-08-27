#!/usr/bin/env bash

# Install with the following command
# DOTFILESBRANCH=master INSTALLER=debian bash -c "$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install.sh)"
# This assumes you already have a working OS and user created

set -e
set -o pipefail

export TARGET_USER=$(whoami)
export DOTFILESBRANCH=${DOTFILESBRANCH:-master}
export INSTALLER=${INSTALLER:-arch}
export GRAPHICS=${GRAPHICS:-intel}

curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-${INSTALLER}.sh
curl -o install-stage1.sh https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh

chmod 755 install-stage0.sh install-stage1.sh

echo "Running stage0 requires sudo, you will be prompted for your password"

sudo ./install-stage0.sh base
sudo ./install-stage0.sh wm
sudo ./install-stage0.sh games

echo "Installing dotfiles"

./install-stage1.sh dotfiles

echo "Initializing user environment"

zsh -i -c "./install-stage1.sh tools"
zsh -i -c "./install-stage1.sh vim"
zsh -i -c "./install-stage1.sh emacs"

echo "Cleaning up"

rm install-stage0.sh install-stage1.sh

echo "Done!, log out and back in for full effect"
