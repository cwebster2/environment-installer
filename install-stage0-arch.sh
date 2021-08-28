#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-arch.sh

set -eo pipefail

export TARGET_USER=${TARGET_USER:-casey}
export DOTFILESBRANCH=${DOTFILESBRANCH:-main}
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
  SWAP_OFFSET=$((${SWAPSIZE}*1024 + 513))
    # mkpart boot 513 1537 \
  parted -s -a optimal -- "/dev/disk/by-id/${DISK}" \
    unit mib \
    mklabel gpt \
    mkpart esp 1 513 \
    mkpart swap 513 ${SWAP_OFFSET} \
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
  zfs create -o mountpoint=/ -o canmount=noauto rpool/root/arch
  zpool set bootfs=rpool/root/arch rpool

  echo "*** /var/log"
  zfs create -o mountpoint=/var/log rpool/log

  echo "*** /var/lib/docker"
  zfs create \
    -o mountpoint=/var/lib/docker \
    -o dedup=sha512 \
    -o quota=10G \
    rpool/docker

  echo "*** /usr/local"
  zfs create -o mountpoint=/usr/local rpool/usrlocal
  echo "*** /opt"
  zfs create rpool/opt

  zfs create -o mountpoint=none -o canmount=off rpool/data
  echo "*** /home"
  zfs create -o mountpoint=/home rpool/data/home
  zfs create -o mountpoint=/root rpool/data/home/root
  chmod 700 /mnt/os/root
  echo "***"

  echo "***"
  echo "*** Creating swap"
  echo "***"
  mkswap -f "/dev/disk/by-id/${DISK}-part2"
  swapon "/dev/disk/by-id/${DISK}-part2"

  zpool status
  zfs list

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

  mount | grep /mnt/os

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
  mkdir boot
  mount "/dev/disk/by-id/${DISK}-part1" boot

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
    refind \
    efibootmgr \
    zsh \
    kitty-terminfo \
    sudo

  cp --dereference /etc/resolv.conf etc/

  genfstab -U -p /mnt/os | grep -e '/dev/sd' -A 1 | grep -v -e "^--$" > etc/fstab
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
  systemctl enable systemd-timesyncd --root=/mnt/os
  systemctl disable systemd-networkd-wait-online.service --root=/mnt/os
}

