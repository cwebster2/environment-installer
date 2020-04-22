#!/usr/bin/env bash

# This is meant to be run from a liveCD environment
# Onto a machine you want to dedicate the entire disk
# to Linux.  This will erase the entire disk.

# This will erase the entire disk

# This will erase the entire disk

# You've been warned.

set +e
set -o pipefail
#set -x

export HOSTNAME=${HOSTNAME:-"caseybook"}
export DISK=${DISK:-"/dev/disk/by-id/scsi-SATA_disk1"}
export RELEASE=${RELEASE:-"focal"}
export DISTRO=${DISTRO:-"ubuntu"}
export DOTFILESBRANCH=${DOTFILESBRANCH:-"master"}
export SWAPSIZE=${SWAPSIZE:-"1G"}
export TZONE=${TZONE:-"America/Chicago"}

export DEBIAN_FRONTEND=noninteractive
export APT_LISTBUGS_FRONTEND=none
export DEBCONF_NONINTERACTIVE_SEEN=true
export TARGET_USER=${TARGET_USER:-casey}

install_prereqs() {
  echo "I: Installing ntpdate"
  apt-add-repository universe
  apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Check-Date=false update
  apt install --yes ntpdate

  echo "I: Setting system clock"
  ntpdate-debian

  echo "I: Installing prereqs for install"
  apt-get update
  apt install --yes debootstrap gdisk zfs-initramfs ntpdate mdadm
}

partition_disk() {
  echo "Removing traces of previous installations"

  mdadm --zero-superblock --force ${DISK}
  sgdisk --zap-all ${DISK}

  echo "Partitioning ${DISK}"

  sgdisk -n1:1M:+512M -t1:EF00 ${DISK}
  sgdisk -n2:0:+${SWAPSIZE}    -t2:8200 ${DISK}
  sgdisk -n3:0:+1G    -t3:BE00 ${DISK}
  sgdisk -n4:0:0      -t4:BF00 ${DISK}

  echo "Sleeping to let disks sync before creating zfs pools"
  sleep 5

  partprobe ${DISK}

  sleep 5
}

init_zfs() {
  UUID_ORIG=$(head -100 /dev/urandom | tr -dc 'a-z0-9' |head -c6)
  UUID2_ORIG=$(head -100 /dev/urandom | tr -dc 'a-z0-9' |head -c6)

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
  zfs create -o com.sun:auto-snapshot=false "rpool/ROOT/ubuntu_${UUID_ORIG}/var/lib/docker"

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

  bootfsdataset=$(grep "\s/mnt\s" /proc/mounts | awk '{ print $1 }')
  zfs create "rpool/USERDATA/${TARGET_USER}_${UUID2_ORIG}" -o canmount=on -o mountpoint="/home/${TARGET_USER}"
  zfs create "rpool/USERDATA/root_${UUID2_ORIG}" -o canmount=on -o mountpoint="/root"
  zfs set com.ubuntu.zsys:bootfs-datasets="${bootfsdataset}" "rpool/USERDATA/${TARGET_USER}_${UUID2_ORIG}"
  zfs set com.ubuntu.zsys:bootfs-datasets="${bootfsdataset}" "rpool/USERDATA/root_${UUID2_ORIG}"
  chown root:root /root
  chmod 700 /root
}

bootstrap_system() {
  debootstrap "${RELEASE}" /mnt
  zfs set devices=off rpool
}

