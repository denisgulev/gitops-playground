#!/bin/bash
# Deploy the observability stack (Grafana, Loki, Promtail) on the EC2 instance.
# Runs ON the instance; sent by .github/actions/ssm-run.
#
# It downloads this repository's archive at one commit from GitHub (the repo is
# public, so no credentials are needed), copies observability-stack/ into
# DEPLOY_DIR, installs Docker Compose if it is missing, and starts the stack.
# An existing .env in DEPLOY_DIR is never overwritten, so credentials changed on
# the instance survive deployments. Markdown files are not copied.
#
# Required environment: REPO (owner/name), SHA (full 40-character commit id)
# Optional environment (defaults in the script):
#   DEPLOY_DIR, COMPOSE_VERSION, COMPOSE_SHA256, COMPOSE_BIN, COMPOSE_LINK,
#   ARCHIVE_BASE_URL (mainly so tests can point it at a local file:// tree)
#
# POSIX sh only (SSM may run this with `sh`).
set -eu

: "${REPO:?REPO is required}"
: "${SHA:?SHA is required}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/ec2-user/observability-stack}"
ARCHIVE_BASE_URL="${ARCHIVE_BASE_URL:-https://codeload.github.com}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.36.0}"
# sha256 of docker-compose-linux-aarch64 for COMPOSE_VERSION (the instance is ARM).
COMPOSE_SHA256="${COMPOSE_SHA256:-af9609273eb43a928323ed78e67b4064a1026b66b63a71e82fd100151b1d7b33}"
COMPOSE_BIN="${COMPOSE_BIN:-/usr/local/bin/docker-compose}"
COMPOSE_LINK="${COMPOSE_LINK:-/usr/bin/docker-compose}"

case "$REPO" in */*/* | */ | /* | '' | *[!A-Za-z0-9._/-]*) echo "invalid REPO: $REPO"; exit 1 ;; esac
case "$REPO" in */*) ;; *) echo "invalid REPO: $REPO"; exit 1 ;; esac
case "$SHA" in *[!0-9a-f]* | '') echo "invalid SHA: $SHA"; exit 1 ;; esac
[ "${#SHA}" -eq 40 ] || { echo "invalid SHA (need 40 hex characters): $SHA"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $REPO at $SHA ..."
curl -fsSL --retry 3 --max-time 120 -o "$tmp/repo.tar.gz" "$ARCHIVE_BASE_URL/$REPO/tar.gz/$SHA"

# The archive has one top-level directory (<repo>-<sha>/); strip it.
mkdir "$tmp/src"
tar -xzf "$tmp/repo.tar.gz" -C "$tmp/src" --strip-components=1 --wildcards '*/observability-stack'
src="$tmp/src/observability-stack"
[ -d "$src" ] || { echo "observability-stack/ not found in the archive"; exit 1; }

echo "Copying configuration to $DEPLOY_DIR ..."
mkdir -p "$DEPLOY_DIR"
tar -cf "$tmp/config.tar" -C "$src" --exclude='./.env' --exclude='*.md' .
tar -xf "$tmp/config.tar" -C "$DEPLOY_DIR"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  [ -f "$src/.env" ] || { echo "no .env on the instance and none in the repository"; exit 1; }
  echo "Creating $DEPLOY_DIR/.env from the repository (first deployment)"
  cp "$src/.env" "$DEPLOY_DIR/.env"
fi

# SSM runs as root; only use sudo when that is not the case.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

if ! docker-compose version >/dev/null 2>&1; then
  [ "$(uname -m)" = "aarch64" ] || { echo "Docker Compose install is only set up for aarch64, found $(uname -m)"; exit 1; }
  echo "Installing Docker Compose $COMPOSE_VERSION ..."
  curl -fsSL --retry 3 -o "$tmp/docker-compose" \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-aarch64"
  echo "${COMPOSE_SHA256}  $tmp/docker-compose" | sha256sum -c -
  $SUDO install -m 0755 "$tmp/docker-compose" "$COMPOSE_BIN"
  $SUDO ln -sf "$COMPOSE_BIN" "$COMPOSE_LINK"
fi

echo "Deploying observability stack..."
cd "$DEPLOY_DIR"
docker-compose pull
# `up -d` recreates only the services whose image or configuration changed.
docker-compose up -d
echo "Done."
