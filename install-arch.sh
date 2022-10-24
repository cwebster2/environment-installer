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

source ./common.sh

install_from_arch() {
  arch_install "$*"
}

install_from_aur() {
  aur_install_by_user "${TARGET_USER}" "$*"
}

initialize_pacman() {
  pacman -Syu --noconfirm
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

  (
    set +e
    install_from_aur \
      flashrom-git \
      fwupd-git
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

  if [[ $cmd == "base" ]]; then
    check_is_sudo
    initialize_pacman
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
