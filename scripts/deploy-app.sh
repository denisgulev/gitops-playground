#!/bin/bash
# Deploy a new image of the Go API on the EC2 instance, with a canary check.
# Runs ON the instance; sent by .github/actions/ssm-run.
#
# Required environment: IMAGE (e.g. user/go-app:v1.2.3), TAG (v1.2.3), REGION
# Optional environment: CLOUDWATCH_LOG_GROUP (default go-app-logs),
#                       STATIC_SITE_URL (default https://static-website.denisgulev.com)
#
# Flow: pull the image -> run it as a canary on :8001 -> if /api/status answers
# "ok", replace the production container on :8000, otherwise remove the canary
# and fail (the running production container is left untouched).
#
# POSIX sh only (SSM may run this with `sh`). No `pipefail` on purpose: with
# `curl ... | grep -q` grep exits at the first match and curl would then report
# a broken pipe as a failure.
set -eu

: "${IMAGE:?IMAGE is required}"
: "${TAG:?TAG is required}"
: "${REGION:?REGION is required}"
CLOUDWATCH_LOG_GROUP="${CLOUDWATCH_LOG_GROUP:-go-app-logs}"
STATIC_SITE_URL="${STATIC_SITE_URL:-https://static-website.denisgulev.com}"

# Values reach `docker` as arguments, so reject anything that is not a plain image/tag.
case "$IMAGE" in '' | *[!A-Za-z0-9_./:@-]*) echo "invalid IMAGE: $IMAGE"; exit 1 ;; esac
case "$TAG" in '' | *[!A-Za-z0-9_.-]*) echo "invalid TAG: $TAG"; exit 1 ;; esac
case "$REGION" in '' | *[!a-z0-9-]*) echo "invalid REGION: $REGION"; exit 1 ;; esac

TEMP_CONTAINER="go-app-new"
CURRENT_CONTAINER="go-app"

echo "Pulling image: $IMAGE"
docker pull "$IMAGE"

echo "Starting canary container..."
docker rm -f "$TEMP_CONTAINER" 2>/dev/null || true
docker run -d --name "$TEMP_CONTAINER" \
  -p 8001:8000 \
  -e APP_VERSION="$TAG" \
  -e AWS_DEFAULT_REGION="$REGION" \
  -e CLOUDWATCH_LOG_GROUP="$CLOUDWATCH_LOG_GROUP" \
  -e STATIC_SITE_URL="$STATIC_SITE_URL" \
  "$IMAGE"

sleep 5

if curl -sf --max-time 30 http://localhost:8001/api/status | grep -q '"ok"'; then
  echo "Health check passed. Promoting..."
  docker stop "$TEMP_CONTAINER" && docker rm "$TEMP_CONTAINER"

  if docker ps -a --format '{{.Names}}' | grep -q "^${CURRENT_CONTAINER}\$"; then
    docker stop "$CURRENT_CONTAINER" && docker rm "$CURRENT_CONTAINER"
  fi

  docker run -d --name "$CURRENT_CONTAINER" \
    --restart unless-stopped \
    -p 8000:8000 \
    -e APP_VERSION="$TAG" \
    -e AWS_DEFAULT_REGION="$REGION" \
    -e CLOUDWATCH_LOG_GROUP="$CLOUDWATCH_LOG_GROUP" \
    -e STATIC_SITE_URL="$STATIC_SITE_URL" \
    "$IMAGE"
  echo "Deployed: $CURRENT_CONTAINER"
else
  echo "Health check failed."
  docker stop "$TEMP_CONTAINER" && docker rm "$TEMP_CONTAINER"
  exit 1
fi
