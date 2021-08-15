#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-arch.sh

set -eo pipefail

export TARGET_USER=${TARGET_USER:-casey}
export DOTFILESBRANCH=${DOTFILESBRANCH:-master}
export GRAPHICS=${GRAPHICS:-intel}
export SWAPSIZE=${SWAPSIZE:-32}
export HOSTNAME=${HOSTNAME:-${TARGET_USER}book}
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
    -o cachefile= \
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
  zfs create -o mountpoint=/boot bpool/boot/arch

  mkswap -f "/dev/disk/by-id/${DISK}-part3"
  swapon "/dev/disk/by-id/${DISK}-part3"

  zpool status
  zfs list

  echo "***"
  echo "*** Exporting rpool and bpool"
  echo "***"

  zpool export -a

  echo "***"
  echo "*** Reimporting pools to validate them"
  echo "*** You will be prompted for rpool passphrase"
  echo "***"

  zpool import -R /mnt/os rpool
  zfs load-key rpool
  zfs mount rpool/root/arch
  zfs mount -a
  zpool import -R /mnt/os bpool
  zfs mount -a

  echo "***"
  echo "*** ZFS pools imported and datasets mounted"
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

  pacstrap /mnt/os \
    base \
    linux \
    linux-headers \
    dkms \
    linux-firmware \
    archlinux-keyring \
    iproute2 \
    iw \
    wpa_supplicant \
    grub \
    efibootmgr \
    zsh \
    kitty-terminfo \
    sudo

  cp --dereference /etc/resolv.conf etc/

  genfstab -U -p /mnt/os | grep -e '/dev/sd' -A 1 | grep -v -e "^--$" > etc/fstab
  # genfstab -U -p /mnt/os | grep -e '/dev/sd' -e '# bpool' -A 1 | grep -v -e "^--$" > etc/fstab
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
    SSID=$SSID \
    WPA_PASSPHRASE=$WPA_PASSPHRASE \
    arch-chroot /mnt/os bash -l -c "./install-stage0.sh chrooted"

  systemctl enable zfs.target --root=/mnt/os
  systemctl enable zfs-import-cache --root=/mnt/os
  systemctl enable zfs-mount --root=/mnt/os
  systemctl enable zfs-import.target --root=/mnt/os
  systemctl enable wpa_supplicant@wlan0.service --root=/mnt/os
  systemctl enable systemd-networkd.service --root=/mnt/os
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
}

add_arch_zfs() {
  echo "***"
  echo "*** Adding archzfs repo"
  echo "***"

  pacman-key init
  pacman-key --recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76
  pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

  cat <<-EOF >>/etc/pacman.conf
[archzfs]
SigLevel = Required DatabaseOptional
Server = https://zxcvfdsa.com/archzfs/\$repo/\$arch
EOF
   pacman -Syyu
   pacman --noconfirm -S zfs-dkms
}

setup_boot() {
  echo "***"
  echo "*** Setting up bootloader"
  echo "***"
  sed -i 's/^HOOKS=.*$/HOOKS=(base udev autodetect modconf block keyboard zfs filesystems resume)/' /etc/mkinitcpio.conf
  rm -f /etc/hostid
  zgenhostid $(hostid)
  zpool set cachefile=/etc/zfs/zpool.cache rpool
  zpool set cachefile=/etc/zfs/zpool.cache bpool
  mkinitcpio -P
  echo 'GRUB_CMDLINE_LINUX="root=ZFS=rpool/root/arch"' >> /etc/default/grub
  ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
  ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg
}

setup_user() {
  echo "***"
  echo "Setting up user account for ${TARGET_USER}, please set a password"
  echo "***"
  TARGET_USER=${TARGET_USER:-casey}
  useradd -m -s /bin/zsh -G wheel ${TARGET_USER}
  passwd ${TARGET_USER}
  # this is so the zsh setup doesn't bother us until dotfiles are installed
  touch /home/${TARGET_USER}/.zshrc
  chown ${TARGET_USER} /home/${TARGET_USER}/.zshrc
  setup_sudo
}

setup_sudo() {
  echo "***"
  echo "Setting up sudo for ${TARGET_USER}"
  echo "***"
  gpasswd -a "$TARGET_USER" systemd-journal
  gpasswd -a "$TARGET_USER" systemd-network

  { \
    echo -e "Defaults	secure_path=\"/usr/local/go/bin:/home/${TARGET_USER}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/bcc/tools:/home/${TARGET_USER}/.cargo/bin\""; \
    echo -e 'Defaults	env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"'; \
    echo -e "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"; \
    echo -e "${TARGET_USER} ALL=NOPASSWD: /sbin/ifconfig, /sbin/ifup, /sbin/ifdown, /sbin/ifquery"; \
  } > "/etc/sudoers.d/${TARGET_USER}"
}

