#!/usr/bin/env bash
# Start a freshly built image and check that it behaves like a release must:
#   1. it does not run as root,
#   2. it serves /api/status with status "ok",
#   3. its own HEALTHCHECK command (`/app -healthcheck`) succeeds.
#
# Environment:
#   IMAGE  image to test (default go-app:ci)
#   PORT   host port to publish on 127.0.0.1 (default 8000)
set -euo pipefail

IMAGE="${IMAGE:-go-app:ci}"
PORT="${PORT:-8000}"
name="smoke-$$"

fail() {
  echo "::error::$*"
  exit 1
}

cleanup() {
  echo "--- container logs ---"
  docker logs --tail 40 "$name" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

user=$(docker inspect --format '{{.Config.User}}' "$IMAGE")
echo "Image user: '${user}'"
if [ -z "$user" ] || [ "$user" = "root" ] || [ "${user%%:*}" = "0" ]; then
  fail "image runs as root (USER is '${user}'); set a non-root USER in the Dockerfile"
fi

# No AWS credentials exist here, so switch off the metadata-service lookup: the
# app's CloudWatch logging then fails fast instead of waiting on timeouts, and
# (by design) the app keeps running without it.
docker run -d --name "$name" -p "127.0.0.1:${PORT}:8000" \
  -e APP_VERSION=smoke-test \
  -e AWS_REGION=eu-south-1 \
  -e AWS_EC2_METADATA_DISABLED=true \
  "$IMAGE" >/dev/null

body=""
for _ in $(seq 1 30); do
  if body=$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/status" 2>/dev/null); then
    break
  fi
  body=""
  sleep 1
done
[ -n "$body" ] || fail "the container did not answer /api/status within 30 seconds"
echo "GET /api/status -> $body"

[ "$(jq -r '.status' <<<"$body")" = "ok" ] || fail "/api/status did not report status ok"
[ "$(jq -r '.version' <<<"$body")" = "smoke-test" ] || fail "/api/status did not report the APP_VERSION that was set"

docker exec "$name" /app -healthcheck || fail "the image's HEALTHCHECK command (/app -healthcheck) failed"
echo "Smoke test passed."
