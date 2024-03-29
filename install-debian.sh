#!/usr/bin/env bash
set -e
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_LISTBUGS_FRONTEND=none
export TARGET_USER=${TARGET_USER:-casey}

# Choose a user account to use for this installation
get_user() {
  if [ -z "${TARGET_USER-}" ]; then
    mapfile -t options < <(find /home/* -maxdepth 0 -printf "%f\\n" -type d)
    # if there is only one option just use that user
    if [ "${#options[@]}" -eq "1" ]; then
      readonly TARGET_USER="${options[0]}"
      echo "Using user account: ${TARGET_USER}"
      return
    fi

    # iterate through the user options and print them
    PS3='command -v user account should be used? '

    select opt in "${options[@]}"; do
      readonly TARGET_USER=$opt
      break
    done
  fi
}

check_is_sudo() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
  fi
}

setup_sources_min() {
  apt-get update || true
  apt-get install -y \
    apt-transport-https \
    apt-listbugs \
    ca-certificates \
    curl \
    dirmngr \
    gnupg2 \
    lsb-release \
    --no-install-recommends

  # turn off translations, speed up apt update
  mkdir -p /etc/apt/apt.conf.d
  echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/99translations
}

 # sets up apt sources
 setup_sources() {
   setup_sources_min;

   cat <<- EOF > /etc/apt/sources.list
  deb http://httpredir.debian.org/debian sid main contrib non-free
  deb-src http://httpredir.debian.org/debian/ sid main contrib non-free

  deb http://httpredir.debian.org/debian experimental main contrib non-free
  deb-src http://httpredir.debian.org/debian experimental main contrib non-free
EOF

  # yubico
  cat <<- EOF > /etc/apt/sources.list.d/yubico.list
  deb http://ppa.launchpad.net/yubico/stable/ubuntu xenial main
  deb-src http://ppa.launchpad.net/yubico/stable/ubuntu xenial main
EOF

  # tlp: Advanced Linux Power Management
  cat <<- EOF > /etc/apt/sources.list.d/tlp.list
  # tlp: Advanced Linux Power Management
  # http://linrunner.de/en/tlp/docs/tlp-linux-advanced-power-management.html
  deb http://repo.linrunner.de/debian sid main
EOF

  # Create an environment variable for the correct distribution
  CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"
  export CLOUD_SDK_REPO

  # Add the Cloud SDK distribution URI as a package source
  cat <<- EOF > /etc/apt/sources.list.d/google-cloud-sdk.list
  deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main
EOF

  # Import the Google Cloud Platform public key
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -

  # Add the Google Chrome distribution URI as a package source
  cat <<- EOF > /etc/apt/sources.list.d/google-chrome.list
  deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main
EOF

cat <<- EOF > /etc/apt/sources.list.d/keybase.list
  deb http://prerelease.keybase.io/deb stable main
EOF

cat <<- EOF > /etc/apt/sources.list.d/lutris.list
  deb http://download.opensuse.org/repositories/home:/strycore/Debian_Unstable/ ./
EOF

cat <<- EOF > /etc/apt/sources.list.d/microsoft-prod.list
  deb [arch=amd64] https://packages.microsoft.com/debian/10/prod buster main
EOF

cat <<- EOF > /etc/apt/sources.list.d/teams.list
   deb [arch=amd64] https://packages.microsoft.com/repos/ms-teams stable main
EOF

cat <<- EOF > /etc/apt/sources.list.d/vscode.list
   deb [arch=amd64] http://packages.microsoft.com/repos/vscode stable main
EOF

cat <<- EOF > /etc/apt/sources.list.d/slack.list
  deb https://packagecloud.io/slacktechnologies/slack/debian/ jessie main
EOF

cat <<- EOF > /etc/apt/sources.list.d/spotify.list
  deb http://repository.spotify.com stable non-free
EOF

cat <<- EOF > /etc/apt/sources.list.d/github-cli.list
  deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
EOF

  # Import the slack public key
  echo "slack"
  curl -L "https://packagecloud.io/slacktechnologies/slack/gpgkey" 2> /dev/null | apt-key add - &>/dev/null

  # Import the storycore key
  echo "storycore"
  curl http://download.opensuse.org/repositories/home:/strycore/Debian_Unstable/Release.key | apt-key add -

  # Import the keybase key
  echo "keybase"
  curl https://keybase.io/docs/server_security/code_signing_key.asc | apt-key add -

  # Import the spotify keys
  echo "spotify"
  curl -sS https://download.spotify.com/debian/pubkey_0D811D58.gpg | apt-key add -

  # Import the microsoft key
  echo "ms"
  curl -sSL https://packages.microsoft.com/keys/microsoft.asc | apt-key add -

  # Import the Google Chrome public key
  echo "chrome"
  curl https://dl.google.com/linux/linux_signing_key.pub | apt-key add -

  # add the yubico ppa gpg key
  echo "yubi"
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 32CBA1A9

  # github
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg

  # add the tlp apt-repo gpg key
  # apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 6B283E95745A6D903009F7CA641EED65CD4E8809

  # linrunner
  # apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys BF851E76615EF34A

}

base_min() {
  apt-get update || true
  apt-get -y upgrade
  apt-get -y dist-upgrade

  apt-get install -y \
    adduser \
    automake \
    bc \
    bzip2 \
    coreutils \
    dnsutils \
    expect \
    file \
    findutils \
    gcc \
    ninja-build \
    git \
    grep \
    gzip \
    hostname \
    indent \
    iptables \
    iw \
    jq \
    less \
    locales \
    lsof \
    make \
    mount \
    net-tools \
    policykit-1 \
    strace \
    sudo \
    tar \
    tree \
    tzdata \
    unzip \
    wget \
    xz-utils \
    zip \
    --no-install-recommends

  apt -y autoremove
  apt autoclean
  apt clean
}

# installs base packages
# the utter bare minimal shit
base() {
  cat /etc/apt/sources.list
  base_min;

  apt-get update || true
  apt-get -y upgrade

  echo "*** Installing base"
  apt-get install -y \
    apparmor \
    autoconf \
    automake \
    bluez \
    bolt \
    bridge-utils \
    build-essential \
    cgroupfs-mount \
    cmake \
    cpufrequtils \
    curl \
    docker.io \
    doxygen \
    emacs-gtk \
    exuberant-ctags \
    fwupd \
    fwupdate \
    g++ \
    gdm3 \
    gettext \
    gh \
    gnupg-agent \
    google-cloud-sdk \
    htop \
    iproute2 \
    iwd \
    libimobiledevice6 \
    libpam-systemd \
    libsecret-1-dev \
    libssl-dev \
    libtool \
    libtool-bin \
    lm-sensors \
    locate \
    lshw \
    mpd \
    netbase \
    netcat \
    nftables \
    ninja-build \
    pcscd \
    pinentry-curses \
    pkg-config \
    prettyping \
    printer-driver-brlaser \
    psmisc \
    rsync \
    scdaemon \
    silversearcher-ag \
    software-properties-common \
    ssh \
    tcptraceroute \
    texlive \
    traceroute \
    unrar \
    unzip \
    zsh \
    --no-install-recommends

  echo "*** Done Installing base"
  dpkg --get-selections | grep hold

  setup_sudo

  apt -y autoremove
  apt autoclean
  apt clean

  #cat <<- EOF > /etc/default/locale
  ##  File generated by update-locale
  #LANG=en_US.UTF-8
  #EOF

  sed -i '/en_US.UTF-8/ s/^# //' /etc/locale.gen
  locale-gen -a
  dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8

  sed -i '/WaylendEnable=false/ s/^#\s*//' /etc/gdm3/daemon.conf
  }

# setup sudo for a user
# because fuck typing that shit all the time
# just have a decent password
# and lock your computer when you aren't using it
# if they have your password they can sudo anyways
# so its pointless
# i know what the fuck im doing ;)
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

# install graphics drivers
install_graphics() {
  local system=$1

  if [[ -z "$system" ]]; then
    echo "You need to specify whether it's intel, geforce or optimus"
    exit 1
  fi

  local pkgs=( xorg xserver-xorg xserver-xorg-input-libinput xserver-xorg-input-synaptics )

  case $system in
    "intel")
      pkgs+=( xserver-xorg-video-intel )
      ;;
    "geforce")
      pkgs+=( nvidia-driver )
      ;;
    "optimus")
      pkgs+=( nvidia-kernel-dkms bumblebee-nvidia primus )
      ;;
    *)
      echo "You need to specify whether it's intel, geforce or optimus"
      exit 1
      ;;
  esac

  apt update || true
  apt -y upgrade

  apt install -y "${pkgs[@]}" --no-install-recommends
}

