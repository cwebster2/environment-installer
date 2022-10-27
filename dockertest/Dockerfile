FROM archlinux:latest

ARG TARGET_USER

ENV TARGET_USER=${TARGET_USER:-casey} \
    DOTFILESBRANCH=main

USER root
# RUN useradd $TARGET_USER
RUN pacman -Sy --noconfirm zsh sudo
RUN useradd -m -s /bin/zsh -U -G wheel $TARGET_USER
RUN echo -e "Defaults	secure_path=\"/usr/local/go/bin:/home/${TARGET_USER}/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/bcc/tools:/home/${TARGET_USER}/.cargo/bin\"" >> /etc/sudoers.d/$TARGET_USER
RUN echo -e 'Defaults	env_keep += "ftp_proxy http_proxy https_proxy no_proxy GOPATH EDITOR"' >> /etc/sudoers.d/$TARGET_USER
RUN echo -e "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$TARGET_USER

WORKDIR /home/$TARGET_USER
RUN mkdir .environment-installer
COPY *.sh .environment-installer/

RUN pacman -Syu --noconfirm
RUN cd .environment-installer && ./install-arch.sh base
# RUN cd .environment-installer && ./install-arch.sh wm
# RUN cd .environment-installer && ./install-arch.sh laptop
# RUN cd .environment-installer && ./install-arch.sh games
RUN cd .environment-installer && ./install-arch.sh dotfiles

USER $TARGET_USER
# RUN wget -qO- https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh > /home/$TARGET_USER/install-stage1.sh && \
    # chmod +x /home/$TARGET_USER/install-stage1.sh

# RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh vim"]
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh emacs"]

# ENTRYPOINT ["/usr/bin/zsh"]
