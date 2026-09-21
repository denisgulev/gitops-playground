#!/usr/bin/env bash
# Turn the log of a `terraform plan` into a readable GitHub job summary: a
# one-line verdict on top and the full output underneath, collapsed.
#
# Usage: terraform-plan-summary.sh <plan-output-file> <title>
# Writes to $GITHUB_STEP_SUMMARY (to stdout when that is not set).
#
# Environment:
#   MAX_CHARS  most characters of plan output to include (default 60000; the
#              job summary itself is capped at 1 MiB). When the output is
#              longer, the END is kept: that is where the plan summary and
#              any error message are.
set -euo pipefail

plan_file="${1:?usage: terraform-plan-summary.sh <plan-output-file> <title>}"
title="${2:?usage: terraform-plan-summary.sh <plan-output-file> <title>}"
out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
max_chars="${MAX_CHARS:-60000}"

# Plain text without terminal colour codes.
plain=$(mktemp)
trap 'rm -f "$plain"' EXIT
if [ -f "$plan_file" ]; then
  perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "$plan_file" >"$plain"
fi

plan_line=$(grep -m1 -E '^Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' "$plain" || true)

if [ ! -s "$plain" ]; then
  verdict="No plan output was produced. See the job log."
elif [ -n "$plan_line" ]; then
  destroyed=$(sed -E 's/.* ([0-9]+) to destroy.*/\1/' <<<"$plan_line")
  verdict="**${plan_line}**"
  if [ "$destroyed" -gt 0 ]; then
    verdict="${verdict} ⚠️ This plan destroys ${destroyed} resource(s)."
  fi
elif grep -q -E '^No changes\.' "$plain"; then
  verdict="**No changes.** The infrastructure matches the configuration."
elif grep -q -E '(^|[[:space:]])Error: ' "$plain"; then
  # Terraform prints errors either bare ("Error: ...") or inside a box ("│ Error: ...").
  verdict="**The plan failed.** See the error at the end of the output."
else
  verdict="No plan summary line was found. See the output below."
fi

total=$(wc -c <"$plain" | tr -d ' ')
notice=""
if [ "$total" -gt "$max_chars" ]; then
  notice="Output truncated to the last ${max_chars} of ${total} characters; the job log has all of it."
  tail -c "$max_chars" "$plain" >"$plain.cut" && mv "$plain.cut" "$plain"
fi

{
  echo "## ${title}"
  echo
  echo "${verdict}"
  echo
  if [ -s "$plain" ]; then
    echo "<details><summary>Full plan output</summary>"
    echo
    [ -n "$notice" ] && echo "_${notice}_" && echo
    # HTML-escape so nothing in the plan (descriptions, tags, ...) can be rendered as markup.
    echo "<pre>"
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$plain"
    echo "</pre>"
    echo "</details>"
  fi
} >>"$out"