# install stuff for i3 window manager
install_wmapps() {
  apt update || true
  apt install -y \
    alsa-utils \
    feh \
    i3 \
    i3lock-fancy \
    i3status \
    flameshot \
    suckless-tools \
    kitty \
    rofi \
    usbmuxd \
    xclip \
    picom \
    arandr \
    adwaita-icon-theme \
    breeze-cursor-theme \
    breeze-gtk-theme \
    breeze-icon-theme \
    dunst \
    firefox \
    gucharmap \
    hicolor-icon-theme \
    higan \
    inkscape \
    google-chrome-stable \
    kdeconnect \
    lxappearance \
    neofetch \
    oxygen-icon-theme \
    pavucontrol \
    pinentry-qt \
    remmina \
    vlc \
    wmctrl \
    snapd \
    libxcb1-dev \
    libxss-dev \
    libpulse-dev \
    libxcb-screensaver0-dev \
    teams \
    code-insiders \
    lutris \
    slack-desktop \
    spotify-client \
    keybase \
    --no-install-recommends

  apt -y autoremove
  apt autoclean
  apt clean
}

usage() {
  echo -e "install.sh\\n\\tThis script installs my basic setup for a debian laptop\\n"
  echo "Usage:"
  echo "  base                                - setup sources & install base pkgs"
  echo "  basemin                             - setup sources & install base min pkgs"
  echo "  graphics {intel, geforce, optimus}  - install graphics drivers"
  echo "  wm                                  - install window manager/desktop pkgs"
}

main() {
  local cmd=$1

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  if [[ $cmd == "base" ]]; then
    check_is_sudo
    get_user

    # setup /etc/apt/sources.list
    setup_sources

    base
  elif [[ $cmd == "basemin" ]]; then
    check_is_sudo
    get_user

    # setup /etc/apt/sources.list
    setup_sources_min

    base_min
  elif [[ $cmd == "graphics" ]]; then
    check_is_sudo

    install_graphics "$2"
  elif [[ $cmd == "wm" ]]; then
    check_is_sudo

    install_wmapps
  else
    usage
  fi
}

main "$@"
