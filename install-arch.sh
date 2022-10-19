#!/usr/bin/env bash

# curl -o install-stage0.sh https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-arch.sh

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

prepare_chroot() {
  echo "***"
  echo "*** Preparing for chrooting"
  echo "***"
  # prepare for chroot
  cd /mnt/os
  mkdir efi
  mkdir boot
  mount "/dev/disk/by-id/${DISK}-part1" /mnt/os/efi
  mkdir -p /mnt/os/efi/EFI/arch
  mount --bind /mnt/os/efi/EFI/arch /mnt/os/boot

  pacstrap /mnt/os \
    base \
    linux \
    linux-headers \
    dkms \
    linux-firmware \
    archlinux-keyring \
    iproute2 \
    iw \
    refind \
    efibootmgr \
    networkmanager \
    zsh \
    kitty-terminfo \
    sudo

  cp --dereference /etc/resolv.conf etc/

  genfstab -U -p /mnt/os | grep -e '/dev/' -A 1 | grep -v -e "^--$" > /mnt/os/etc/fstab
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
  env -i HOME="/root" \
    TERM="$TERM" \
    DISK="$DISK" \
    TARGET_USER="$TARGET_USER" \
    HOSTNAME="$HOSTNAME" \
    SSID="$SSID" \
    WPA_PASSPHRASE="$WPA_PASSPHRASE" \
    arch-chroot /mnt/os bash -l -c "./install-stage0.sh chrooted"

  systemctl enable zfs.target --root=/mnt/os
  systemctl enable zfs-import-cache --root=/mnt/os
  systemctl enable zfs-mount --root=/mnt/os
  systemctl enable zfs-import.target --root=/mnt/os
  systemctl enable systemd-timesyncd --root=/mnt/os
  systemctl disable systemd-networkd-wait-online.service --root=/mnt/os

  echo "***"
  echo "*** Setting up next stage to run on user login"
  echo "***"
  cat <<-EOF > "/mnt/os/home/${TARGET_USER}/.zshrc"
export INSTALLER=${INSTALLER}
export DOTFILESBRANCH=${DOTFILESBRANCH}
export INSTALLER=${INSTALLER}
export GRAPHICS=${GRAPHICS}
export SSID=${SSID}
export WPA_PASSPHRASE=${WPA_PASSPHRASE}
nmcli dev wifi connect ${SSID} password ${WPA_PASSPHRASE}
./install.sh 2>&1 | tee install.log
EOF
}

