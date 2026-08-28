#!/bin/bash
# Fetches the Summernote build app1's asset pipeline expects.
#
# Summernote is MIT-licensed but is not redistributed from this repository, so
# the two files land in app1/vendor/assets/ as ignored local inputs. 0.6.4 is
# pinned because that is what this 2015 experiment was written against; it
# predates Summernote's npm packages, so the files come from the upstream tag.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="v0.6.4"
BASE="https://raw.githubusercontent.com/summernote/summernote/${VERSION}/dist"

curl -fsSL "${BASE}/summernote.min.js" \
  -o app1/vendor/assets/javascripts/summernote.min.js
curl -fsSL "${BASE}/summernote.css" \
  -o app1/vendor/assets/stylesheets/summernote.css

echo "fetched Summernote ${VERSION} into app1/vendor/assets/"
