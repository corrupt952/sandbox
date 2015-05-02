FROM centos:centos7
MAINTAINER Kazuki Hasegawa <hasegawa@khasegawa.net>
RUN yum update -y && \
        yum install -y wget unzip java-1.8.0-openjdk
RUN useradd -m corrupt952
ENV HOME /home/corrupt952
USER corrupt952
WORKDIR $HOME
RUN wget http://ftp.jaist.ac.jp/pub/eclipse/orion/drops/R-8.0-201502161823/eclipse-orion-8.0-linux.gtk.x86_64.zip -O eclipse.zip && \
        unzip eclipse.zip
EXPOSE 8080
WORKDIR $HOME/eclipse
CMD ./orion
