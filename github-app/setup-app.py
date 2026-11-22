#!/usr/bin/env python3
"""Create a GitHub App from a manifest, with one click in the browser.

GitHub's manifest flow: a form posts the app's settings (the manifest) to GitHub, the owner clicks
"Create GitHub App", GitHub redirects back here with a one-time code, and this script trades the code
for the app's id and private key (POST /app-manifests/{code}/conversions, no token needed, valid for
one hour). Nothing is copied by hand and no secret is printed.

    python3 -I setup-app.py reader   # read-only app: Actions, contents, pull requests, issues
    python3 -I setup-app.py issues   # one write permission: issues

The owner must be signed in to github.com as the account that will own the app (OWNER below).
Output, in ~/.config/github-app/ (directory 700):
    <slug>.pem   the private key, mode 600. Move it to the host that mints tokens, then delete it here.
    <slug>.json  id, slug, client id, owner, and the page to install the app. No secret.

The client secret and the webhook secret in the conversion are not kept: tokens are minted with the
private key alone, and the app has no webhook.
"""
import html
import http.server
import json
import os
import pathlib
import secrets
import sys
import urllib.parse
import urllib.request

OWNER = os.environ.get("GITHUB_APP_OWNER", "uncovertechtalent")  # user account that owns the apps
HOME_URL = "https://machinebehavior.io/"
PORT = int(os.environ.get("GITHUB_APP_SETUP_PORT", "8765"))
OUT = pathlib.Path(os.environ.get("GITHUB_APP_DIR", "~/.config/github-app")).expanduser()

# Least privilege per app. Minted tokens can narrow these further (repositories and permissions).
APPS = {
    "reader": {
        "name": f"{OWNER}-house-reader",
        "description": "Read-only access for the house's own services: deploy runs and job logs for the "
                       "observability stack, repositories and their issues and pull requests for the mirror.",
        "permissions": {"actions": "read", "contents": "read", "issues": "read",
                        "pull_requests": "read", "metadata": "read"},
    },
    "issues": {
        "name": f"{OWNER}-house-issues",
        "description": "Opens, updates, and comments on issues for the house's alert receiver.",
        "permissions": {"issues": "write", "metadata": "read"},
    },
}


def manifest(kind):
    a = APPS[kind]
    return {
        "name": a["name"],
        "url": HOME_URL,
        "description": a["description"],
        # The app takes no events; GitHub still wants a hook URL in the manifest.
        "hook_attributes": {"url": HOME_URL, "active": False},
        "redirect_url": f"http://127.0.0.1:{PORT}/callback",
        # Public only so that other accounts (the organisation, the second user) can install it. Installing
        # it elsewhere gives nobody access to anything here: tokens need this app's private key.
        "public": True,
        "default_permissions": a["permissions"],
        "default_events": [],
    }


def form_page(kind, state):
    target = f"https://github.com/settings/apps/new?state={urllib.parse.quote(state)}"
    value = html.escape(json.dumps(manifest(kind)), quote=True)
    return f"""<!doctype html><meta charset="utf-8"><title>Create {html.escape(APPS[kind]['name'])}</title>
<p>Signed in to github.com as <b>{html.escape(OWNER)}</b>? This sends the app's settings to GitHub,
where you click <i>Create GitHub App</i>.</p>
<form method="post" action="{html.escape(target, quote=True)}">
<input type="hidden" name="manifest" value="{value}">
<button type="submit">Continue to GitHub</button></form>"""


def convert(code):
    req = urllib.request.Request(
        f"https://api.github.com/app-manifests/{urllib.parse.quote(code)}/conversions", method="POST",
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def save(conv):
    OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    slug = conv["slug"]
    pem = OUT / f"{slug}.pem"
    fd = os.open(pem, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(conv["pem"])
    meta = {"id": conv["id"], "slug": slug, "client_id": conv.get("client_id"),
            "owner": (conv.get("owner") or {}).get("login"), "html_url": conv.get("html_url"),
            "install_url": f"https://github.com/apps/{slug}/installations/new"}
    (OUT / f"{slug}.json").write_text(json.dumps(meta, indent=2) + "\n")
    return pem, meta


def main(argv):
    if len(argv) != 2 or argv[1] not in APPS:
        print(f"usage: {argv[0]} {'|'.join(APPS)}", file=sys.stderr)
        return 2
    kind, state = argv[1], secrets.token_urlsafe(24)
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):  # the callback URL carries the one-time code: keep it out of the log
            pass

        def reply(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path == "/":
                return self.reply(200, form_page(kind, state))
            if url.path != "/callback":
                return self.reply(404, "not found")
            q = urllib.parse.parse_qs(url.query)
            if q.get("state", [""])[0] != state or not q.get("code"):
                return self.reply(400, "state does not match; start again")
            try:
                pem, meta = save(convert(q["code"][0]))
            except Exception as e:  # noqa: BLE001 - report and stop, never retry a one-time code
                result["error"] = f"{type(e).__name__}: {e}"
                return self.reply(500, "conversion failed; see the terminal")
            result.update(pem=str(pem), meta=meta)
            self.reply(200, f"<p>Created <b>{html.escape(meta['slug'])}</b>. Install it: "
                            f"<a href=\"{html.escape(meta['install_url'])}\">{html.escape(meta['install_url'])}</a></p>")

    srv = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Open http://127.0.0.1:{PORT}/ in the browser where github.com is signed in as {OWNER}.", flush=True)
    while not result:
        srv.handle_request()
    srv.server_close()
    if "error" in result:
        print("failed:", result["error"], file=sys.stderr)
        return 1
    m = result["meta"]
    print(f"app {m['slug']} (id {m['id']}); private key {result['pem']} (mode 600, not printed)")
    print(f"install: {m['install_url']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