configure_chroot() {
  echo "Configuring basic environment"
    ln -s /proc/self/mounts /etc/mtab
    sed -i '/en_US.UTF-8/ s/^# //' /etc/locale.gen
    locale-gen
    dpkg-reconfigure --frontend=noninteractive locales
    update-locale LANG=en_US.UTF-8

    echo "${TZONE}" > /etc/timezone
    rm -f /etc/localtime
    cp -f /usr/share/zoneinfo/$TZONE /etc/localtime
    dpkg-reconfigure --frontend=noninteractive tzdata

    apt-get update

    apt-get install --yes \
      linux-image-generic \
      --no-install-recommends

    apt-get install --yes \
      zfs-initramfs \
      zfsutils-linux \
      zfs-dkms \
      zsys \
      dosfstools \
      grub-efi-amd64-signed \
      shim-signed


    apt-get install --yes grub-pc
    echo "Setting up /boot/efi"
    mkdosfs -F 32 -s 1 -n EFI ${DISK}-part1
    mkdir /boot/efi
    echo PARTUUID=$(blkid -s PARTUUID -o value ${DISK}-part1) /boot/efi vfat nofail,umask=0077,x-systemd.device-timeout=1 0 1 >> /etc/fstab
    echo "/boot/efi/grub /boot/grub none defaults,bind 0 0" >> /etc/fstab
    mkdir -p /boot/efi
    mount /boot/efi
    mkdir -p /boot/efi/grub
    mkdir -p /boot/grub
    mount /boot/efi/grub

    echo "Fixing initrd"
    KVER=$(find /boot/ -name 'vmlinuz-*' -print | cut -d"-" -f2)
    KVERM=$(find /boot/ -name 'vmlinuz-*' -print | cut -d"-" -f3)
    mkinitramfs -o "/boot/initrd.img-${KVER}-${KVERM}-generic" ${KVER}-${KVERM}-generic

    echo "Setting up /tmp as a tmpfs"
    cp /usr/share/systemd/tmp.mount /etc/systemd/system
    systemctl enable tmp.mount

    echo "Setting up system groups"
    addgroup --system lpadmin
    addgroup --system sambashare

    echo "Setting up GRUB"
    grub-probe /boot
    update-initramfs -u -k all

    cat >> /etc/default/grub <<-EOF
GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/ubuntu_${UUID_ORIG}"
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=5
GRUB_RECORDFAIL_TIMEOUT=5
EOF
    update-grub

    grub-install \
      --target=x86_64-efi \
      --efi-directory=/boot/efi \
      --bootloader-id=ubuntu \
      --recheck \
      --no-floppy


    echo "Adding user"
    cp -a /etc/skel/. /home/${TARGET_USER}
    adduser --home /home/${TARGET_USER} --shell /usr/bin/bash --uid 1000 ${TARGET_USER}
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo,audio,video ${TARGET_USER}
    cat > /home/${TARGET_USER}/do-stage0-install.sh <<-EOF
DOTFILESBRANCH="${DOTFILESBRANCH}" INSTALLER="${DISTRO}" bash -c "\$(wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install.sh)"  | tee install.log
EOF
    chmod 755 /home/${TARGET_USER}/do-stage0-install.sh
    chown -R ${TARGET_USER}.${TARGET_USER} /home/${TARGET_USER}


    echo "disabling log rotation compression due to native zfs compression"
    for file in /etc/logrotate.d/* ; do
      if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r 's/(^|[^#y])(compress)/\1#\2/' "$file"
      fi
    done

    echo "Activating swap"
    mkswap ${DISK}-part2
    SWAPID=$(blkid -s UUID -o value "${DISK}-part2")
    printf "UUID=${SWAPID}\tnone\tswap\tdiscard\t0\t0\n" >> "/etc/fstab"
    swapon -v "${DISK}-part2"

    echo "Installing base system"
    apt-get dist-upgrade --yes
    apt-get install --yes ubuntu-standard network-manager
}

export -f configure_chroot
configure_system() {

  echo "Setting hostname... ${HOSTNAME}"

  echo ${HOSTNAME} > /mnt/etc/hostname
  cat >> /mnt/etc/hosts <<-EOF
127.0.0.1   ${HOSTNAME}
EOF

  echo "Setting networking"
  cat > /mnt/etc/netplan/01-network-manager-all.yaml <<-EOF
network:
  version: 2
  renderer: NetworkManager
EOF

  echo "Setting apt sources"
  cat > /mnt/etc/apt/sources.list <<- EOF
deb http://archive.ubuntu.com/ubuntu ${RELEASE} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${RELEASE} main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${RELEASE}-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu ${RELEASE}-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${RELEASE}-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${RELEASE}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${RELEASE}-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${RELEASE}-backports main restricted universe multiverse
EOF

  echo "Chrooting time"
  mount --rbind /dev /mnt/dev
  mount --rbind /proc /mnt/proc
  mount --rbind /sys /mnt/sys
  chroot /mnt /usr/bin/env DISK=${DISK} UUID_ORIG=${UUID_ORIG} bash -c "configure_chroot"
  echo "Test state of install in /mnt"
}

finalize() {
  echo "Setting mount point generator"
  ln -s /usr/lib/zfs-linux/zed.d/history_event-list-cacher.sh /mnt/etc/zfs/zed.d
  zpool set cachefile= bpool
  zpool set cachefile= rpool
  cp /etc/zfs/zpool.cache /mnt/etc/zfs
  mkdir -p /mnt/etc/zfs/zfs-list.cache
  touch /mnt/etc/zfs/zfs-list.cache/bpool /mnt/etc/zfs/zfs-list.cache/rpool

  zfs set sync=standard rpool

  # make boot stuff world readable
  sed -i 's#\(.*boot/efi.*\)umask=0077\(.*\)#\1umask=0022,fmask=0022,dmask=0022\2#' "/mnt/etc/fstab"

  echo "cleaning up"
  mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
  zpool export -a

  echo "REBOOT"
}

#TODO SWAP

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
    echo "Using ${DISK} as installation target"
    echo "Using ${HOSTNAME} as hostname"
    echo "Bootsrapping ubuntu ${RELEASE}"

    install_prereqs
    partition_disk
    init_zfs
    bootstrap_system
    configure_system
    finalize

  elif [[ $cmd == "bootstrap" ]]; then
    echo "Bootsrapping ubuntu ${RELEASE}"
    bootstrap_system

  elif [[ $cmd == "configure" ]]; then
    echo "Configuring ubuntu ${RELEASE}"
    configure_system

  elif [[ $cmd == "finalize" ]]; then
    echo "Finalizing system"
    finalize
  else
    usage
  fi
}

main "$@"
