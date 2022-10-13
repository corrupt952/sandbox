#!/usr/bin/env bash

CURRENT_PATH=$(cd $(dirname "$0") || exit; pwd)

cp "$CURRENT_PATH"/generator.yml "$SNMP_EXPORTER_PATH"/generator/generator.yml
"$SNMP_EXPORTER_PATH"/generator/generator generate --output-path="$CURRENT_PATH"/snmp.yml