cleanup_chroot() {
  echo "***"
  echo "Cleaning up"
  echo "***"
  cd /
  rm /mnt/os/install-stage0.sh
  umount /mnt/os/boot
  zfs umount -a
  swapoff /dev/disk/by-id/${DISK}-part2
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

setup_pacman_keys() {
  echo "***"
  echo "*** Setting up pacman-key"
  echo "***"

  pacman-key --init
  # pacman-key --refresh-keys
}

add_arch_zfs() {
  echo "***"
  echo "*** Adding archzfs repo"
  echo "***"
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
  # zpool set cachefile=/etc/zfs/zpool.cache bpool
  mkinitcpio -P
  # get uuid of the swap disk
  UUID=$(cat /etc/fstab | grep swap | awk '{print $1}')

  # setup the bootloader
  # echo "GRUB_CMDLINE_LINUX=\"root=ZFS=rpool/root/arch resume=${UUID}\"" >> /etc/default/grub
  # sed -i "s/^GRUB_PRELOAD_MODULES=.*$/GRUB_PRELOAD_MODULES=\"part_gpt\"/" /etc/default/grub
  # ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
  # ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg

  # sbsigntools?
  refind-install

  # loglevel=3 quiet
  cat <<-EOF > /boot/refind_linux.conf
  "Boot with standard options"  "zfs=bootfs rw resume=${UUID} add_efi_memmap initrd=initramfs-%v.img"
  "Boot with fallback initramfs"  "zfs=bootfs rw resume=${UUID} add_efi_memmap initrd=initramfs-%v-fallback.img"
  "Boot to terminal"   "zfs=bootfs rw add_efi-memmap initrd=initramfs-%v.img systemd.unit=multi-user.target"
EOF

  cp /boot/EFI/refind/refind.conf /boot/EFI/refind/refind.conf.orig
  mkdir -p /boot/EFI/refind/icons/local
  curl -sLo /boot/EFI/refind/icons/local/banner.jpg https://raw.githubusercontent.com/cwebster2/environment-installer/master/wallpaper.jpg
  cat <<-EOF > /boot/EFI/refind/refind.conf
  timeout 5
  use_nvram false
  banner icons/local/banner.jpg
  #resolution max
  #use_graphics_for linux
  scan_all_linux_kernels true
  extra_kernel_version_strings linux-hardened,linux-zen,linux-lts,linux
EOF

  mkdir -p /etc/pacman.d/hooks
  cat <<-EOF >> /etc/pacman.d/hooks/refind.hook
  [Trigger]
  Operation=Upgrade
  Type=Package
  Target=refind

  [Action]
  Description = Updating rEFInd on ESP
  When=PostTransaction
  Exec=/usr/bin/refind-install
EOF

  cat <<-EOF >> /etc/systemd/logind.conf
  HandleLidSwitch=hibernate
  HandleLidSwitchExternalPower=suspend-then-hibernate
  HandleLidSwitchDocked=suspend-then-hibernate
EOF

  cat <<-EOF >> /etc/systemd/sleep.conf
  HibernateDelaySec=30min
EOF
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

  # Setup ~/Downloads as a tmpfs
  mkdir -p "/home/${TARGET_USER}/Downloads"
  chown ${TARGET_USER}:${TARGET_USER} "/home/${TARGET_USER}/Downloads"
  echo -e "\\n# tmpfs for downloads\\ntmpfs\\t/home/${TARGET_USER}/Downloads\\ttmpfs\\tnodev,nosuid,size=2G\\t0\\t0" >> /etc/fstab
  mount "/home/${TARGET_USER}/Downloads"
  chown ${TARGET_USER}:${TARGET_USER} "/home/${TARGET_USER}/Downloads"
  umount "/home/${TARGET_USER}/Downloads"
}

get_installer() {
  echo "***"
  echo "*** Getting stage 1 installer for post-reboot"
  echo "***"
  curl -sLo "/home/${TARGET_USER}/install.sh" https://raw.githubusercontent.com/cwebster2/environment-installer/master/install.sh
  chmod 755 "/home/${TARGET_USER}/install.sh"
  chown ${TARGET_USER}:${TARGET_USER} "/home/${TARGET_USER}/install.sh"
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
  install_from_arch \
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
    fuse \
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
    psmisc \
    ranger \
    rsync \
    strace \
    tar \
    the_silver_searcher \
    traceroute \
    unrar \
    unzip \
    w3m \
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
    chown -R ${TARGET_USER} yay
    cd yay
    su - ${TARGET_USER} -c 'cd /usr/src/yay; makepkg --noconfirm -sri'
    popd
  )

  echo "***"
  echo "*** Setting up ${TARGET_USER} to use docker and enable zfs"
  echo "***"
  # Setup Docker
  gpasswd -a ${TARGET_USER} docker
  mkdir -p /etc/docker
  cat <<-EOF >>/etc/docker/daemon.json
{
  "storage-driver": "zfs"
}
EOF

  install_from_aur docker-credential-secretservice

  systemctl enable docker
  systemctl start docker

  echo "***"
  echo "*** Base install target finiished"
  echo "***"
}

install_laptop() {

  install_from_arch \
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
      install_from_arch vulkan-intel libva-intel-driver xf86-video-intel
      export WM=sway
      ;;
    "geforce")
      install_from_arch nvidia-drivers
      export WM=i3
      ;;
    "optimus")
      install_from_arch nvidia-drivers bbswitch-dkms
      export WM=i3
      ;;
    *)
      echo "You need to specify whether it's intel, geforce or optimus"
      exit 1
      ;;
  esac

  install_from_arch \
    alsa-utils \
    discord \
    easyeffects \
    emacs \
    ffmpegthumbnailer \
    firefox \
    flameshot \
    gtk3 \
    gtk4 \
    gucharmap \
    highlight \
    inkscape \
    kdeconnect \
    keybase \
    kitty \
    materia-gtk-theme \
    mediainfo \
    neofetch \
    pavucontrol \
    pipewire \
    pipewire-alsa \
    pipewire-jack \
    pipewire-media-session \
    pipewire-pulse \
    poppler \
    qt5ct \
    qutebrowser \
    remmina \
    vlc \
    vscode \
    wl-clipboard \
    xdg-desktop-portal

  install_from_aur \
    azuredatastudio-bin \
    google-chrome \
    noise-suppression-for-voice \
    plymouth-theme-dark-arch \
    plymouth-zfs \
    spotify

  case $WM in
    "i3")
      install_from_arch \
        gdm \
        i3-wm \
        i3-lock

      install_from_aur \
        i3lock-fancy

      systemctl enable gdm
      ;;
    "sway")
      install_from_arch \
        qt5-wayland \
        qt6-wayland \
        sway \
        swaybg \
        swayidle \
        xdg-desktop-portal-wlr \
        xorg-xwayland

      install_from_aur \
        greetd \
        greetd-gtkgreet \
        swaylock-effects-git

      setup_greeter

      systemctl enable greetd
      ;;
    *)
      echo "You need to specify WM as i3 or sway"
      exit 1
      ;;
  esac

  setup_bootlogo

  echo "***"
  echo "*** GUI Install Target Finished"
  echo "***"
}

