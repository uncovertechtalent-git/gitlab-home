#!/bin/bash
# One-time GitLab side of the GitHub mirror: the group, one subgroup per owner,
# the metadata project, and a group access token (role Maintainer, scope api,
# 360 days) written to ./secrets/github_mirror_gitlab_token without printing it.
# Safe to run again: what exists is kept; the token is made only when none is
# active, or when asked (--renew), which revokes the old one.
#   usage: mirror/setup-gitlab.sh [--renew] <owner> [<owner> ...]
# Needs secrets/api_token (scripts/create-api-token.sh); run it on the GitLab machine.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

renew=no
if [ "${1:-}" = "--renew" ]; then renew=yes; shift; fi
[ "$#" -ge 1 ] || { echo "usage: mirror/setup-gitlab.sh [--renew] <owner> [<owner> ...]" >&2; exit 64; }
group="${GITLAB_GROUP:-github}"
port="$(sed -n 's/^GITLAB_HTTP_PORT=//p' .env)"
base="http://127.0.0.1:${port:-8929}"
[ -s secrets/api_token ] || { echo "secrets/api_token is missing: run scripts/create-api-token.sh" >&2; exit 1; }

api() { # <method> <path> [curl args]
  local m=$1 p=$2
  shift 2
  curl -fsS -X "$m" -K <(printf 'header = "PRIVATE-TOKEN: %s"\n' "$(cat secrets/api_token)") "$base/api/v4$p" "$@"
}
field() { python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

group_id() { # <full path>: id, or empty
  api GET "/groups/$(enc "$1")" 2>/dev/null | field id 2>/dev/null || true
}

gid="$(group_id "$group")"
if [ -z "$gid" ]; then
  gid="$(api POST /groups --data-urlencode "name=$group" --data-urlencode "path=$group" --data-urlencode "visibility=private" | field id)"
  echo "created group $group (id $gid)"
fi
for owner in "$@"; do
  if [ -z "$(group_id "$group/$owner")" ]; then
    api POST /groups --data-urlencode "name=$owner" --data-urlencode "path=$owner" --data-urlencode "parent_id=$gid" \
      --data-urlencode "visibility=private" >/dev/null
    echo "created group $group/$owner"
  fi
done
if ! api GET "/projects/$(enc "$group/metadata")" >/dev/null 2>&1; then
  api POST /projects --data-urlencode "name=metadata" --data-urlencode "path=metadata" --data-urlencode "namespace_id=$gid" \
    --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" \
    --data-urlencode "description=Issues, pull requests, comments, reviews and releases exported from GitHub, one folder per repository. Written by the github-mirror job." >/dev/null
  echo "created project $group/metadata"
fi

active="$(api GET "/groups/$gid/access_tokens" | python3 -c '
import json, sys
print(sum(1 for t in json.load(sys.stdin) if t["name"] == "github-mirror" and t["active"]))')"
if [ "$active" -gt 0 ] && [ "$renew" = no ]; then
  echo "a group access token github-mirror is active already; use --renew to replace it"
  exit 0
fi
if [ "$renew" = yes ]; then
  api GET "/groups/$gid/access_tokens" | python3 -c '
import json, sys
for t in json.load(sys.stdin):
    if t["name"] == "github-mirror" and t["active"]:
        print(t["id"])' | while read -r tid; do api DELETE "/groups/$gid/access_tokens/$tid" >/dev/null; echo "revoked token $tid"; done
fi
expires="$(date -d '+360 days' +%F)"
tmp="$(mktemp secrets/.ghm.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
api POST "/groups/$gid/access_tokens" --data-urlencode "name=github-mirror" --data-urlencode "scopes[]=api" \
  --data-urlencode "access_level=40" --data-urlencode "expires_at=$expires" | field token >"$tmp"
[ "$(wc -c <"$tmp")" -ge 20 ] || { echo "no token came back" >&2; exit 1; }
chmod 600 "$tmp"
mv "$tmp" secrets/github_mirror_gitlab_token
echo "created secrets/github_mirror_gitlab_token (group $group, Maintainer, expires $expires)"
echo "next: sudo install -m 600 secrets/github_mirror_gitlab_token /etc/credstore/github-mirror.gitlab_token && rm secrets/github_mirror_gitlab_token"