install_base() {
  echo "***"
  echo "*** Starting Base Install Target"
  echo "***"
# brlaser \
# tcptraceroute \
# docker-credential-helpers \
  pacman --noconfirm -S \
    automake \
    bc \
    bluez \
    bluez-utils \
    bolt \
    bridge-utils \
    bzip2 \
    ca-certificates \
    coreutils \
    ctags \
    curl \
    base-devel \
    docker \
    docker-compose \
    expect \
    file \
    findutils \
    fwupd \
    gcc \
    git \
    github-cli \
    gnu-netcat \
    gnupg \
    grep \
    gzip \
    htop \
    iproute2 \
    iw \
    iwd \
    jq \
    less \
    libssh2 \
    lm_sensors \
    lsb-release \
    lshw \
    lsof \
    make \
    man \
    neovim \
    net-tools \
    nftables \
    nftables \
    openssh \
    pinentry \
    pkgconf \
    prettyping \
    psmisc
    ranger \
    rsync \
    strace \
    tar \
    the_silver_searcher \
    traceroute \
    unrar \
    unzip \
    wget \
    xz \
    zip \
    zsh

  echo "***"
  echo "*** Setting up yay for AUR packages"
  echo "***"
  (
    pushd /usr/src 2>/dev/null
    git clone https://aur.archlinux.org/yay.git
    cd yay
    su - ${TARGET_USER} -c 'cd /usr/src/yay; makepkg --noconfirm -sri'
    popd
  )

  echo "***"
  echo "*** Base install target finiished"
  echo "***"
}

install_laptop() {

  pacman --noconfirm -S \
    thermald \
    acpid \
    ethtool

  install_from_aur laptop-mode-tools

  # https://wiki.gentoo.org/wiki/Power_management/Guide
  echo "ENABLE_LAPTOP_MODE_ON_BATTERY=1" >> /etc/laptop-mode/conf.d/cpufreq.conf

  systemctl enable thermald
  systemctl enable acpid
  systemctl enable laptop-mode.service

  cat <<-EOF >>/etc/udev/rules.d/99-lowbat.rules
# Suspend the system when battery level drops to 5% or lower
SUBSYSTEM=="power_supply", ATTR{status}=="Discharging", ATTR{capacity}=="[0-5]", RUN+="/usr/bin/systemctl hibernate"
EOF
}

install_gui() {
  echo "***"
  echo "*** Beginning install for GUI Target"
  echo "***"
  case $GRAPHICS in
    "intel")
      pacman --noconfirm -S vulkan-intel libva-intel-driver xf86-video-intel
      ;;
    "geforce")
      pacman --noconfirm -S nvidia-drivers
      ;;
    "optimus")
      pacman --noconfirm -S nvidia-drivers bbswitch-dkms
      ;;
    *)
      echo "You need to specify whether it's intel, geforce or optimus"
      exit 1
      ;;
  esac

  pacman --noconfirm -S \
    alsa-utils \
    discord \
    firefox \
    emacs \
    flameshot \
    gucharmap \
    inkscape \
    kdeconnect \
    keybase \
    kitty \
    neofetch \
    pavucontrol \
    playerctl \
    pulseaudio \
    qutebrowser \
    remmina \
    sway \
    swaybg \
    swayidle \
    swaylock \
    vlc \
    vscode


  install_from_aur \
    google-chrome \
    spotify \
    plymouth-zfs \
    greetd

  sed -i '/^HOOKS=.*$/HOOKS=(base udev autodetect modconf block keyboard plymouth-zfs filesystems resume)/' /etc/mkinitcpio.conf
  mkinitcpio -P

  echo "***"
  echo "*** GUI Install Target Finished"
  echo "***"
}

install_from_aur() {
  # yay doesn't like being root
  su - ${TARGET_USER} -c "yay --noconfirm -S $*"
}

install_games() {
  echo "***"
  echo "*** Installing games target"
  echo "***"
  pacman --noconfirm -S \
    steam \
    higan
  install_from_aur lutris-git
}

do_cleanup() {
  echo "***"
  echo "*** Cleaning up"
  echo "***"
  pacman -Sc
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
  echo "  base                                - Installs base software"
  echo "  wm                                  - Installs GUI environment"
  echo "  laptop                              - Setup up laptop specific settings"
  echo "  games                               - Setup games"
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
    setup_hostname
    setup_network
    setup_user
    add_arch_zfs
    setup_boot
  elif [[ $cmd == "base" ]]; then
    check_is_sudo
    install_base
    do_cleanup
    echo "***"
    echo "*** Done"
    echo "***"
  elif [[ $cmd == "wm" ]]; then
    check_is_sudo
    install_wm
    do_cleanup
    echo "***"
    echo "*** Done"
    echo "***"
  elif [[ $cmd == "laptop" ]]; then
    check_is_sudo
    install_laptop
    do_cleanup
    echo "***"
    echo "*** Done"
    echo "***"
  elif [[ $cmd == "games" ]]; then
    check_is_sudo
    install_games
    do_cleanup
    echo "***"
    echo "*** Done"
    echo "***"
  else
    usage
  fi
}

main "$@"
