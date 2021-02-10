FROM debian:10.3

ENV TARGET_USER casey
ENV DOTFILESBRANCH=master

RUN adduser casey --disabled-password
RUN apt-get update && \
    apt-get install -y wget && \
    wget -qO- https://raw.githubusercontent.com/cwebster2/environment-installer/master/install-stage0-debian.sh > /home/$TARGET_USER/install-stage0.sh && \
    chmod +x /home/$TARGET_USER/install-stage0.sh
WORKDIR /home/$TARGET_USER
RUN ./install-stage0.sh basemin
RUN ./install-stage0.sh base

USER $TARGET_USER
RUN wget -qO- https://raw.githubusercontent.com/cwebster2/dotfiles/${DOTFILESBRANCH}/bin/install.sh > /home/$TARGET_USER/install-stage1.sh && \
    chmod +x /home/$TARGET_USER/install-stage1.sh

RUN ./install-stage1.sh dotfiles
# Need an interactive shell to init zsh-nvm
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh tools"]
RUN ["/usr/bin/zsh", "-i", "-c", "./install-stage1.sh lsp"]

ENTRYPOINT ["/usr/bin/zsh"]
