#!/usr/bin/env bash
# ok and no always return 0, so 'test && ok || no' cannot run both.
# shellcheck disable=SC2015
# Tests for github-app-mint against a local fake of the GitHub API. Needs bash 4+, jq, openssl,
# python3. No network, no real key: a throwaway RSA key is made in a temporary folder.
#   bash test_github_app_mint.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=github-app-mint
source "$here/github-app-mint"
set +e  # the tests check exit codes themselves

t=$(mktemp -d); trap 'kill "${srv:-0}" 2>/dev/null; rm -rf "$t"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; }

openssl genrsa -out "$t/key.pem" 2048 2>/dev/null
openssl rsa -in "$t/key.pem" -pubout -out "$t/pub.pem" 2>/dev/null

# 1. The JSON Web Token: three parts, RS256 header, iss is the app id, and the signature verifies.
tok=$(jwt 4242 "$t/key.pem")
IFS=. read -r h p s <<<"$tok"
unb64() { local x=${1//-/+}; x=${x//_//}; while (( ${#x} % 4 )); do x+="="; done; printf '%s' "$x" | openssl base64 -d -A; }
[[ $(unb64 "$h" | jq -r .alg) == RS256 ]] && ok "jwt header RS256" || no "jwt header"
[[ $(unb64 "$p" | jq -r .iss) == 4242 ]] && ok "jwt iss is the app id" || no "jwt iss"
life=$(unb64 "$p" | jq '.exp - .iat'); (( life == 600 )) && ok "jwt lives 10 minutes from iat" || no "jwt life $life"
printf '%s.%s' "$h" "$p" >"$t/signed"; unb64 "$s" >"$t/sig"
openssl dgst -sha256 -verify "$t/pub.pem" -signature "$t/sig" "$t/signed" >/dev/null 2>&1 \
  && ok "jwt signature verifies" || no "jwt signature"

# 2. The request body narrows repositories and permissions; "-" means all repositories.
[[ $(body "a,b" "actions=read,metadata=read") == '{"repositories":["a","b"],"permissions":{"actions":"read","metadata":"read"}}' ]] \
  && ok "body with repositories" || no "body with repositories: $(body "a,b" "actions=read,metadata=read")"
[[ $(body "-" "issues=write") == '{"permissions":{"issues":"write"}}' ]] && ok "body for all repositories" || no "body all"

# 3. The whole run against a fake API: two installations, one token per target, one target not installed.
cat >"$t/fake.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if not self.headers.get("Authorization", "").startswith("Bearer ey"): return self.send(401, {"message": "Bad credentials"})
        if self.path.startswith("/app/installations"):
            return self.send(200, [{"id": 11, "account": {"login": "uncovertechtalent"}},
                                   {"id": 22, "account": {"login": "Uncovertechtalent-Git"}}])
        self.send(404, {"message": "Not Found"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        with open(sys.argv[2], "a") as f: f.write(self.path + " " + json.dumps(req, sort_keys=True) + "\n")
        inst = self.path.split("/")[3]
        self.send(201, {"token": "ghs_fake_" + inst, "expires_at": "2099-01-01T00:00:00Z"})
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1])); srv.serve_forever()
PY
python3 -I "$t/fake.py" "$t/port" "$t/requests" & srv=$!
for _ in $(seq 50); do [[ -s $t/port ]] && break; sleep 0.1; done
mkdir -p "$t/conf" "$t/cred" "$t/out"
cp "$t/key.pem" "$t/cred/github-app.reader.pem"; cp "$t/key.pem" "$t/cred/github-app.issues.pem"
printf 'reader 1\nissues 2\n' >"$t/conf/apps.conf"
uid=$(id -u)
cat >"$t/conf/targets.conf" <<EOF
# comment line is skipped
reader uncovertechtalent     $t/out/utt     $uid machinebehavior.io,tychat.io actions=read,metadata=read
reader uncovertechtalent-git $t/out/uttgit  $uid uncovertechtalent            actions=read,metadata=read
issues uncovertechtalent     $t/out/issues  $uid machinebehavior.io           issues=write,metadata=read
reader nobody-installed      $t/out/missing $uid -                            metadata=read
EOF
echo old >"$t/out/missing"
mkdir -p "$t/conf" "$t/textfile"
out=$(GITHUB_API="http://127.0.0.1:$(cat "$t/port")" GITHUB_APP_MINT_CONF_DIR="$t/conf" CREDENTIALS_DIRECTORY="$t/cred" \
      GITHUB_APP_MINT_TEXTFILE="$t/textfile/github_app_mint.prom" main 2>"$t/err"); rc=$?
[[ -n ${DEBUG:-} ]] && { echo "--- stdout"; echo "$out"; echo "--- stderr"; cat "$t/err"; }
(( rc == 1 )) && ok "exit 1 when one target fails" || no "exit code $rc"
[[ $(cat "$t/out/utt") == ghs_fake_11 && $(cat "$t/out/issues") == ghs_fake_11 ]] && ok "tokens of installation 11 written" || no "installation 11"
[[ $(cat "$t/out/uttgit") == ghs_fake_22 ]] && ok "owner matched without regard to case" || no "case-insensitive owner"
[[ $(cat "$t/out/missing") == old ]] && ok "failed target keeps its old file" || no "old file replaced"
grep -q "not installed on nobody-installed" "$t/err" && ok "missing installation reported" || no "missing installation message"
perm=$(stat -c %a "$t/out/utt" 2>/dev/null || stat -f %Lp "$t/out/utt"); [[ $perm == 600 ]] && ok "token file mode 600" || no "mode $perm"
grep -q 'access_tokens {"permissions": {"actions": "read", "metadata": "read"}, "repositories": \["machinebehavior.io", "tychat.io"\]}' "$t/requests" \
  && ok "request narrowed to repositories and permissions" || no "request body: $(head -1 "$t/requests")"
! grep -q ghs_fake <<<"$out$(cat "$t/err")" && ok "no token on stdout or stderr" || no "token printed"
left=$(find "$t/out" -name '.github-app-token.*' | wc -l); (( left == 0 )) && ok "no temporary files left" || no "temporary files left"

# 4. The textfile: one result and one file age per target, no token, no host path, readable by node_exporter.
m="$t/textfile/github_app_mint.prom"
[[ -s $m ]] && ok "textfile written" || no "textfile missing"
grep -q '^github_app_mint_target_ok{app="reader",owner="uncovertechtalent",service="'"$(basename "$t")"'",file="utt"} 1$' "$m" \
  && ok "minted target reported ok, service from the folder two levels up" || no "target ok line: $(grep target_ok "$m" | head -1)"
grep -q '^github_app_mint_target_ok{app="reader",owner="nobody-installed",.*} 0$' "$m" && ok "failed target reported 0" || no "failed target line"
[[ $(grep -c '^github_app_token_file_mtime_seconds{' "$m") == 4 ]] && ok "file age for every target, failed ones too" || no "mtime lines: $(grep -c mtime_seconds "$m")"
grep -q '^github_app_mint_last_run_timestamp_seconds [0-9]\+$' "$m" && ok "last run timestamp" || no "last run line"
! grep -q "ghs_fake\|$t" "$m" && ok "no token and no path in the textfile" || no "token or path in textfile"
perm=$(stat -c %a "$m" 2>/dev/null || stat -f %Lp "$m"); [[ $perm == 644 ]] && ok "textfile mode 644" || no "textfile mode $perm"
if command -v promtool >/dev/null; then
  promtool check metrics <"$m" >/dev/null 2>&1 && ok "promtool accepts the textfile" || no "promtool: $(promtool check metrics <"$m" 2>&1 | head -2)"
fi

# 5. A textfile folder the run cannot write: the exit code is still the mint result, nothing is left behind.
mkdir -p "$t/ro"; chmod 555 "$t/ro"
GITHUB_API="http://127.0.0.1:$(cat "$t/port")" GITHUB_APP_MINT_CONF_DIR="$t/conf" CREDENTIALS_DIRECTORY="$t/cred" \
  GITHUB_APP_MINT_TEXTFILE="$t/ro/github_app_mint.prom" bash -c 'set -euo pipefail; source "$1"; main' _ "$here/github-app-mint" \
  >/dev/null 2>"$t/err2"; rc=$?
if (( $(id -u) == 0 )); then
  echo "skip unwritable textfile folder (root writes anyway)"
else
  (( rc == 1 )) && ok "unwritable textfile folder keeps the mint exit code under set -e" || no "exit code $rc with unwritable textfile folder"
  grep -q "metrics: .* not written" "$t/err2" && ok "unwritable textfile folder reported" || no "no metrics message: $(cat "$t/err2")"
  left=$(find "$t/ro" -name '.github-app-mint.prom.*' | wc -l); (( left == 0 )) && ok "no temporary textfile left" || no "temporary textfile left"
fi
chmod 755 "$t/ro"

echo "$pass passed, $fail failed"
(( fail == 0 ))
