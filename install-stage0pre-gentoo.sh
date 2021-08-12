#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0pre-gentoo.sh

set -euo pipefail

export ROOTDATE=$(date +%Y%M%d)
export TARGET_USER=${TARGET_USER:-casey}
export STAGE3=${STAGE3:-20210808T170546Z/stage3-amd64-systemd-20210808T170546Z.tar.xz}
export DOTFILESBRANCH=${DOTFILESBRANCH:-master}
export GRAPHICS=${GRAPHICS:-intel}

partition_disk() {
  echo "***"
  echo "Partitioning disks for efi, boot, swap and rpool"
  echo "***"
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
}

create_filesystems() {
  echo "***"
  echo "Creating filesystems, swap and zfs pools"
  echo "***"
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
  zfs create -o mountpoint=/var/lib/docker rpool/data/docker
  zfs set quota=100G rpool/data/docker

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
}

prepare_chroot() {
  echo "***"
  echo "Preparing for chrooting"
  echo "***"
  # prepare for chroot
  cd /mnt/gentoo
  mkdir boot/efi
  mount "/dev/${DISK}1" boot/efi

  # get amd64+systemd stage3 archive
  curl -o stage3.tar.xz https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/${STAGE3}
  tar xpf stage3.tar.xz
  rm stage3.xz

  mkdir etc/zfs
  cp /etc/zfs/zpool.cache etc/zfs

  cp --dereference /etc/resolv.conf etc/

  mount --rbind /dev dev
  mount --rbind /proc proc
  mount --rbind /sys sys
  mount --make-rslave dev
  mount --make-rslave proc
  mount --make-rslave sys

  cat <<-EOF >>etc/fstab
/dev/${DISK}1               /boot/efi       vfat            noauto        1 2
/dev/${DISK}3               none            swap            sw            0 0
EOF
}

do_chroot() {
  echo "***"
  echo "***"
  echo "***"
  SCRIPTNAME=$(basename "$0")
  PATHNAME=$(dirname "$0")
  cp "${PATHNAME}/${SCRIPTNAME}" ./install-stage0.sh
  env -i HOME=/root \
    TERM=$TERM \
    DISK=$DISK \
    TARGET_USER=$TARGET_USER \
    ROOTDATE=$ROOTDATE \
    HOSTNAME=$HOSTNAME \
    chroot . bash -l -c "./install-stage0.sh chrooted"
  }

setup_portage() {
  echo "***"
  echo "Setting up portage"
  echo "***"

  cat <<-EOF >etc/portage/make.conf
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

  mkdir -p etc/portage/package.use
  echo "sys-boot/grub libzfs" >> /etc/portage/package.use/zfs
  echo "sys-kernel/linux-firmware initramfs" >> /etc/portage/package.use/boot
  mkdir -p etc/portage/repos.conf
  cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf

  echo "***"
  echo "Syncing portage tree, this could tage some time"
  echo "***"
  update_ports

  # mirrorselect -i -o >> /mnt/gentoo/etc/portage/make.conf

  eselect news read
  emerge --quiet-build -uDNav @world
}

setup_kernel() {
  echo "***"
  echo "Setting up kernel"
  echo "***"
  emerge --quiet-build net-misc/dhcp sys-kernel/genkernel

  # need to gen kernel config make menuconfig
  eselect kernel set 1
  genkernel --makeopts=-j4 --no-install kernel

  # now we have kernel we can install zfs-kmod
  emerge --quiet-build sys-fs/zfs sys-fs/zfs-kmod sys-boot/grub
  hostid >/etc/hostid
  genkernel --makeopts=-j4 --zfs --bootloader=grub2 all

  if [ "$(grub-probe /boot)" != "zfs" ]; then
    echo "grub-probe did not return zfs, aborting"
    exit 1
  fi

  echo "***"
  echo "Setting up booting"
  echo "***"
  cat <<-EOF >>etc/default/grub
GRUB_CMDLINE_LINUX="dozfs root=ZFS"
EOF

  mount -o remount,rw /sys/firmware/efi/efivars/
  grub-install --efi-directory=/boot/efi
  grub-mkconfig -o /boot/grub/grub.cfg

  echo "options zfs zfs_arc_max=4294967296" >> /etc/modprobe.d/zfs.conf
  systemctl enable zfs.target
  systemctl enable zfs-import-cache
  systemctl enable zfs-mount
  systemctl enable zfs-import.target
}

setup_user() {
  TARGET_USER=${TARGET_USER:-casey}
  useradd -m -s /bin/bash -G wheel,portage ${TARGET_USER}
  echo "***"
  echo "Setting up user account for ${TARGET_USER}, please set a password"
  echo "***"
  passwd ${TARGET_USER}
}

setup_timezone() {
  # timezoen
  echo "***"
  echo "Setting Timezone"
  echo "***"
  ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
}

