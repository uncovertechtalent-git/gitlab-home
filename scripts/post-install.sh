#!/bin/bash
# Settings that gitlab.rb does not cover, applied once after the first start
# and safe to run again. Waits for the container to be healthy first.
#   - sign-up off: accounts are made by an administrator
#   - new projects and groups private; public visibility not allowed at all
#   - the Prometheus metrics endpoint on (for the scraper of the host)
#   - telemetry and Gravatar off
set -euo pipefail
cd "$(dirname "$0")/.."

echo "waiting for the container to be healthy"
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gitlab)")" = healthy ]; do sleep 10; done

docker compose exec -T gitlab gitlab-rails runner - <<'RUBY'
s = ApplicationSetting.current
s.update!(
  signup_enabled: false,
  default_project_visibility: Gitlab::VisibilityLevel::PRIVATE,
  default_group_visibility: Gitlab::VisibilityLevel::PRIVATE,
  default_snippet_visibility: Gitlab::VisibilityLevel::PRIVATE,
  restricted_visibility_levels: [Gitlab::VisibilityLevel::PUBLIC],
  prometheus_metrics_enabled: true,
  gravatar_enabled: false,
  usage_ping_enabled: false
)
%i[signup_enabled default_project_visibility default_group_visibility restricted_visibility_levels
   prometheus_metrics_enabled gravatar_enabled usage_ping_enabled].each do |k|
  puts "#{k} = #{s.reload.public_send(k).inspect}"
end
RUBY
