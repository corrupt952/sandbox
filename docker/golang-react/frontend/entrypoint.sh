#!/usr/bin/env bash

yarn install --flat --frozen-lockfile

exec "$@"
