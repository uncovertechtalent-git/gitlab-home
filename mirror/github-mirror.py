#!/usr/bin/env python3
"""Mirror GitHub repositories into GitLab and export their issues, pull requests and releases.

GitLab CE has no pull mirroring, so this job does it: for every repository of the
owners in OWNERS it keeps a bare mirror on disk (git clone --mirror, then remote
update --prune), pushes branches and tags to a private GitLab project
<GITLAB_GROUP>/<owner>/<repo>, and, when a GitHub token for the owner exists,
writes the issues, pull requests, comments, reviews and releases as JSON into the
GitLab project <GITLAB_GROUP>/metadata (one commit per run that changed anything).
Everything ends up in GitLab, so the nightly GitLab backup covers it.

Settings come from the environment file named by GITHUB_MIRROR_ENV (see
mirror/mirror.env.example). Tokens are systemd credentials (CREDENTIALS_DIRECTORY):
  github-mirror.gitlab_token        group access token of the GitLab group (required)
  github-mirror.token.<owner>       read-only GitHub token for that owner (optional;
                                    without it only the owner's public repositories
                                    are mirrored and no metadata is exported)
Standard library only. Exit status 1 when anything failed; the other repositories
are still done.
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
GITHUB_HEADERS = {"X-GitHub-Api-Version": "2022-11-28"}


def load_env(path):
    """KEY=VALUE lines of an environment file; blank lines and # comments are skipped."""
    out = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def next_link(header):
    """The rel="next" URL of a GitHub Link header, or None."""
    for part in (header or "").split(","):
        m = re.match(r'\s*<([^>]+)>;\s*rel="next"', part)
        if m:
            return m.group(1)
    return None


def project_path(name):
    """GitLab project path for a GitHub repository name (same name; GitLab refuses a trailing .git or .atom)."""
    path = re.sub(r"[^A-Za-z0-9_.-]", "-", name)
    if path[:1] in (".", "-"):                       # GitLab paths start with a letter, digit or underscore (".github")
        path = ("dot-" if path[0] == "." else "dash-") + path.lstrip(".-")
    for bad in (".git", ".atom"):
        if path.endswith(bad):
            path = path[: -len(bad)] + "-" + bad[1:]
    return path


class Http:
    """Small JSON client; one instance per base URL and token."""

    def __init__(self, token=None, header="Authorization", scheme="Bearer", extra=None):
        self.token, self.header, self.scheme = token, header, scheme
        self.extra = extra or {}
        self.last_headers = {}

    def request(self, method, url, data=None, ok404=False):
        headers = {"Accept": "application/json", "User-Agent": "github-mirror", **self.extra}
        if self.token:
            headers[self.header] = f"{self.scheme} {self.token}" if self.scheme else self.token
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                self.last_headers = dict(resp.headers)
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            if e.code == 410 or (ok404 and e.code == 404):    # 410: the feature (issues) is switched off for that repository
                self.last_headers = {}
                return None
            raise RuntimeError(f"{method} {url.split('?')[0]} -> HTTP {e.code}") from None

    def pages(self, url):
        """Every item of a paginated list endpoint."""
        items = []
        while url:
            items += self.request("GET", url, ok404=True) or []
            url = next_link(self.last_headers.get("Link"))
        return items