cleanup_chroot() {
  echo "***"
  echo "Cleaning up"
  echo "***"
  cd /
  rm /mnt/os/install-stage0.sh
  echo "/efi/EFI/arch /boot none defaults,bind 0 0" >> /mnt/os/etc/fstab
  mount | grep "mnt/os"
  umount /mnt/os/boot
  umount /mnt/os/efi
  zfs umount -a
  swapoff "/dev/disk/by-id/${DISK}-part2"
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

setup_pacman_keys() {
  echo "***"
  echo "*** Setting up pacman-key"
  echo "***"

  pacman-key --init
  (
    set +e
    pacman-key --populate archlinux || true
    # pacman-key --keyserver hkps://keyserver.ubuntu.com --refresh-keys || true
  )
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

  # sbsigntools?
  refind-install

  cat <<-EOF > /boot/refind_linux.conf
  "Boot with standard options"  "zfs=bootfs rw quiet splash vt.global_cursor_default=0 iomem=relaxed resume=${UUID} add_efi_memmap initrd=EFI\arch\initramfs-%v.img"
  "Boot without plymouth" "zfs=bootfs rw iomem=relaxed resume=${UUID} add_efi_memmap initrd=EFI\arch\initramfs-%v.img"
  "Boot with fallback initramfs"  "zfs=bootfs rw quiet splash vt.global_cursor_default=0 resume={UUID} add_efi_memmap initrd=EFI\arch\initramfs-%v-fallback.img"
  "Boot to terminal"   "zfs=bootfs rw add_efi-memmap iomem=relaxed initrd=EFI\arch\initramfs-%v.img systemd.unit=multi-user.target"
EOF

  mkdir -p /efi/EFI/refind/theme
  curl -sLo /efi/EFI/refind/theme/banner.png https://raw.githubusercontent.com/cwebster2/environment-installer/master/wallpaper.png
  cat <<-EOF > /efi/EFI/refind/refind.conf
  timeout 5
  use_nvram false
  banner theme/banner.png
  resolution 1920 1080
  use_graphics_for linux
  scan_all_linux_kernels true
  extra_kernel_version_strings linux-hardened,linux-zen,linux-lts,linux
  showtools shell, bootorder, gdisk, memtest, mok_tool, about, hidden_tags, reboot, exit, firmware, fwupdate
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

  echo "options zfs zfs_arc_max=4294967296" >> /etc/modprobe.d/zfs.conf
  echo "options zfs zfs_vdev_trim_max_active=1" >> /etc/modprobe.d/zfs.conf
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

enable_autologin() {
  echo "***"
  echo "*** Setting up autologin to handle the first reboot"
  echo "***"
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat <<-EOF >> /etc/systemd/system/getty@tty1.service.d/override.conf
  [Service]
  ExecStart=
  ExecStart=-/usr/bin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF
}

disable_autologin() {
  echo "***"
  echo "*** Setting up autologin to handle the first reboot"
  echo "***"
  rm -f /etc/systemd/system/getty@tty1.service.d/override.conf || true
}

install_base() {
  echo "***"
  echo "*** Starting Base Install Target"
  echo "***"
# brlaser \
# tcptraceroute \
  install_from_arch \
    automake \
    bc \
    bluez \
    bluez-utils \
    bolt \
    bridge-utils \
    bzip2 \
    ca-certificates \
    cmake \
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
    libfido2 \
    libssh2 \
    lm_sensors \
    lsb-release \
    lshw \
    lsof \
    make \
    man \
    neovim \
    ninja \
    net-tools \
    nftables \
    openssh \
    pam-u2f \
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
    tree-sitter \
    ueberzug \
    unrar \
    unzip \
    w3m \
    wget \
    xz \
    yubico-pam \
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
  echo "*** Installing from AUR"
  echo "***"

  install_from_aur \
    flashrom-git \
    fwupd-git

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

  cp /usr/lib/fwupd/efi/fwupdx64.efi /efi/EFI/tools

  systemctl enable --now docker
  systenctl enable --now nftables

  echo "***"
  echo "*** Base install target finiished"
  echo "***"
}

install_laptop() {
  echo "***"
  echo "*** Installing Laptop mode tools"
  echo "***"

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
      install_from_arch vulkan-intel intel-media-driver
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
    libva-mesa-driver \
    materia-gtk-theme \
    mediainfo \
    mesa-vdpau \
    neofetch \
    odt2txt \
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
    rofi \
    vlc \
    vscode \
    vulkan-mesa-layers \
    webp-pixbuf-loader

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
        sddm \
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
        wl-clipboard \
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
  mount /boot
  sed -i 's/^MODULES=.*$/MODULES=(i915)/' /etc/mkinitcpio.conf
  sed -i 's/^HOOKS=.*$/HOOKS=(base udev plymouth autodetect modconf block keyboard plymouth-zfs filesystems resume)/' /etc/mkinitcpio.conf
  plymouth-set-default-theme -R dark-arch
}

setup_greeter() {
  echo "***"
  echo "*** Setting up greeter"

  mkdir -p /etc/greetd

  echo "*** environments"
  cat <<-EOF >/etc/greetd/environments
  sway-run
  bash
EOF

  echo "*** config.toml"
  cat <<-EOF >/etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
# command = "agreety --cmd $SHELL"
command = "sway --config /etc/greetd/sway-config"
user = "greeter"

EOF

  echo "*** sway-config"
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

  echo "*** gtkgreet css"
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

  echo "*** sway-run"
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

  echo "*** wayland_enablement"
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

  echo "*** wallpaper"
  curl -sLo /etc/greetd/wallpaper.jpg https://raw.githubusercontent.com/cwebster2/dotfiles/main/.config/i3/wallpaper.jpg
  chown -R greeter /etc/greetd
  echo "***"
}

install_from_arch() {
  pacman --needed --noconfirm -S $*
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
  case $GRAPHICS in
    "intel")
      install_from_arch lib32-vulkan-intel
      ;;
    "geforce")
      install_from_arch lib32-nvidia-utils
      ;;
    "optimus")
      install_from_arch lib32-nvidia-utils
      ;;
    *)
      echo "You need to specify whether it's intel, geforce or optimus"
      exit 1
      ;;
  esac

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
    setup_user
    setup_pacman_keys
    add_arch_zfs
    setup_boot
    get_installer
    enable_autologin
  elif [[ $cmd == "base" ]]; then
    check_is_sudo
    disable_autologin
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
