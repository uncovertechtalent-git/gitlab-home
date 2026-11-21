#!/bin/bash
# Add a public ssh key as a write-enabled deploy key to every project of a
# group. A deploy key belongs to no person: a laptop that only pushes needs
# nothing more, and removing the key (Settings, Repository, Deploy keys, or
# the API) cuts that machine off. Safe to run again: projects that have the
# key already are skipped.
#   usage: scripts/add-deploy-key.sh <group> <public key file> <title>
# Needs secrets/api_token (scripts/create-api-token.sh); run it on the GitLab machine.
set -euo pipefail
cd "$(dirname "$0")/.."

group="${1:?usage: add-deploy-key.sh <group> <public key file> <title>}"
keyfile="${2:?usage: add-deploy-key.sh <group> <public key file> <title>}"
title="${3:?usage: add-deploy-key.sh <group> <public key file> <title>}"
port="$(sed -n 's/^GITLAB_HTTP_PORT=//p' .env)"
base="http://127.0.0.1:${port:-8929}"
[ -s secrets/api_token ] || { echo "secrets/api_token is missing: run scripts/create-api-token.sh" >&2; exit 1; }
grep -q '^ssh-' "$keyfile" || { echo "$keyfile is not a public ssh key" >&2; exit 1; }

api() { # <method> <path> [curl args]
  local m=$1 p=$2
  shift 2
  curl -fsS -X "$m" -K <(printf 'header = "PRIVATE-TOKEN: %s"\n' "$(cat secrets/api_token)") "$base/api/v4$p" "$@"
}
field() { python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# One page of 100 projects; a group with more needs paging here.
ids="$(api GET "/groups/$group/projects?per_page=100" | python3 -c 'import json, sys; print(*[p["id"] for p in json.load(sys.stdin)])')"
# The key may already exist in another project (a deploy key's fingerprint is unique
# on the instance): look it up by title first and enable it where it is missing.
key_id="$(api GET "/deploy_keys?per_page=100" | python3 -c '
import json, sys
k = [x["id"] for x in json.load(sys.stdin) if x["title"] == sys.argv[1]]
print(k[0] if k else "")' "$title")"
for id in $ids; do
  existing="$(api GET "/projects/$id/deploy_keys" | python3 -c '
import json, sys
k = [x["id"] for x in json.load(sys.stdin) if x["title"] == sys.argv[1]]
print(k[0] if k else "")' "$title")"
  if [ -n "$existing" ]; then
    echo "project $id has the key already"
    continue
  fi
  if [ -z "$key_id" ]; then
    key_id="$(api POST "/projects/$id/deploy_keys" --data-urlencode "title=$title" \
      --data-urlencode "key@$keyfile" --data-urlencode "can_push=true" | field id)"
    echo "project $id: created deploy key $key_id"
  else
    api POST "/projects/$id/deploy_keys/$key_id/enable" >/dev/null
    api PUT "/projects/$id/deploy_keys/$key_id" --data-urlencode "can_push=true" >/dev/null
    echo "project $id: enabled deploy key $key_id with push"
  fi
done
