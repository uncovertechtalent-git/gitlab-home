#!/bin/bash
# Create a short-lived personal access token for the root account and store it
# in ./secrets/api_token (mode 600). The token is written straight from the
# Rails runner into the file and never printed. The import script reads it.
#   usage: scripts/create-api-token.sh [days]      (default 7, at most 30)
# Revoke it when the work is done: scripts/revoke-api-token.sh
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

days="${1:-7}"
case "$days" in '' | *[!0-9]*) echo "days must be a number" >&2; exit 64 ;; esac
[ "$days" -ge 1 ] && [ "$days" -le 30 ] || { echo "days must be 1 to 30" >&2; exit 64; }

mkdir -p secrets
chmod 700 secrets
tmp="$(mktemp secrets/.api_token.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

docker compose exec -T gitlab gitlab-rails runner - >"$tmp" <<RUBY
user = User.find_by_username('root')
PersonalAccessToken.where(user: user, name: 'house-scripts', revoked: false).each(&:revoke!)
token = user.personal_access_tokens.create!(name: 'house-scripts', scopes: [:api], expires_at: Date.today + $days)
\$stdout.write(token.token)
RUBY

[ "$(wc -c <"$tmp")" -ge 20 ] || { echo "no token came back" >&2; exit 1; }
chmod 600 "$tmp"
mv "$tmp" secrets/api_token
echo "created secrets/api_token (expires in $days days)"
