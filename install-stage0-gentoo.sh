#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0pre-gentoo.sh

set -eo pipefail

export ROOTDATE=$(date +%Y%M%d)
export TARGET_USER=${TARGET_USER:-casey}
export STAGE3=${STAGE3:-20210808T170546Z/stage3-amd64-systemd-20210808T170546Z.tar.xz}
export DOTFILESBRANCH=${DOTFILESBRANCH:-master}
export GRAPHICS=${GRAPHICS:-intel}
export SWAPSIZE=${SWAPSIZE:-32}
#export SSID=set this
#export WPA_PASSPHRASE=set this

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
  SWAP_OFFSET=$((${SWAPSIZE}*1024 + 1537))
  parted -s -a optimal -- "/dev/${DISK}" \
    unit mib \
    mklabel gpt \
    mkpart esp 1 513 \
    mkpart boot 513 1537 \
    mkpart swap 1537 ${SWAP_OFFSET} \
    mkpart rootfs ${SWAP_OFFSET} -1 \
    set 1 boot on \
    print \
    quit
}

create_filesystems() {
  echo "***"
  echo "Creating filesystems, swap and zfs pools"
  echo "***"
  mkfs.fat -F32 /dev/${DISK}1

  echo "rpool will ask for a passphrase"
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

  zfs list
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
  echo ${STAGE3}
  curl -L -o stage3.tar.xz https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/${STAGE3}
  tar xpf stage3.tar.xz
  rm stage3.tar.xz

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
  echo "Chrooting"
  echo "***"
  cd ~
  SCRIPTNAME=$(basename "$0")
  PATHNAME=$(dirname "$0")
  cp "${PATHNAME}/${SCRIPTNAME}" /mnt/gentoo/install-stage0.sh
  cd /mnt/gentoo
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

MAKEOPTS="-j$(cat /proc/cpuinfo | grep "core id" | wc -l)"

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
VIDEO_CARDS="${GRAPHICS}"
LLVM_TARGETS="X86 AArch64 RISCV WebAssembly"
EOF

  mkdir -p /var/tmp/portage
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
  emerge --quiet-build -uDNv @world
}

setup_kernel() {
  echo "***"
  echo "Setting up kernel"
  echo "***"
  emerge --quiet-build net-misc/dhcp sys-kernel/genkernel sys-kernel/gentoo-sources

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
  echo "***"
  echo "Setting up user account for ${TARGET_USER}, please set a password"
  echo "***"
  TARGET_USER=${TARGET_USER:-casey}
  useradd -m -s /bin/bash -G wheel,portage ${TARGET_USER}
  passwd ${TARGET_USER}
  setup_sudo
}

setup_timezone() {
  echo "***"
  echo "Setting Timezone"
  echo "***"
  ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
}

setup_locale() {
  echo "***"
  echo "Setting english utf8 locale"
  echo "***"
  echo "LANG=\"en_US.utf8\"" >> /etc/locale.conf
  echo "en_US.UTF8 UTF-8" >> /etc/locale.gen
  locale-gen
  env-update && source /etc/profile
}

setup_hostname() {
  echo "***"
  echo "Setup hostname"
  echo "***"
  # cant run this until after first boot
  hostnamectl set-hostname ${HOSTNAME}
}

setup_network() {
  echo "***"
  echo "Setting up dhcp for ethernet interfaces."
  echo "***"
  cat <<-EOF > /etc/systemd/network/50-dhcp.network
[Match]
Name=en*

[Network]
DHCP=yes
EOF
  cat <<-EOF > /etc/systemd/network/00-wireless-dhcp.network
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF
  emerge --quiet-build --verbose net-wireless/iw net-wireless/wpa_supplicant
  cat <<-EOF > /etc/wpa_supplicant/wpa_supplicant.conf
# Allow users in the 'wheel' group to control wpa_supplicant
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel

# Make this file writable for wpa_gui / wpa_cli
update_config=1
EOF
  wpa_passphrase "${SSID}" "${WPA_PASSPHRASE}" >> /etc/wpa_supplicant/wpa_supplicant.conf

  systemctl enable wpa_supplicant@wlan0.service
  systemctl enable systemd-networkd.service

}

cleanup_chroot() {
  echo "***"
  echo "Cleaning up"
  echo "***"
  umount -lR /mnt/gentoo/{dev,proc,sys,boot}
  cd /
  zfs umount -a
  swapoff /dev/${DISK}3
  # neet do unmount stuff, export and reboot
  # TODO fix exporting rpool
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
  echo "dev-lang/rust rls rustfmt wasm" >> /etc/portage/package.use/rust
  echo "virtual/rust rustfmt" >> /etc/portage/package.use/rust
}

update_ports() {
  echo "***"
  echo Downloading portage tree
  echo "***"
  emerge --sync --quiet
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
dev-util/github-cli
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

  update_use "gnome-keyring systemd udev pulseaudio bluetooth cups thunderbolt uefi gnutls dbus apparmor wayland X gtk qt5 policykit"

  echo "dev-libs/boost numpy python" >> /etc/portage/package.use/boost
  mkdir -p /etc/portage/package.accept_keywords
  echo "dev-util/github-cli ~amd64" >> /etc/portage/package.accept_keywords/gh
}