setup_bootlogo() {
  echo "***"
  echo "*** Setting up plymouth bootlogo"
  echo "***"
  sed -i 's/^HOOKS=.*$/HOOKS=(base udev plymouth autodetect modconf block keyboard plymouth-zfs filesystems resume)/' /etc/mkinitcpio.conf
  plymouth-set-default-theme -R dark-arch
  mkinitcpio -P
}

setup_greeter() {
  echo "***"
  echo "*** Setting up greeter"
  echo "***"

  mkdir -p /etc/greetd

  cat <<-EOF >/etc/greetd/environments
  sway-run
  bash
EOF

  cat <<-EOF >/etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
# command = "agreety --cmd $SHELL"
command = "sway --config /etc/greetd/sway-config"
user = "greeter"

EOF

  cat <<-EOF >/etc/greetd/sway-config
# `-l` activates layer-shell mode. Notice that `swaymsg exit` will run after gtkgreet.
exec "GTK_THEME=Materia-dark gtkgreet -l -s /etc/greetd/gtkgreet.css; swaymsg exit"

bindsym Mod4+shift+q exec swaynag \
-t warning \
-m 'What do you want to do?' \
-b 'Poweroff' 'systemctl poweroff' \
-b 'Reboot' 'systemctl reboot'

include /etc/sway/config.d/*
EOF

  cat <<-EOF >/etc/greetd/gtkgreet.css
window {
   background-image: url("file:///etc/greetd/wallpaper.jpg");
   background-color: #000000;
   background-size: cover;
   background-position: center;
}

box#body {
   background-color: rgba(0, 0, 0, 0.5);
   border-radius: 10px;
   padding: 50px;
}
EOF

  cat <<-EOF >/usr/local/bin/sway-run
  #!/usr/bin/env bash

  # Session
  export XDG_SESSION_TYPE=wayland
  export XDG_SESSION_DESKTOP=sway
  export XDG_CURRENT_DESKTOP=sway

  source /usr/local/bin/wayland_enablement

  systemd-cat --identifier=sway sway $@
EOF
  chmod 755 /usr/local/bin/sway-run

  cat <<-EOF >/usr/local/bin/wayland_enablement
  #!/usr/bin/env bash
  export MOZ_ENABLE_WAYLAND=1
  export CLUTTER_BACKEND=wayland
  export QT_QPA_PLATFORM=wayland-egl
  export ECORE_EVAS_ENGINE=wayland-egl
  export ELM_ENGINE=wayland_egl
  export SDL_VIDEODRIVER=wayland
  export _JAVA_AWT_WM_NONREPARENTING=1
  export NO_AT_BRIDGE=1
EOF

  chmod 755 /usr/local/bin/wayland_enablement

  curl -sLo /etc/greetd/wallpaper.jpg https://raw.githubusercontent.com/cwebster2/dotfiles/main/.config/i3/wallpaper.jpg
  chown -R greeter /etc/greetd
}

install_from_arch() {
  pacman --noconfirm -S $*
}

install_from_aur() {
  # yay doesn't like being root
  su - ${TARGET_USER} -c "yay --noconfirm -S $*"
}

enable_multilib() {
  echo "***"
  echo "*** Enabling multilib repository"
  echo "***"
  cat <<-EOF >> /etc/pacman.conf
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
  pacman --noconfirm -Syyu
}

install_games() {
  echo "***"
  echo "*** Installing games target"
  echo "***"
  install_from_arch \
    steam \
    higan
  install_from_aur lutris-git
}

do_cleanup() {
  echo "***"
  echo "*** Cleaning up"
  echo "***"
  pacman --noconfirm -Sc
}

get_dotfiles_installer() {
  curl -sLo /home/${TARGET_USER}/install.sh https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh
  chown ${TARGET_USER} /home/${TARGET_USER}/install.sh
  chmod 755 /home/${TARGET_USER}/install.sh
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
  echo "  dotfiles                            - Get dotfiles install.sh"
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
    get_installer
    setup_pacman_keys
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
    install_gui
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
    enable_multilib
    install_games
    do_cleanup
    echo "***"
    echo "*** Done"
    echo "***"
  elif [[ $cmd == "dotfiles" ]]; then
    get_dotfiles_installer
  else
    usage
  fi
}

main "$@"
