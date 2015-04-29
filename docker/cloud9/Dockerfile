FROM centos:centos7
MAINTAINER Kazuki Hasegawa <hasegawa@khasegawa.net>
RUN yum update -y && \
        yum groupinstall -y "Development Tools" && \
        yum install -y libxml2-devel ncurses ncurses-devel tmux libffi-devel openssl openssl-devel
RUN useradd -m corrupt952
ENV HOME /home/corrupt952
ENV NODE_VERSION v0.10.38
ADD nvm_install.sh $HOME/nvm_install.sh
ADD rbenv_install.sh $HOME/rbenv_install.sh
RUN chown corrupt952 $HOME/nvm_install.sh $HOME/rbenv_install.sh && \
        chmod +x $HOME/nvm_install.sh $HOME/rbenv_install.sh
USER corrupt952
WORKDIR $HOME
RUN $HOME/nvm_install.sh
RUN $HOME/rbenv_install.sh
RUN mkdir workspace
RUN git clone https://github.com/c9/core.git c9core
WORKDIR $HOME/c9core
RUN source ~/.nvm/nvm.sh && \
        npm install && \
        scripts/install-sdk.sh
EXPOSE 8181
CMD source ~/.nvm/nvm.sh && \
        node server.js -p 8181 -l 0.0.0.0 -a : -w ~/workspace