update_use() {
  NEWUSE=$1
  OLDUSE=$(env -i bash -c 'source /etc/portage/make.conf; echo $USE')
  RESULTUSE="${OLDUSE} ${NEWUSE}"
  sed -i "s/USE=.*/USE=\"${RESULTUSE}\"/" /etc/portage/make.conf
}

set_video_cards() {
  NEWVIDEO=$1
  sed -i "s/VIDEO_CARDS=.*/VIDEO_CARDS=\"${NEWVIDEO}\"/" /etc/portage/make.conf
}

select_laptop() {
  #uptade_use if needed
  cat <<-EOF >>/var/lib/portage/world
sys-power/thermald
app-laptop/laptop-mode-tools
EOF
  echo "app-laptop/laptop-mode-tools acpi -apm bluetooth" >> /etc/portage/package.use/laptop
}

configure_laptop() {
  # https://wiki.gentoo.org/wiki/Power_management/Guide
  echo "ENABLE_LAPTOP_MODE_ON_BATTERY=1" >> /etc/laptop-mode/conf.d/cpufreq.conf
  systemctl enable thermald
  systemctl enable laptop-mode.service

  cat <<-EOF >>/etc/udev/rules.d/99-lowbat.rules
# Suspend the system when battery level drops to 5% or lower
SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", ATTR{capacity}=="[0-5]", RUN+="/usr/bin/systemctl hibernate"
EOF
}

select_wm() {
  #uptade_use if needed
  case $GRAPHICS in
    "intel")
      set_video_cards "intel i965 iris"
  cat <<-EOF >> /var/lib/portage/world
x11-drivers/xf86-video-intel
x11-libs/libva-intel-driver
x11-libs/libva-intel-media-driver
EOF
  echo "x11-drivers/xf86-video-intel dri sna tools udev uxa xvmc" >> /etc/portage/package.use/video
      ;;
    "geforce")
      set_video_cards "nvidia"
  cat <<-EOF >> /var/lib/portage/world
x11-drivers/nvidia-drivers
EOF
      ;;
    "optimus")
      set_video_cards "nvidia intel"
  cat <<-EOF >> /var/lib/portage/world
x11-drivers/nvidia-drivers
x11-misc/bumblebee
x11-misc/primus
EOF
      ;;
    *)
      echo "You need to specify whether it's intel, geforce or optimus"
      exit 1
      ;;
  esac

  cat <<-EOF >> /var/lib/portage/world
app-crypt/keybase
app-editors/vscode
app-misc/neofetch
app-select/eselect-repository
games-emulation/higan
gnome-extra/gucharmap
gui-apps/swaybg
gui-apps/swayidle
gui-apps/swaylock
gui-apps/waybar
gui-wm/sway
kde-misc/kdeconnect
media-gfx/flameshot
media-gfx/inkscape
media-sound/alsa-utils
media-sound/pavucontrol
media-sound/playerctl
media-sound/pulseaudio
media-sound/pulseaudio-modules-bt
media-sound/spotify
media-video/vlc
net-im/slack
net-im/discord
net-misc/remmina
www-client/google-chrome
www-client/qutebrowser
www-client/firefox
x11-terms/kitty
x11-terms/kitty-terminfo
EOF

# x11-base/xwayland
# games-util/lutris

  echo "gui-apps/waybar network popups tray wifi" >> /etc/portage/package.use/wayland
  update_use "vulkan gles2"

  cat <<-EOF >>/etc/portage/package.accept_keywords/gui
x11-terms/kitty ~amd64
x11-terms/kitty-terminfo ~amd64
app-crypt/keybase ~amd64
app-editors/vscode ~amd64
games-emulation/higan ~amd64
gui-apps/waybar ~amd64
media-sound/pulseaudio-modules-bt  ~amd64
net-im/slack ~amd64
net-im/teams ~amd64
www-client/qutebrowser ~amd64
x11-base/xwayland ~amd64
dev-python/adblock ~amd64
dev-util/maturin ~amd64
dev-libs/date ~amd64
EOF
}

configure_wm() {
  eselect repository enable steam-overlay
}

do_emerge() {
  emerge --newuse --changed-use --update --deep --quiet-build --complete-graph --autounmask-write --autounmask-continue @world
}

do_cleanup() {
  perl-cleaner --all
  emerge --depclean  --verbose
}

check_is_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
  fi
}

usage() {
  echo -e "install.sh\\n\\tThis script sets up a gentoo system\\n"
  echo "Usage:"
  echo "  prepare                             - Prepare new maching for first boot"
  echo "  chrooted                            - Initial chroot installation (this is run by prepare)"
  echo "  profile                             - Sets the desktop/systemd profile"
  echo "  base                                - Installs base software"
  echo "  wm                                  - Installs GUI environment"
  echo "  laptop                              - Setup up laptop specific settings"
}

main() {
  local cmd=$1

  set -u

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
    setup_network
  elif [[ $cmd == "profile" ]]; then
    setup_hostname
    setup_profile
    bring_up_to_baseline
  elif [[ $cmd == "base" ]]; then
    select_base
    do_emerge
    do_cleanup
  elif [[ $cmd == "wm" ]]; then
    select_wm
    do_emerge
    configure_wm
    do_cleanup
  elif [[ $cmd == "laptop" ]]; then
    select_laptop
    do_emerge
    configure_laptop
    do_cleanup
  else
    usage
  fi
}

main "$@"
