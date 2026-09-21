#!/usr/bin/env bash
# Decide which release tag a run of release.yml is about, and refuse anything
# unexpected: the tag must look like vMAJOR.MINOR.PATCH, exist, and point at a
# commit that is part of the main branch.
#
# Must run inside a full clone (checkout with fetch-depth: 0), because it needs
# the history of main and all tags.
#
# Environment:
#   EVENT_NAME   push | workflow_dispatch
#   REF_NAME     the pushed tag (push events)
#   INPUT_TAG    the requested tag (workflow_dispatch events)
#   MAIN_BRANCH  default: main
# Writes `tag=` and `commit=` to $GITHUB_OUTPUT when it is set.
set -euo pipefail

: "${EVENT_NAME:?EVENT_NAME is required}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

fail() {
  echo "::error::$*"
  exit 1
}

case "$EVENT_NAME" in
  push) tag="${REF_NAME:-}" ;;
  workflow_dispatch) tag="${INPUT_TAG:-}" ;;
  *) fail "unsupported event: $EVENT_NAME" ;;
esac

[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$tag' is not a release tag (expected vMAJOR.MINOR.PATCH)"

commit=$(git rev-parse --verify --quiet "refs/tags/${tag}^{commit}") || fail "tag $tag does not exist in this repository"

if ! git merge-base --is-ancestor "$commit" "origin/${MAIN_BRANCH}"; then
  fail "tag $tag points at $commit, which is not on ${MAIN_BRANCH}; only commits merged to ${MAIN_BRANCH} can be released"
fi

echo "Release tag: $tag ($commit)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "tag=$tag"
    echo "commit=$commit"
  } >>"$GITHUB_OUTPUT"
fi
