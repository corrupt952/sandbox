#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p data
curl -fsSL -o data/titanic.csv \
  https://raw.githubusercontent.com/datasciencedojo/datasets/master/titanic.csv
echo "Saved: data/titanic.csv ($(wc -l < data/titanic.csv | tr -d ' ') lines)"
