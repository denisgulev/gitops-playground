#!/usr/bin/env bash
# Run a local script on the EC2 instance through SSM Run Command, wait for it,
# print its output, and fail unless it succeeded.
#
# Used by .github/actions/ssm-run. Also runnable by hand: it needs `aws` and
# `jq`, plus AWS credentials and a region in the environment.
#
# Inputs (environment variables):
#   SSM_SCRIPT_PATH     script to run on the instance; its first line must be a shebang
#   SSM_ENV             optional KEY=VALUE lines, exported before the script runs.
#                       Values end up in the SSM command history, so never pass secrets.
#   SSM_INSTANCE_PARAM  SSM parameter holding the instance id (default /infra/ec2/instance_id)
#   SSM_TIMEOUT         seconds the script may run (default 300, minimum 30)
#   SSM_POLL_INTERVAL   seconds between status checks (default 5)
set -euo pipefail

: "${SSM_SCRIPT_PATH:?SSM_SCRIPT_PATH is required}"
SSM_ENV="${SSM_ENV:-}"
SSM_INSTANCE_PARAM="${SSM_INSTANCE_PARAM:-/infra/ec2/instance_id}"
SSM_TIMEOUT="${SSM_TIMEOUT:-300}"
SSM_POLL_INTERVAL="${SSM_POLL_INTERVAL:-5}"
export AWS_PAGER=""

fail() {
  echo "::error::$*"
  exit 1
}

# POSIX single-quote escaping: it -> 'it'\''s' so the value is never interpreted.
shell_quote() {
  local sq="'" repl="'\\''"
  local s=${1//$sq/$repl}
  printf "'%s'" "$s"
}

case "$SSM_TIMEOUT" in '' | *[!0-9]*) fail "SSM_TIMEOUT must be a number of seconds" ;; esac
[ "$SSM_TIMEOUT" -ge 30 ] || fail "SSM_TIMEOUT must be at least 30 seconds"
case "$SSM_POLL_INTERVAL" in '' | *[!0-9]*) fail "SSM_POLL_INTERVAL must be a number of seconds" ;; esac
[ -f "$SSM_SCRIPT_PATH" ] || fail "script not found: $SSM_SCRIPT_PATH"

# ── Build the script that runs on the instance ────────────────────────────────
# Layout: the script's own shebang line, then `export KEY='value'` lines, then
# the rest of the script.
first_line=$(head -n 1 "$SSM_SCRIPT_PATH")
case "$first_line" in
  '#!'*) ;;
  *) fail "$SSM_SCRIPT_PATH must start with a shebang line" ;;
esac

prologue=""
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  case "$line" in '' | '#'*) continue ;; esac
  key=${line%%=*}
  # Do not echo the line: it may contain a value that should stay out of logs.
  [ "$key" != "$line" ] && [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
    fail "SSM_ENV line $line_no is not KEY=VALUE with a valid variable name"
  prologue+="export ${key}=$(shell_quote "${line#*=}")"$'\n'
done <<<"$SSM_ENV"

script="${first_line}"$'\n'"${prologue}$(tail -n +2 "$SSM_SCRIPT_PATH")"$'\n'
# SSM caps the size of the commands parameter (about 97 KB).
[ "${#script}" -lt 90000 ] || fail "script is too large for SSM Run Command"

# ── Resolve the instance and send the command ─────────────────────────────────
instance_id=$(aws ssm get-parameter --name "$SSM_INSTANCE_PARAM" --query "Parameter.Value" --output text)
[[ $instance_id =~ ^i-[0-9a-f]+$ ]] || fail "parameter $SSM_INSTANCE_PARAM does not hold an instance id"
echo "Instance: $instance_id"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

jq -n \
  --arg id "$instance_id" \
  --arg script "$script" \
  --arg timeout "$SSM_TIMEOUT" \
  --arg comment "GitHub Actions ${GITHUB_REPOSITORY:-local} run ${GITHUB_RUN_ID:-manual}: ${SSM_SCRIPT_PATH}" \
  '{
    InstanceIds: [$id],
    DocumentName: "AWS-RunShellScript",
    Comment: ($comment | .[0:100]),
    Parameters: {commands: [$script], executionTimeout: [$timeout]},
    TimeoutSeconds: ($timeout | tonumber)
  }' >"$workdir/payload.json"

command_id=$(aws ssm send-command \
  --cli-input-json "file://$workdir/payload.json" \
  --query "Command.CommandId" --output text)
[[ $command_id =~ ^[0-9a-f-]{36}$ ]] || fail "unexpected command id: $command_id"
echo "SSM command id: $command_id"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "command-id=$command_id" >>"$GITHUB_OUTPUT"
fi

# ── Wait for a final status ───────────────────────────────────────────────────
# The invocation record does not exist for a moment after send-command
# (InvocationDoesNotExist); that is treated as "pending", any other error is fatal.
start=$(date +%s)
deadline=$((start + SSM_TIMEOUT + 120))
last_status=""
while :; do
  if out=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query "Status" --output text 2>&1); then
    status=$out
  elif [[ $out == *InvocationDoesNotExist* ]]; then
    status="Pending"
  else
    fail "get-command-invocation failed: $out"
  fi

  if [ "$status" != "$last_status" ]; then
    echo "[$(($(date +%s) - start))s] status: $status"
    last_status=$status
  fi
  case "$status" in Success | Failed | Cancelled | TimedOut) break ;; esac

  [ "$(date +%s)" -lt "$deadline" ] || fail "gave up waiting for the command (last status: $status)"
  sleep "$SSM_POLL_INTERVAL"
done

# ── Show what happened ────────────────────────────────────────────────────────
# SSM returns at most 24,000 characters per stream.
result=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id")
echo "--- Output ---"
jq -r '.StandardOutputContent' <<<"$result"
echo "--- Error output ---"
jq -r '.StandardErrorContent' <<<"$result"

[ "$status" = "Success" ] || fail "command finished with status $status (exit code $(jq -r '.ResponseCode' <<<"$result"))"
echo "Command succeeded."
