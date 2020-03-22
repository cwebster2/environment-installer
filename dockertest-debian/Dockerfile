FROM debian:10.3

ENV TARGET_USER casey
ENV DOTFILESBRANCH=master

RUN adduser casey --disabled-password
COPY --chown=$TARGET_USER:$TARGET_USER install-stage0-debian.sh /home/$TARGET_USER/install-stage0.sh
WORKDIR /home/$TARGET_USER
RUN ./install-stage0.sh basemin && \
    ./install-stage0.sh base && \
    ./install-stage0.sh graphics geforce && \
    ./install-stage0.sh wm

USER $TARGET_USER
COPY --chown=$TARGET_USER:$TARGET_USER install-stage1-debian.sh /home/$TARGET_USER/install-stage1.sh
RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]

ENTRYPOINT ["/usr/bin/zsh"]
