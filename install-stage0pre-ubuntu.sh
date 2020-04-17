#!/usr/bin/env bash

# This is meant to be run from a liveCD environment
# Onto a machine you want to dedicate the entire disk
# to Linux.  This will erase the entire disk.

# This will erase the entire disk

# This will erase the entire disk

# You've been warned.

set -e
set -o pipefail

HOSTNAME=${HOSTNAME:-"caseybook"}
DISK=${DISK:-"/dev/disk/by-id/scsi-SATA_disk1"}
echo "Using ${DISK} as installation target"
echo "Using ${HOSTNAME} as hostname"

install_prereqs() {
  apt-add-repository universe
  apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Check-Date=false update
  apt install --yes ntpdate

  echo "Syncing system clock"
  ntpdate-debian

  apt-get update
  apt install --yes debootstrap gdisk zfs-initramfs ntpdate mdadm
}

partition_disk() {
  echo "Removing traces of previous installations"

  mdadm --zero-superblock --force ${DISK}
  sgdisk --zap-all ${DISK}

  echo "Partitioning ${DISK}"

  sgdisk -n1:1M:+512M -t1:EF00 ${DISK}
  sgdisk -n2:0:+1G    -t2:8200 ${DISK}
  sgdisk -n3:0:+1G    -t3:BE00 ${DISK}
  sgdisk -n4:0:0      -t4:BF00 ${DISK}

  partprobe ${DISK}
}

init_zfs() {
  UUID_ORIG=$(head -100 /dev/urandom | tr -dc 'a-z0-9' |head -c6)

  echo "Creating the zfs boot pool"

  zpool create -o ashift=12 -d \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@userobj_accounting=enabled \
    -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
    -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -R /mnt bpool ${DISK}-part3

  echo "Creating the zfs root pool"

  zpool create -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
    -O mountpoint=/ -R /mnt \
    rpool ${DISK}-part4

  zfs create rpool/ROOT -o canmount=off -o mountpoint=none
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}" -o mountpoint=/
  zfs create bpool/BOOT -o canmount=off -o mountpoint=none
  zfs create "bpool/BOOT/ubuntu_${UUID_ORIG}" -o mountpoint=/boot

  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var" -o canmount=off
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/AccountsService"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/apt"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/dpkg"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/NetworkManager"

  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/srv"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/usr" -o canmount=off
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/usr/local"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/games"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/log"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/mail"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/snap"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/spool"
  zfs create "rpool/ROOT/ubuntu_${UUID_ORIG}/var/www"

  zfs create rpool/USERDATA -o canmount=off -o mountpoint=/

  zfs set com.ubuntu.zsys:bootfs='yes' "rpool/ROOT/ubuntu_${UUID_ORIG}"
  zfs set com.ubuntu.zsys:last-used=$(date +%s) "rpool/ROOT/ubuntu_${UUID_ORIG}"
  zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/srv"
  zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/usr"
  zfs set com.ubuntu.zsys:bootfs='no' "rpool/ROOT/ubuntu_${UUID_ORIG}/var"
}

bootstrap_system() {
  debootstrap focal /mnt
  zfs set devices=off rpool
}

configure_system() {
  echo ${HOSTNAME} > /mnt/etc/hostname

  cat >> /mnt/etc/hosts <<-EOF
127.0.0.1   ${HOSTNAME}
EOF

}

echo "Test state of install in /mnt"

create_zfs_snapshot() {
  echo
  echo "Creating ZFS Snapshot"
  echo

  if [[ -z $(command -v zfs) ]]; then
    echo "zfs not found, skipping"
    return 0
  fi

  zfs snapshot -r rpool/ROOT@stage0preinstall
}

rollback_zfs_snapshot() {
  echo
  echo "An error occured during install, rolling back to filesystem state before this install step"
  echo

  if [[ -z $(command -v zfs) ]]; then
    echo "zfs not found, skipping"
    return 0
  fi

  zfs rollback -r rpool/ROOT@stage0preinstall
}

destroy_zfs_snapshot() {
  echo
  echo "The install step was successful, removing zfs snapshot"
  echo

  if [[ -z $(command -v zfs) ]]; then
    echo "zfs not found, skipping"
    return 0
  fi

  zfs destroy -r rpool/ROOT@stage0preinstall
}

usage() {
  echo -e "install.sh\\n\\tThis script installs my basic setup for a debian laptop\\n"
  echo "Usage:"
  echo "  init                                - Do it all"
  echo "  bootstrap                           - bootstrap unconfigured base"
  echo "  configure                           - configure base system"
  echo "  finalize                            - finalize installation"
}

main() {
  local cmd=$1

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  #trap 'rollback_zfs_snapshot' ERR SIGINT
  #trap 'destroy_zfs_snapshot' EXIT
  #create_zfs_snapshot

  if [[ $cmd == "init" ]]; then
    install_prereqs
    partition_disk
    init_zfs
    bootstrap_system
    configure_system

  elif [[ $cmd == "bootstrap" ]]; then
    bootstrap_system

  elif [[ $cmd == "configure" ]]; then
    configure_system

  elif [[ $cmd == "finalize" ]]; then
    echo TODO
  else
    usage
  fi
}

main "$@"
