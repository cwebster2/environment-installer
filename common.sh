#!/usr/bin/env bash

set -euo pipefail

# Partitions a gpt disk with 512MB esp, swap and the rest to /
partition_disk() {
  DISK=$1
  SWAPSIZE=${2:-32}
  SWAP_OFFSET=$((SWAPSIZE*1024))

  echo "***"
  echo "Partitioning disks for efi/boot, swap and rpool"
  echo "***"

  parted -s -a optimal -- "/dev/disk/by-id/${DISK}" \
    unit mib \
    mklabel gpt \
    mkpart esp 1 513 \
    mkpart swap 513 ${SWAP_OFFSET} \
    mkpart rootfs ${SWAP_OFFSET} -1 \
    set 1 boot on \
    print \
    quit
  sync
  sleep 10
}

create_filesystems_zfs() {
  DISK=$1

  echo "***"
  echo "Creating filesystems, swap and zfs pools"
  echo "***"

  mkfs.fat -F32 "/dev/disk/by-id/${DISK}-part1"

  echo "***"
  echo "Creating the root pool"
  echo "rpool will ask for a passphrase"
  echo "***"
  zpool create -f \
    -o ashift=12 \
    -o cachefile= \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O relatime=on \
    -O atime=off \
    -O xattr=sa \
    -O normalization=formD \
    -O encryption=aes-256-gcm \
    -O keyformat=passphrase \
    -O canmount=off \
    -O devices=off \
    -m none \
    -R /mnt/os \
    rpool \
    "/dev/disk/by-id/${DISK}-part3"

  echo "***"
  echo "*** Creating zfs datasets"
  echo "*** /"
  zfs create -o mountpoint=none rpool/root
  zfs create -o mountpoint=none -o canmount=off rpool/data
  zfs create -o mountpoint=/ -o canmount=noauto rpool/root/arch
  zpool set bootfs=rpool/root/arch rpool

  echo *** "/tmp"
  zfs create -o setuid=off -o devices=off -o sync=disabled -o mountpoint=/tmp rpool/tmp

  echo "*** /var/log"
  zfs create -o mountpoint=/var/log rpool/root/log

  echo "*** /var/lib/docker"
  zfs create \
    -o mountpoint=/var/lib/docker \
    -o dedup=sha512 \
    -o quota=100G \
    rpool/data/docker

  echo "*** /usr/local"
  zfs create -o mountpoint=/usr/local rpool/root/usrlocal

  echo "*** /opt"
  zfs create rpool/opt

  echo "*** /home"
  zfs create -o mountpoint=/home rpool/data/home
  zfs create -o mountpoint=/root rpool/data/root
  chmod 700 /mnt/os/root
  echo "***"

  echo "***"
  echo "*** Creating swap"
  echo "***"
  mkswap -f "/dev/disk/by-id/${DISK}-part2"
  swapon "/dev/disk/by-id/${DISK}-part2"

  echo "***"
  echo "*** Exporting rpool"
  echo "***"

  zpool export -a

  echo "***"
  echo "*** Reimporting pool to validate"
  echo "*** You will be prompted for rpool passphrase"
  echo "***"

  zpool import -R /mnt/os rpool
  zfs load-key rpool
  zfs mount rpool/root/arch
  zfs mount -a

  zpool status -v
  zfs list

  mount | grep /mnt/os

  echo "***"
  echo "*** ZFS pools imported and datasets mounted"
  echo "***"
}

arch_install() {
  pacman --needed --noconfirm -S "$*"
}

aur_install_by_user() {
  TARGET_USER="${1}"
  shift
  # yay doesn't like being root
  su - "${TARGET_USER}" -c "yay --noconfirm -S $*"
}




