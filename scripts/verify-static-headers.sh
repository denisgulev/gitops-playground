#!/usr/bin/env bash
# After a static-site deploy, check the bucket against the local dist/ directory:
#   - every file in dist/ exists in the bucket,
#   - each has the intended Cache-Control (HTML short, everything else longer),
#   - the bucket holds nothing that is not in dist/ (i.e. `sync --delete` worked).
#
# Environment:
#   S3_BUCKET            bucket name
#   HTML_CACHE_CONTROL   expected Cache-Control of *.html files
#   OTHER_CACHE_CONTROL  expected Cache-Control of every other file
#   DIST_DIR             local directory that was uploaded (default frontend/static/dist)
# Needs `aws` with credentials and a region in the environment.
set -euo pipefail

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${HTML_CACHE_CONTROL:?HTML_CACHE_CONTROL is required}"
: "${OTHER_CACHE_CONTROL:?OTHER_CACHE_CONTROL is required}"
DIST_DIR="${DIST_DIR:-frontend/static/dist}"
export AWS_PAGER=""

[ -d "$DIST_DIR" ] || {
  echo "::error::$DIST_DIR does not exist"
  exit 1
}

problems=0
problem() {
  echo "::error::$*"
  problems=$((problems + 1))
}

local_keys=$(cd "$DIST_DIR" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
[ -n "$local_keys" ] || {
  echo "::error::$DIST_DIR contains no files"
  exit 1
}

while IFS= read -r key; do
  case "$key" in
    *.html) expected="$HTML_CACHE_CONTROL" ;;
    *) expected="$OTHER_CACHE_CONTROL" ;;
  esac
  if ! actual=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$key" --query CacheControl --output text 2>&1); then
    problem "$key is not in the bucket ($actual)"
    continue
  fi
  if [ "$actual" = "$expected" ]; then
    echo "ok   $key  Cache-Control: $actual"
  else
    problem "$key has Cache-Control '$actual', expected '$expected'"
  fi
done <<<"$local_keys"

remote_keys=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --query 'Contents[].Key' --output text | tr '\t' '\n' | LC_ALL=C sort)
# `Contents` is null for an empty bucket, which the CLI prints as "None".
[ "$remote_keys" = "None" ] && remote_keys=""
extra=$(comm -13 <(printf '%s\n' "$local_keys") <(printf '%s\n' "$remote_keys") | sed '/^$/d')
if [ -n "$extra" ]; then
  while IFS= read -r key; do
    problem "the bucket has '$key', which is not in $DIST_DIR"
  done <<<"$extra"
fi

if [ "$problems" -gt 0 ]; then
  echo "::error::$problems problem(s) found in bucket $S3_BUCKET"
  exit 1
fi
echo "Bucket matches $DIST_DIR and every object has the intended Cache-Control."
