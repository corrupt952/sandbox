FROM ubuntu:22.04

RUN apt-get update -qq \
    && apt-get install -y \
        git \
        build-essential \
        golang \
        libsnmp-dev \
        curl \
        wget \
        unzip \
        p7zip-full

ENV SNMP_EXPORTER_PATH /opt/snmp_exporter
ENV MIBDIRS /opt/snmp_exporter/generator/mibs
RUN git clone https://github.com/prometheus/snmp_exporter.git $SNMP_EXPORTER_PATH \
    && cd $SNMP_EXPORTER_PATH/generator \
    && go build \
    && make mibs \
    && wget http://www.rtpro.yamaha.co.jp/RT/docs/mib/yamaha-private-mib.zip \
    && unzip yamaha-private-mib.zip \
    && mv yamaha-private-mib/* mibs
WORKDIR $SNMP_EXPORTER_PATH/generator
