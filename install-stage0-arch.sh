#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-arch.sh

set -eo pipefail

export TARGET_USER=${TARGET_USER:-casey}
export DOTFILESBRANCH=${DOTFILESBRANCH:-master}
export GRAPHICS=${GRAPHICS:-intel}
export SWAPSIZE=${SWAPSIZE:-32}
# export HOSTNAME
# export SSID=set this
# export WPA_PASSPHRASE=set this

###################################################################################################
###
### The next functions are for partitioning, filesystems and then calling this script in chroot
###
###################################################################################################

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
  # $SWAPSIZE GiB swap
  # the rest of the disk ZFS /,/home,etc
  SWAP_OFFSET=$((${SWAPSIZE}*1024 + 1537))
  parted -s -a optimal -- "/dev/disk/by-id/${DISK}" \
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
  mkfs.fat -F32 "/dev/disk/by-id/${DISK}-part1"

  echo "rpool will ask for a passphrase"
  zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O encryption=on \
    -O keyformat=passphrase \
    -O canmount=off \
    -O devices=off \
    -m none \
    -R /mnt/os \
    rpool \
    "/dev/disk/by-id/${DISK}-part4"

  zfs create -o mountpoint=none rpool/root
  zfs create -o mountpoint=/ -o canmount=noauto rpool/root/arch
  zpool set bootfs=rpool/root/arch rpool

  zfs create -o mountpoint=/var/log        rpool/log
  zfs create -o mountpoint=/var/lib/docker rpool/docker
  zfs set quota=100G rpool/docker
  zfs create -o mountpoint=/usr/local rpool/usrlocal
  zfs create rpool/opt

  zfs create -o mountpoint=none -o canmount=off rpool/data
  zfs create -o mountpoint=/home rpool/data/home
  zfs create -o mountpoint=/root rpool/data/home/root
  chmod 700 /mnt/os/root

  zpool create -f -d \
    -o ashift=12 \
    -o cachefile= \
    -m none \
    -R /mnt/os \
    bpool \
    "/dev/disk/by-id/${DISK}-part2"

  zfs create -o canmount=off bpool/boot
  zfs create -o mountpoint=/boot -o canmount=noauto bpool/boot/arch

  mkswap -f "/dev/disk/by-id/${DISK}-part3"
  swapon "/dev/disk/by-id/${DISK}-part3"

  zpool status
  zfs list

  echo "***"
  echo "*** Exporting and reimporting datasets to validate them"
  echo "*** You will be prompted for rpool passphrase"
  echo "***"

  zpool export -a
  zpool import -R /mnt/os -a
  zfs load-key rpool
  zfs mount rpool/root/arch
  zfs mount bpool/boot/arch

  zfs mount -a

  echo "***"
  echo "*** ZFS imported and mounted"
  echo "***"
}

prepare_chroot() {
  echo "***"
  echo "*** Preparing for chrooting"
  echo "***"
  # prepare for chroot
  cd /mnt/os
  mkdir boot/efi
  mount "/dev/disk/by-id/${DISK}-part1" boot/efi

  pacstrap /mnt base linux linux-firmware

  mkdir -p etc/zfs
  cp /etc/zfs/zpool.cache etc/zfs

  cp --dereference /etc/resolv.conf etc/

  genfstab -U -p /mnt/os | grep -e '/dev/sd' -e '# bpool' -A 1 | grep -v -e "^--$" > etc/fstab
}

do_chroot() {
  echo "***"
  echo "Chrooting"
  echo "***"
  cd ~
  SCRIPTNAME=$(basename "$0")
  PATHNAME=$(dirname "$0")
  cp "${PATHNAME}/${SCRIPTNAME}" /mnt/os/install-stage0.sh
  cd /mnt/os
  env -i HOME=/root \
    TERM=$TERM \
    DISK=$DISK \
    TARGET_USER=$TARGET_USER \
    HOSTNAME=$HOSTNAME \
    arch-chroot . bash -l -c "./install-stage0.sh chrooted"
  }

