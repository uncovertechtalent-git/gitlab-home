#!/bin/bash
# Revoke the token made by create-api-token.sh and delete its file.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T gitlab gitlab-rails runner - <<'RUBY'
user = User.find_by_username('root')
n = PersonalAccessToken.where(user: user, name: 'house-scripts', revoked: false).each(&:revoke!).size
puts "revoked #{n} token(s)"
RUBY
rm -f secrets/api_token
echo "removed secrets/api_token"
