#!/usr/bin/env bash
#   ./deliver-local.sh                        # fixtures/plain.eml
#   ./deliver-local.sh fixtures/unauthenticated.eml
set -euo pipefail

cd "$(dirname "$0")"

fixture="${1:-fixtures/plain.eml}"
port="${PORT:-8787}"
log="$(mktemp)"

[ -f "$fixture" ] || { echo "no such fixture: $fixture" >&2; exit 1; }

# Direct binary, not `pnpm exec`: killing the wrapper leaves wrangler holding the port.
node_modules/.bin/wrangler dev --port "$port" >"$log" 2>&1 &
dev_pid=$!
cleanup() {
  kill "$dev_pid" 2>/dev/null || true
  wait "$dev_pid" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://localhost:$port/cdn-cgi/handler/email" \
      --url-query 'from=probe@example.net' \
      --url-query 'to=agent@example.com' \
      --data-binary '' 2>/dev/null; then
    break
  fi
  kill -0 "$dev_pid" 2>/dev/null || { echo "wrangler dev exited early:" >&2; cat "$log" >&2; exit 1; }
  sleep 0.5
done

from="${FROM:-$(sed -n 's/^From:.*<\(.*\)>.*/\1/p;s/^From: \([^<]*\)$/\1/p' "$fixture" | head -1)}"
# TO overrides the envelope recipient independently of the To: header, which is
# how a message addressed to one mailbox in its headers gets delivered to another.
to="${TO:-$(sed -n 's/^To:.*<\(.*\)>.*/\1/p;s/^To: \([^<]*\)$/\1/p' "$fixture" | head -1)}"

curl -fsS -X POST "http://localhost:$port/cdn-cgi/handler/email" \
  --url-query "from=${from:-probe@example.net}" \
  --url-query "to=${to:-agent@example.com}" \
  --header 'Content-Type: message/rfc822' \
  --data-binary "@$fixture"

# Let the runtime flush console output before the trap kills it.
sleep 1
echo
echo "--- worker log ---"
grep -v '^\[wrangler' "$log" | grep -v '^$' | tail -20
