FROM centos:centos7
MAINTAINER Kazuki Hasegawa <hasegawa@khasegawa.net>
RUN yum update -y && \
        yum groupinstall -y "Development Tools" && \
        yum install -y libxml2-devel ncurses ncurses-devel libffi-devel openssl openssl-devel wget maven
RUN useradd -m corrupt952
ENV HOME /home/corrupt952
ADD rbenv_install.sh $HOME/rbenv_install.sh
RUN chown corrupt952 $HOME/rbenv_install.sh && \
        chmod +x $HOME/rbenv_install.sh
USER corrupt952
WORKDIR $HOME
RUN $HOME/rbenv_install.sh
RUN wget http://ftp.jaist.ac.jp/pub/eclipse/orion/drops/R-8.0-201502161823/eclipse-orion-8.0-linux.gtk.x86_64.zip -o eclipse.zip && \
        unzip eclipse.zip
EXPOSE 8080
WORKDIR $HOME/eclipse
CMD ./orion