setup_locale() {
  echo "***"
  echo "***"
  echo "***"
  # locale
  echo "LANG=en_US.utf8" > /etc/locale.conf
  env-update && source /etc/profile
}

setup_hostname() {
  echo "***"
  echo "***"
  echo "***"
  # hostname
  hostnamectl set-hostname ${HOSTNAME}
}

setup_network() {
  echo "***"
  echo "***"
  echo "***"
  # networking
  cat <<-EOF > /etc/systemd/network/50-dhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
EOF
  systemctl enable systemd-networkd.service

}

cleanup_chroot() {
  echo "***"
  echo "Cleaning up"
  echo "***"
  umount -lR {dev,proc,sys}
  cd /
  zfs umount -a
  swapoff /dev/${DISK}3
  # neet do unmount stuff, export and reboot
  zpool export rpool
  zpool export boot
  echo "***"
  echo "Finished with the initial setup."
  echo "***"
}

setup_profile() {
  echo "***"
  echo Selecting desktop systemd profile
  echo "***"
  eselect profile set $(eselect profile list | grep "amd64/17.1/desktop/systemd" | tr -d '[]' | awk '{print $1}')
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
  echo "***"
  echo "Setting up sudo for ${TARGET_USER}"
  echo "***"
  emerge --quiet-build app-admin/sudo
  gpasswd -a "$TARGET_USER" systemd-journal
  gpasswd -a "$TARGET_USER" systemd-network

  { \
    echo -e "Defaults	secure_path=\"/usr/local/go/bin:/home/${TARGET_USER}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/bcc/tools:/home/${TARGET_USER}/.cargo/bin\""; \
    echo -e 'Defaults	env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"'; \
    echo -e "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"; \
    echo -e "${TARGET_USER} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery"; \
  } > "/etc/sudoers.d/${TARGET_USER}"
}

select_base() {
  cat <<-EOF >>/var/lib/portage/world
app-admin/sudo
app-arch/bzip2
app-arch/gzip
app-arch/tar
app-arch/unar
app-arch/unzip
app-arch/xz-utils
app-arch/zip
app-crypt/gnupg
app-crypt/pinentry
app-editors/emacs
app-emulation/docker
app-emulation/docker-cli
app-emulation/docker-compose
app-emulation/docker-credential-helpers
app-misc/ca-certificates
app-misc/jq
app-misc/ranger
app-shells/zsh
dev-tcltk/expect
dev-util/ctags
dev-util/pkgconf
dev-util/strace
dev-vcs/git
exuberant-ctags
net-analyzer/netcat
net-analyzer/prettyping
net-analyzer/tcptraceroute
net-analyzer/traceroute
net-firewall/nftables
net-firewall/nftables
net-libs/libssh2
net-misc/bridge-utils
net-misc/curl
net-misc/openssh
net-misc/rsync
net-misc/wget
net-print/brlaser
net-wireless/bluez
net-wireless/iw
net-wireless/iwd
sys-apps/bolt
sys-apps/coreutils
sys-apps/file
sys-apps/findutils
sys-apps/fwupd
sys-apps/grep
sys-apps/iproute2
sys-apps/less
sys-apps/lm-sensors
sys-apps/lsb-release
sys-apps/lshw
sys-apps/net-tools
sys-apps/the_silver_searcher
sys-devel/automake
sys-devel/bc
sys-devel/gcc
sys-devel/make
sys-process/htop
sys-process/lsof
sys-process/psmisc
EOF

   cat <<-EOF >>/etc/portage/make.conf
USE="gnome-keyring systemd udev pulseaudio bluetooth cups thunderbolt uefi gnutls dbus device-mapper apparmor X gtk qt5 policykit"
EOF
}

do_emerge() {
  emerge --newuse --update --deep --quiet-build --complete-graph --autounmask-write --autounmask-continue @world
  emerge --clean  --verbose
}

check_is_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
  fi
}

usage() {
  echo -e "install.sh\\n\\tThis script preps a gentoo laptop\\n"
  echo "Usage:"
  echo "  prepare                             - Prepare new maching for first boot"
  echo "  chrooted                            - Initial chroot installation"
  echo "  base                                - Recompiles world"
  echo "  profile                             - Sets the desktop/systemd profile and rebuilds"
}

main() {
  local cmd=$1

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  if [[ $cmd == "prepare" ]]; then
    partition_disk
    create_filesystems
    prepare_chroot
    do_chroot
    cleanup_chroot
    echo "reboot and run insall-stage0.sh profile"
  elif [[ $cmd == "chrooted" ]]; then
    setup_portage
    setup_kernel
    setup_user
    setup_timezone
    setup_locale
    setup_hostname
    setup_network
  elif [[ $cmd == "base" ]]; then
    # update_ports
    echo "TODO"
  elif [[ $cmd == "profile" ]]; then
    setup_profile
    bring_up_to_baseline
    select_base
    do_emerge
    echo "TODO"
  else
    usage
  fi
}

main "$@"
