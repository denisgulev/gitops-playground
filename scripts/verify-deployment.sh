#!/usr/bin/env bash
# Wait until the public API reports the version that was just deployed.
# This checks the real path (CloudFront -> nginx -> container), not just the
# container, so it also catches routing or caching problems.
#
# Environment:
#   URL             status endpoint, e.g. https://api.example.com/api/status
#   EXPECT_VERSION  version the endpoint must report, e.g. v1.2.3
#   ATTEMPTS        tries before giving up (default 24)
#   INTERVAL        seconds between tries (default 5)
set -euo pipefail

: "${URL:?URL is required}"
: "${EXPECT_VERSION:?EXPECT_VERSION is required}"
ATTEMPTS="${ATTEMPTS:-24}"
INTERVAL="${INTERVAL:-5}"

body=""
for attempt in $(seq 1 "$ATTEMPTS"); do
  if body=$(curl -fsS --max-time 10 "$URL" 2>&1); then
    status=$(jq -r '.status // empty' <<<"$body" 2>/dev/null || true)
    version=$(jq -r '.version // empty' <<<"$body" 2>/dev/null || true)
    if [ "$status" = "ok" ] && [ "$version" = "$EXPECT_VERSION" ]; then
      echo "OK: $URL reports status=ok version=$version (attempt $attempt)"
      exit 0
    fi
    echo "[$attempt/$ATTEMPTS] status='${status}' version='${version}', waiting for '$EXPECT_VERSION'"
  else
    echo "[$attempt/$ATTEMPTS] request failed: $body"
  fi
  [ "$attempt" -lt "$ATTEMPTS" ] && sleep "$INTERVAL"
done

echo "::error::$URL did not report version $EXPECT_VERSION after $ATTEMPTS attempts (last response: $body)"
exit 1