def run_git(args, env_extra=None, cwd=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    env.update(env_extra or {})
    res = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if res.returncode != 0:
        # git's own message can carry a URL but never a token (the token goes through GIT_ASKPASS)
        raise RuntimeError(f"git {args[0]} failed: {res.stderr.strip().splitlines()[-1] if res.stderr.strip() else res.returncode}")
    return res.stdout


class Mirror:
    def __init__(self, cfg, creds, args):
        self.cfg, self.creds, self.args = cfg, creds, args
        self.state = pathlib.Path(cfg.get("STATE_DIR", "/var/lib/github-mirror"))
        self.mirrors = self.state / "mirrors"
        self.meta_dir = self.state / "metadata"
        self.group = cfg.get("GITLAB_GROUP", "github")
        self.gl_url = cfg.get("GITLAB_URL", "http://127.0.0.1:8929").rstrip("/")
        self.gl = Http(creds.get("gitlab_token"), header="PRIVATE-TOKEN", scheme="")
        self.askpass = self.state / "askpass.sh"
        self.results = []
        self.failed = False
        self.group_ids = {}

    # ---- helpers -------------------------------------------------------------
    def log(self, msg):
        print(f"{datetime.datetime.now():%F %T} {msg}", flush=True)

    def fail(self, what, err):
        self.failed = True
        self.log(f"FAILED {what}: {err}")

    def write_askpass(self):
        self.state.mkdir(parents=True, exist_ok=True)
        self.askpass.write_text(
            '#!/bin/sh\ncase "$1" in Username*) printf "%s\\n" "$GIT_USERNAME_VALUE" ;; *) printf "%s\\n" "$GIT_PASSWORD_VALUE" ;; esac\n'
        )
        self.askpass.chmod(0o700)

    def git_auth(self, user, token):
        return {"GIT_ASKPASS": str(self.askpass), "GIT_USERNAME_VALUE": user, "GIT_PASSWORD_VALUE": token or ""}

    # ---- GitHub --------------------------------------------------------------
    def list_repos(self, owner, token):
        gh = Http(token, extra=GITHUB_HEADERS)
        info = gh.request("GET", f"{API}/users/{owner}")
        if info["type"] == "Organization":
            url = f"{API}/orgs/{owner}/repos?type=all&per_page=100"
        elif token:
            url = f"{API}/user/repos?affiliation=owner&visibility=all&per_page=100"
        else:
            url = f"{API}/users/{owner}/repos?type=owner&per_page=100"
        repos = [r for r in gh.pages(url) if r["owner"]["login"].lower() == owner.lower()]
        expiry = gh.last_headers.get("github-authentication-token-expiration")
        if expiry:
            self.log(f"{owner}: GitHub token expires {expiry}")
        return sorted(repos, key=lambda r: r["name"])

    # ---- GitLab --------------------------------------------------------------
    def gl_api(self, method, path, data=None, ok404=False):
        return self.gl.request(method, f"{self.gl_url}/api/v4{path}", data, ok404)

    def group_id(self, owner):
        """Id of the subgroup <group>/<owner>, created under the group when missing."""
        if owner in self.group_ids:
            return self.group_ids[owner]
        full = urllib.parse.quote(f"{self.group}/{owner}", safe="")
        g = self.gl_api("GET", f"/groups/{full}", ok404=True)
        if g is None:
            parent = self.gl_api("GET", f"/groups/{urllib.parse.quote(self.group, safe='')}")
            g = self.gl_api("POST", "/groups", {"name": owner, "path": owner, "parent_id": parent["id"], "visibility": "private"})
            self.log(f"created GitLab group {self.group}/{owner}")
        self.group_ids[owner] = g["id"]
        return g["id"]

    def ensure_project(self, owner, repo):
        path = project_path(repo["name"])
        full = urllib.parse.quote(f"{self.group}/{owner}/{path}", safe="")
        proj = self.gl_api("GET", f"/projects/{full}", ok404=True)
        if proj is None:
            kind = "private" if repo["private"] else "public"
            note = f"Mirror of https://github.com/{owner}/{repo['name']} ({kind}{', fork' if repo['fork'] else ''}). A copy for safekeeping, refreshed daily; do not push here."
            proj = self.gl_api("POST", "/projects", {
                "name": repo["name"], "path": path, "namespace_id": self.group_id(owner),
                "visibility": "private", "initialize_with_readme": "false", "description": note,
                "lfs_enabled": "false",
            })
            self.log(f"created GitLab project {self.group}/{owner}/{path}")
        return proj

    def release_branch_protection(self, proj, default_branch):
        """The mirror push is forced: allow force push on whatever GitLab protected."""
        if default_branch and proj.get("default_branch") != default_branch:
            self.gl_api("PUT", f"/projects/{proj['id']}", {"default_branch": default_branch})
        for pb in self.gl_api("GET", f"/projects/{proj['id']}/protected_branches") or []:
            if not pb.get("allow_force_push"):
                self.gl_api("PATCH", f"/projects/{proj['id']}/protected_branches/{urllib.parse.quote(pb['name'], safe='')}",
                            {"allow_force_push": "true"})

    # ---- one repository ------------------------------------------------------
    def mirror_repo(self, owner, repo, token):
        name = repo["name"]
        local = self.mirrors / owner / f"{name}.git"
        url = f"https://github.com/{owner}/{name}.git"
        auth = self.git_auth("x-access-token", token) if token else {}
        if local.exists():
            run_git(["remote", "update", "--prune"], auth, cwd=local)
        else:
            local.parent.mkdir(parents=True, exist_ok=True)
            run_git(["clone", "--mirror", "--quiet", url, str(local)], auth)
        heads = run_git(["for-each-ref", "refs/heads", "refs/tags"], cwd=local).strip()
        if not heads:
            return "empty (no branches or tags)"
        if self.args.no_push:
            return "fetched"
        proj = self.ensure_project(owner, repo)
        if proj.get("lfs_enabled"):
            # With LFS on, GitLab refuses a push whose LFS objects it does not hold, and
            # git clone --mirror never fetches them: the copy keeps the pointer files only.
            self.gl_api("PUT", f"/projects/{proj['id']}", {"lfs_enabled": "false"})
        target = f"{self.gl_url}/{self.group}/{owner}/{project_path(name)}.git"
        run_git(["push", "--prune", "--quiet", target, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
                self.git_auth("oauth2", self.creds["gitlab_token"]), cwd=local)
        self.release_branch_protection(proj, repo.get("default_branch"))
        return "mirrored"

    # ---- metadata ------------------------------------------------------------
    def export_metadata(self, owner, repo, token, meta_root):
        gh = Http(token, extra=GITHUB_HEADERS)
        base = f"{API}/repos/{owner}/{repo['name']}"
        out = meta_root / owner / repo["name"]
        out.mkdir(parents=True, exist_ok=True)

        def dump(fname, data):
            text = json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
            p = out / fname
            if not p.exists() or p.read_text() != text:
                p.write_text(text)

        issues = gh.pages(f"{base}/issues?state=all&per_page=100")      # pull requests are in here too
        dump("issues.json", issues)
        dump("issue_comments.json", gh.pages(f"{base}/issues/comments?per_page=100"))
        pulls = gh.pages(f"{base}/pulls?state=all&per_page=100")
        dump("pulls.json", pulls)
        dump("pull_review_comments.json", gh.pages(f"{base}/pulls/comments?per_page=100"))
        dump("pull_reviews.json", {str(p["number"]): gh.pages(f"{base}/pulls/{p['number']}/reviews?per_page=100") for p in pulls})
        dump("releases.json", gh.pages(f"{base}/releases?per_page=100"))
        return len(issues) - len(pulls), len(pulls)

    def sync_metadata(self, exported):
        """Commit and push what changed in the metadata clone."""
        if not exported or self.args.no_push:
            return
        proj_url = f"{self.gl_url}/{self.group}/metadata.git"
        auth = self.git_auth("oauth2", self.creds["gitlab_token"])
        run_git(["add", "-A"], cwd=self.meta_dir)
        if not run_git(["status", "--porcelain"], cwd=self.meta_dir).strip():
            self.log("metadata: no change")
            return
        run_git(["-c", "user.name=github-mirror", "-c", "user.email=github-mirror@localhost", "commit", "--quiet",
                 "-m", f"GitHub metadata {datetime.date.today()}: {len(exported)} repositories"], cwd=self.meta_dir)
        run_git(["push", "--quiet", proj_url, "HEAD:refs/heads/main"], auth, cwd=self.meta_dir)
        self.log("metadata: committed and pushed")

    def prepare_metadata_clone(self):
        proj_url = f"{self.gl_url}/{self.group}/metadata.git"
        auth = self.git_auth("oauth2", self.creds["gitlab_token"])
        if not (self.meta_dir / ".git").exists():
            self.meta_dir.mkdir(parents=True, exist_ok=True)
            run_git(["init", "--quiet", "-b", "main"], cwd=self.meta_dir)
        try:
            # Every run starts from what GitLab holds, so the push below is a fast-forward
            # even after someone else touched the project.
            run_git(["fetch", "--quiet", proj_url, "main"], auth, cwd=self.meta_dir)
            run_git(["reset", "--quiet", "--hard", "FETCH_HEAD"], cwd=self.meta_dir)
        except RuntimeError:
            pass   # an empty project: the first commit creates main

    # ---- run -----------------------------------------------------------------
    def run(self):
        self.write_askpass()
        exp = self.gl_api("GET", "/personal_access_tokens/self", ok404=True)
        if exp and exp.get("expires_at"):
            days = (datetime.date.fromisoformat(exp["expires_at"]) - datetime.date.today()).days
            self.log(f"GitLab token expires {exp['expires_at']} ({days} days)" + ("  RENEW SOON" if days < 30 else ""))
        owners = self.args.owners or self.cfg["OWNERS"].split()
        exported = set()
        meta_ready = False
        for owner in owners:
            token = self.creds.get(f"token.{owner}")
            try:
                repos = self.list_repos(owner, token)
            except Exception as e:  # noqa: BLE001 - one owner failing must not stop the others
                self.fail(f"listing {owner}", e)
                continue
            self.log(f"{owner}: {len(repos)} repositories ({'token' if token else 'no token, public only'})")
            for repo in repos:
                if self.args.only and f"{owner}/{repo['name']}" not in self.args.only:
                    continue
                label = f"{owner}/{repo['name']}"
                try:
                    status = self.mirror_repo(owner, repo, token)
                    self.log(f"{label}: {status}")
                    self.results.append({"repo": label, "status": status})
                except Exception as e:  # noqa: BLE001
                    self.fail(label, e)
                    self.results.append({"repo": label, "status": f"FAILED: {e}"})
                    continue
                if (token or self.args.anon_metadata) and not self.args.no_metadata:
                    try:
                        if not meta_ready:
                            self.prepare_metadata_clone()
                            meta_ready = True
                        issues, pulls = self.export_metadata(owner, repo, token, self.meta_dir)
                        exported.add(label)
                        self.log(f"{label}: metadata {issues} issues, {pulls} pull requests")
                    except Exception as e:  # noqa: BLE001
                        self.fail(f"metadata of {label}", e)
        try:
            self.sync_metadata(exported)
        except Exception as e:  # noqa: BLE001
            self.fail("metadata push", e)
        status = {"finished": datetime.datetime.now().isoformat(timespec="seconds"), "failed": self.failed, "repos": self.results}
        (self.state / "status.json").write_text(json.dumps(status, indent=1) + "\n")
        if not self.failed:
            (self.state / "LAST_OK").write_text(status["finished"] + "\n")
        self.log(f"done: {len(self.results)} repositories, {'with failures' if self.failed else 'no failures'}")
        return 1 if self.failed else 0


def load_credentials(directory):
    creds = {}
    p = pathlib.Path(directory or "")
    if directory and p.is_dir():
        for f in p.iterdir():
            if f.name.startswith("github-mirror."):
                creds[f.name[len("github-mirror."):]] = f.read_text().strip()
    return creds


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--owners", nargs="*", help="override OWNERS")
    ap.add_argument("--only", nargs="*", help="owner/repo names; others are skipped")
    ap.add_argument("--no-push", action="store_true", help="fetch from GitHub only")
    ap.add_argument("--no-metadata", action="store_true")
    ap.add_argument("--anon-metadata", action="store_true", help="export metadata without a token (60 requests an hour; for tests)")
    args = ap.parse_args(argv)
    cfg = load_env(os.environ.get("GITHUB_MIRROR_ENV", "/etc/github-mirror/mirror.env"))
    creds = load_credentials(os.environ.get("CREDENTIALS_DIRECTORY"))
    if "gitlab_token" not in creds:
        print("missing credential github-mirror.gitlab_token", file=sys.stderr)
        return 2
    return Mirror(cfg, creds, args).run()


if __name__ == "__main__":
    sys.exit(main())