cleanup_chroot() {
  echo "***"
  echo "Cleaning up"
  echo "***"
  cd /
  umount /mnt/os/boot/efi
  zfs umount -a
  swapoff /dev/disk/by-id/${DISK}-part3
  zpool export -a
  echo "***"
  echo "Finished with the initial setup."
  echo "***"
}

###################################################################################################
###
### The next functions are for minimum setup in a chrooted env before rebooting
###
###################################################################################################

setup_timezone() {
  echo "***"
  echo "Setting Timezone"
  echo "***"
  ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
  hwclock --systohc
}

setup_locale() {
  echo "***"
  echo "Setting english utf8 locale"
  echo "***"
  sed -i '/en_US.UTF-8/ s/^#\s*//' /etc/locale.gen
  sed -i '/ro_RO.UTF-8/ s/^#\s*//' /etc/locale.gen
  locale-gen
  echo "LANG=\"en_US.UTF-8\"" >> /etc/locale.conf
}

setup_hostname() {
  echo "***"
  echo "Setup hostname"
  echo "***"
  # cant run this until after first boot
  echo "${HOSTNAME}" > /etc/hostname
  echo "127.0.1.1 ${HOSTNAME}" >> /etc/hosts
}

setup_network() {
  echo "***"
  echo "Setting up dhcp for ethernet interfaces."
  echo "***"

  pacman -S iproute2 iw wpa_supplicant systemd-networkd

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

setup_user() {
  echo "***"
  echo "Setting up user account for ${TARGET_USER}, please set a password"
  echo "***"
  pacman -S zsh sudo
  TARGET_USER=${TARGET_USER:-casey}
  useradd -m -s /bin/zsh -G wheel ${TARGET_USER}
  passwd ${TARGET_USER}
  setup_sudo
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
  mkdir -p /etc/portage/sets/base
  cat <<-EOF >>/etc/portage/sets/base
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
  cat <<-EOF >>/etc/portage/sets/laptop
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
  cat <<-EOF >>/etc/portage/sets/gui
x11-drivers/xf86-video-intel
x11-libs/libva-intel-driver
x11-libs/libva-intel-media-driver
EOF
  echo "x11-drivers/xf86-video-intel dri sna tools udev uxa xvmc" >> /etc/portage/package.use/video
      ;;
    "geforce")
      set_video_cards "nvidia"
  cat <<-EOF >>/etc/portage/sets/gui
x11-drivers/nvidia-drivers
EOF
      ;;
    "optimus")
      set_video_cards "nvidia intel"
  cat <<-EOF >>/etc/portage/sets/gui
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

  cat <<-EOF >>/etc/portage/sets/gui
app-crypt/keybase
app-editors/vscode
app-misc/neofetch
app-select/eselect-repository
dev-libs/weston
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
net-im/teams
net-misc/remmina
www-client/google-chrome
www-client/qutebrowser
www-client/firefox
x11-terms/kitty
x11-terms/kitty-terminfo
EOF

# x11-base/xwayland
# games-util/lutris

  echo "dev-libs/weston drm wayland-compositor xwayland" >> /etc/portage/package.use/wayland
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

install_steam() {
  emerge --verbose games-util/steam-launcher
}

do_emerge() {
  emerge --newuse --changed-use --update --deep --quiet-build --complete-graph --autounmask-write --autounmask-continue @$1
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
  echo "  steam                               - Setup steam"
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
    echo "***"
    echo "*** ALERT: reboot and run insall-stage0.sh base"
    echo "***"
  elif [[ $cmd == "chrooted" ]]; then
    setup_timezone
    setup_locale
    setup_network
    setup_user
  elif [[ $cmd == "profile" ]]; then
    setup_hostname
    setup_profile
    bring_up_to_baseline
  elif [[ $cmd == "base" ]]; then
    select_base
    do_emerge base
    do_cleanup
  elif [[ $cmd == "wm" ]]; then
    select_wm
    do_emerge gui
    configure_wm
    do_cleanup
  elif [[ $cmd == "laptop" ]]; then
    select_laptop
    do_emerge laptop
    configure_laptop
    do_cleanup
  elif [[ $cmd == "steam" ]]; then
    install_steam
    do_cleanup
  else
    usage
  fi
}

main "$@"
