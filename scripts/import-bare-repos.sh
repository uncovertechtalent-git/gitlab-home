#!/bin/bash
# Import bare git repositories into GitLab as private projects of one group.
# Each <name>.git in the folder becomes <group>/<name>, with every branch and
# tag (git push --mirror). A project that exists already is left alone unless
# its repository is empty.
#   usage: scripts/import-bare-repos.sh <group> <folder> [name ...]
# Needs secrets/api_token (scripts/create-api-token.sh) and the web port on the
# loopback address; run it on the GitLab machine.
set -euo pipefail
cd "$(dirname "$0")/.."

group="${1:?usage: import-bare-repos.sh <group> <folder> [name ...]}"
folder="${2:?usage: import-bare-repos.sh <group> <folder> [name ...]}"
shift 2
port="$(sed -n 's/^GITLAB_HTTP_PORT=//p' .env)"
base="http://127.0.0.1:${port:-8929}"
[ -s secrets/api_token ] || { echo "secrets/api_token is missing: run scripts/create-api-token.sh" >&2; exit 1; }

# The token reaches curl as a header from a config on stdin and git through an
# askpass helper; it never appears on a command line.
api() { # <method> <path> [curl args]
  local m=$1 p=$2
  shift 2
  curl -fsS -X "$m" -K <(printf 'header = "PRIVATE-TOKEN: %s"\n' "$(cat secrets/api_token)") "$base/api/v4$p" "$@"
}
askpass="$(mktemp)"
trap 'rm -f "$askpass"' EXIT
cat >"$askpass" <<'ASK'
#!/bin/sh
case "$1" in
  Username*) echo oauth2 ;;
  *) cat "$GITLAB_TOKEN_FILE" ;;
esac
ASK
chmod 700 "$askpass"

# The group, private.
gid="$(api GET "/groups?search=$group" | python3 -c '
import json, sys
g = [x for x in json.load(sys.stdin) if x["path"] == sys.argv[1]]
print(g[0]["id"] if g else "")' "$group")"
if [ -z "$gid" ]; then
  gid="$(api POST /groups --data-urlencode "name=$group" --data-urlencode "path=$group" \
    --data-urlencode "visibility=private" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
  echo "created group $group (id $gid)"
fi

if [ "$#" -gt 0 ]; then names=("$@"); else
  names=()
  for d in "$folder"/*.git; do n="$(basename "$d" .git)"; names+=("$n"); done
fi

for n in "${names[@]}"; do
  src="$folder/$n.git"
  [ -d "$src" ] || { echo "no such repository: $src" >&2; exit 1; }
  proj="$(api GET "/projects/$(printf '%s' "$group/$n" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')" 2>/dev/null || true)"
  if [ -z "$proj" ]; then
    api POST /projects --data-urlencode "name=$n" --data-urlencode "path=$n" --data-urlencode "namespace_id=$gid" \
      --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" >/dev/null
    echo "created project $group/$n"
  elif [ "$(printf '%s' "$proj" | python3 -c 'import json, sys; print(json.load(sys.stdin)["empty_repo"])')" != True ]; then
    echo "skipped $group/$n: the project exists and has commits"
    continue
  fi
  GITLAB_TOKEN_FILE="$PWD/secrets/api_token" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git -C "$src" push --mirror "$base/$group/$n.git" 2>&1 | tail -2
  echo "imported $group/$n"
done
