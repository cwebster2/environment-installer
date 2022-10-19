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
  zgenhostid "$(hostid)"
  zpool set cachefile=/etc/zfs/zpool.cache rpool
  mkinitcpio -P
  # get uuid of the swap disk
  UUID=$(grep swap /etc/fstab | awk '{print $1}')

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
  useradd -m -s /bin/zsh -G wheel "${TARGET_USER}"
  chsh -s /bin/zsh "${TARGET_USER}"
  passwd "${TARGET_USER}"

  # this is so the zsh setup doesn't bother us until dotfiles are installed
  touch "/home/${TARGET_USER}/.zshrc"
  chown "${TARGET_USER} /home/${TARGET_USER}/.zshrc"
  setup_sudo

  # Setup ~/Downloads as a tmpfs
  mkdir -p "/home/${TARGET_USER}/Downloads"
  chown "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/Downloads"
  echo -e "\\n# tmpfs for downloads\\ntmpfs\\t/home/${TARGET_USER}/Downloads\\ttmpfs\\tnodev,nosuid,size=2G\\t0\\t0" >> /etc/fstab
  mount "/home/${TARGET_USER}/Downloads"
  chown "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/Downloads"
  umount "/home/${TARGET_USER}/Downloads"
}

get_installer() {
  echo "***"
  echo "*** Getting stage 1 installer for post-reboot"
  echo "***"
  git clone https://github.com/cwebster2/environment-installer "/home/${TARGET_USER}/.environment-installer"
  chown -R "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/.environment-installer"
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

usage() {
  echo -e "install.sh\\n\\tThis script sets up a brand new system for Arch + zfs\\n"
  echo "Usage:"
  echo "  prepare                             - Prepare new maching for first boot"
  echo "  chrooted                            - Initial chroot installation (this is run by prepare)"
}

main() {
  local cmd=$1

  set -u

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  if [[ $cmd == "prepare" ]]; then
    partition_disk "$DISK" "$SWAPSIZE"
    create_filesystems_zfs "$DISK"
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
  else
    usage
  fi
}

main "$@"
