FROM debian:latest

ARG TARGET_USER
ARG DOTFILESBRANCH

ENV TARGET_USER=${TARGET_USER:-casey} \
    DOTFILESBRANCH=${DOTFILESBRANCH:-master}

RUN adduser $TARGET_USER --disabled-password
WORKDIR /home/$TARGET_USER
COPY install-stage0-debian.sh install-stage0.sh
RUN ./install-stage0.sh basemin
RUN ./install-stage0.sh base

USER $TARGET_USER
RUN wget -qO- https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh > /home/$TARGET_USER/install-stage1.sh && \
    chmod +x /home/$TARGET_USER/install-stage1.sh

RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh vim"]
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh emacs"]

ENTRYPOINT ["/usr/bin/zsh"]
