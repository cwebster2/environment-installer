FROM ubuntu:20.04

ENV TARGET_USER casey
ENV DOTFILESBRANCH=razer-ubuntu

RUN adduser casey --disabled-password
COPY --chown=$TARGET_USER:$TARGET_USER install-stage0-ubuntu.sh /home/$TARGET_USER/install-stage0.sh
WORKDIR /home/$TARGET_USER
RUN ./install-stage0.sh basemin && \
    ./install-stage0.sh base && \
    ./install-stage0.sh graphics geforce && \
    ./install-stage0.sh wm

USER $TARGET_USER
COPY --chown=$TARGET_USER:$TARGET_USER install-stage1-ubuntu.sh /home/$TARGET_USER/install-stage1.sh
RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]

ENTRYPOINT ["/usr/bin/zsh"]
