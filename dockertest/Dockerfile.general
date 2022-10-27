ARG IMAGE=debian
ARG TAG=latest

FROM $IMAGE:$TAG

ARG TARGET_USER
ARG DOTFILESBRANCH
ARG DISTRO=debian

ENV TARGET_USER=${TARGET_USER:-casey} \
    DOTFILESBRANCH=${DOTFILESBRANCH:-main}

USER root
# RUN useradd $TARGET_USER
WORKDIR /home/$TARGET_USER
RUN mkdir .environment-installer
COPY *.sh .environment-installer/
RUN cd .environment-installer && ./install-$DISTRO.sh base
RUN cd .environment-installer && ./install-$DISTRO.sh wm
RUN cd .environment-installer && ./install-$DISTRO.sh laptop
RUN cd .environment-installer && ./install-$DISTRO.sh games
RUN cd .environment-installer && ./install-$DISTRO.sh dotfiles

USER $TARGET_USER
# RUN wget -qO- https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh > /home/$TARGET_USER/install-stage1.sh && \
    # chmod +x /home/$TARGET_USER/install-stage1.sh

# RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh vim"]
# RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh emacs"]

# ENTRYPOINT ["/usr/bin/zsh"]
