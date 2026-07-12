#!/usr/bin/env bash

IMAGE_NAME="snmp-config-generator"
docker build -t $IMAGE_NAME snmp-exporter
docker run --rm -it -v "$PWD"/snmp-exporter:/config $IMAGE_NAME /config/build.sh
