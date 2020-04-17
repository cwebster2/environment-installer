#!/usr/bin/env bash

set -e
set -o pipefail

export DISK=${DISK:-"/dev/disk/by-id/scsi-SATA_disk1"}

wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0pre-ubuntu.sh > install-stage0pre.sh

chmod 755 install-stage0pre.sh

echo "Running prepare requires sudo, you will be promped for your password"

echo "This process is destructive to any data on ${DISK}.  BEWARE"

sudo ./install-stagepre0.sh
