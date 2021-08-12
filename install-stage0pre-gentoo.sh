#!/usr/bin/env bash

set -euo pipefail

do_prep() {
  # boot from sysrescuecd with zfs 2 baked into it
  # https://xyinn.org/gentoo/livecd/
  # get in and then do this stuff

  echo "Preparing to partition ${DISK}"
  # The plan:
  # 512 MB system /boot/efi
  # 1 GB boot (zfs) /boot
  # 32 GB swap
  # the rest of the disk ZFS /,/home,etc
  parted -s -a optimal -- "/dev/${DISK}" \
    unit mib \
    mklabel gpt \
    mkpart esp 1 513 \
    mkpart boot 513 1537 \
    mkpart swap 1537 34305 \
    mkpart rootfs 34305 -1 \
    set 1 boot on \
    print \
    quit

  mkfs.fat -F32 /dev/${DISK}1

  zpool create -f \
    -o ashift=12 \
    -o cachefile= \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O atime=off \
    -O xattr=sa \
    -O encryption=on \
    -O keyformat=passphrase \
    -m none \
    -R /mnt/gentoo \
    rpool \
    "/dev/${DISK}4"

  ROOTDATE=$(date +%Y%M%d)
  zfs create rpool/gentoo
  zfs create -o mountpoint=/ rpool/gentoo/root-${ROOTDATE}
  zpool set bootfs=rpool/gentoo/root-${ROOTDATE} rpool

  zfs create rpool/gentoo_data
  zfs create -o mountpoint=/var/lib/portage/distfiles rpool/gentoo_data/distfiles

  zfs create rpool/data
  zfs create -o mountpoint=/home rpool/data/home

  zpool create -f -d \
    -o ashift=12 \
    -o cachefile= \
    -m /boot \
    -R /mnt/gentoo \
    boot \
    "/dev/${DISK}2"

  mkswap -f "/dev/${DISK}3"
  swapon "/dev/${DISK}3"

  zpool status

  zfs lis

  # prepare for chroot
  cd /mnt/gentoo
  mkdir boot/efi
  mount "/dev/${DISK}1" boot/efi

  # get amd64+systemd stage3 archive
  wget https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/20210808T170546Z/stage3-amd64-systemd-20210808T170546Z.tar.xz
  tar xpf stage3-amd64-systemd-20210808T170546Z.tar.xz

  mkdir etc/zfs
  cp /etc/zfs/zpool.cache etc/zfs

  cp /etc/resolv.conf etc/

  mount --rbind /dev dev
  mount --rbind /proc proc
  mount --rbind /sys sys
  mount --make-rslave dev
  mount --make-rslave proc
  mount --make-rslave sys

  env -i HOME=/root TERM=$TERM DISK=$DISK chroot . bash -l

  cat <<-EOF >>/etc/fstab
/dev/${DISK}1               /boot/efi       vfat            noauto        1 2
/dev/${DISK}3               none            swap            sw            0 0
EOF

  cat <<-EOF >/etc/portage/make.conf
# See /usr/share/portage/config/make.conf.example
USE="initramfs"

MAKEOPTS="-j5"

COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

PORTDIR="/var/db/repos/gentoo"
PORTAGE_TMPDIR="/var/tmp/portage"
DISTDIR="/var/lib/portage/distfiles"

ACCEPT_LICENSE="*"
EMERGE_DEFAULT_OPTS="--with-bdeps=y --keep-going=y"
FEATURES="buildpkg"

LINGUAS="en enUS ro"

LC_MESSAGES=C
GRUB_PLATFORMS="efi-64 coreboot"
EOF

  mkdir -p /etc/portage/package.use

  cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf
  emerge --sync

  eselect news read
  emerge -uDNav @world
  emerge neovim net-misc/dhcp

  echo "sys-boot/grub libzfs" >> /etc/portage/package.use/zfs
  echo "sys-kernel/linux-firmware initramfs" >> /etc/portage/package.use/boot
  emerge --verbose ys-kernel/genkernel sys-boot/grub

  # need to gen kernel config make menuconfig
  select kernel set 1
  genkernel --makeopts=-j4 --no-install kernel

  # now we have kernel we can install zfs-kmod
  emerge --verbose sys-fs/zfs sys-fs/zfs-kmod
  genkernel --makeopts=-j4 --zfs all

  if [ "$(grub-probe /boot)" != "zfs" ]; then
    echo "grub-probe did not return zfs, aborting"
    exit 1
  fi

  cat <<-EOF >>/etc/default/grub
GRUB_DISTRIBUTOR="Gentoo Linux"
GRUB_CMDLINE_LINUX="dozfs real_root=ZFS=rpool/gentoo/root-${ROOTDATE}"
EOF

  mount -o remount,rw /sys/firmware/efi/efivars/
  grub-install --efi-directory=/boot/efi

  ls /boot/grub/*zfs.mod
  grub-mkconfig -o /boot/grub/grub.cfg

  systemctl enable zfs.target
  systemctl enable zfs-import-cache
  systemctl enable zfs-mount
  systemctl enable zfs-import.target

  TARGET_USER=${TARGET_USER:-casey}
  useradd -m -s /bin/bash -G wheel,portage ${TARGET_USER}
  passwd ${TARGET_USER}
  setup_sudo

  exit
  umount -lR {dev,proc,sys}
  cd
  swapoff /dev/${DISK}3
  zpool export 

}

setup_profile() {
  echo "***"
  echo Selecting desktop systemd profile
  echo "***"
  eselect profile set $(eselect profile list | grep "amd64/17.1/desktop/systemd" | tr -d '[]' | awk '{print $1}')
}

setup_makeconf() {
  echo "***"
  echo "Setting up make.conf and portage use"
  echo "***"
#USE="gnome-keyring systemd udev pulseaudio -elogind bluetooth cups nvme thunderbolt uefi gnutls dbus device-mapper apparmor X gtk qt policykit"
  cat <<-EOF > /etc/portage/make.conf
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j12"
ACCEPT_LICENSE="*"
LINGUAS="en enUS ro"
LC_MESSAGES=C
EOF
cat /etc/portage/make.conf
}

update_ports() {
  echo "***"
  echo Downloading portage tree
  echo "***"
  emerge --sync --quiet
}

maybe_fix() {
  emerge -v1 glibc
  emerge -v1 virtual/libcrypt sys-libs/libxcrypt
  USE=-tuetype emerge --quiet-build --autounmask-write --autounmask-continue --keep-going --oneshot harfbuzz
  USE=-harfbuzz emerge --quiet-build --autounmask-write --autounmask-continue --oneshot freetype
}

bring_up_to_baseline() {
  echo "***"
  echo Rebuilding world with new profile and base use flags
  echo "***"
  emerge --newuse --update --deep --quiet-build --autounmask-write --autounmask-continue --reinstall=changed-use @world
}

setup_sudo() {
  # add user to sudoers
  adduser "$TARGET_USER" sudo

  # add user to systemd groups
  # then you wont need sudo to view logs and shit
  gpasswd -a "$TARGET_USER" systemd-journal
  gpasswd -a "$TARGET_USER" systemd-network

  # create docker group
  sudo groupadd -f docker
  sudo gpasswd -a "$TARGET_USER" docker

  # add go path to secure path
  { \
    echo -e "Defaults	secure_path=\"/usr/local/go/bin:/home/${TARGET_USER}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/bcc/tools:/home/${TARGET_USER}/.cargo/bin\""; \
    echo -e 'Defaults	env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"'; \
    echo -e "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"; \
    echo -e "${TARGET_USER} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery"; \
  } >> /etc/sudoers

  # setup downloads folder as tmpfs
  # that way things are removed on reboot
  # i like things clean but you may not want this
  mkdir -p "/home/${TARGET_USER}/Downloads"
  chown ${TARGET_USER}:${TARGET_USER} "/home/${TARGET_USER}/Downloads"
  echo -e "\\n# tmpfs for downloads\\ntmpfs\\t/home/${TARGET_USER}/Downloads\\ttmpfs\\tnodev,nosuid,size=2G\\t0\\t0" >> /etc/fstab
  (
    set +e
    sudo mount "/home/${TARGET_USER}/Downloads"
    chown ${TARGET_USER}:${TARGET_USER} "/home/${TARGET_USER}/Downloads"
  )
}

usage() {
  echo -e "install.sh\\n\\tThis script preps a gentoo laptop\\n"
  echo "Usage:"
  echo "  updatebase                          - Recompiles world"
  echo "  setprofile                          - Sets the desktop/systemd profile and rebuilds"
}

main() {
  local cmd=$1

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  if [[ $cmd == "updatebase" ]]; then
    # update_ports
    maybe_fix
    setup_makeconf
    setup_profile
    bring_up_to_baseline
  elif [[ $cmd == "setprofile" ]]; then
    bring_up_to_baseline
  else
    usage
  fi
}

main "$@"
