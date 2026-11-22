# gitlab-home

GitLab CE for a home: one private forge for the repositories that must not live on a single laptop, in Docker Compose on one machine. It is reachable on the home network and over a Tailscale network, and nowhere else. A nightly job copies a full GitLab backup and the configuration to a NAS.

The public side stays on GitHub. This forge holds what stays private (a notes vault, dotfiles, experiments, agent memory) and is the second copy of everything that matters when a laptop dies.

```
docker-compose.yml      the stack: one GitLab CE container, pinned image, memory tuned for 16 GB
.env.example            version, name, ports, memory limit. No secrets.
scripts/
  init-secrets.sh       creates ./secrets/root_password (random, mode 600), never printed
  post-install.sh       settings gitlab.rb does not cover: sign-up off, private by default, metrics on
  create-api-token.sh   a short-lived root token for the scripts below, written to a file, never printed
  revoke-api-token.sh   revokes it and deletes the file
  import-bare-repos.sh  bare repositories in a folder become private projects of one group
  add-deploy-key.sh     a public ssh key becomes a write deploy key on every project of a group
mirror/
  github-mirror.py      mirrors GitHub repositories into GitLab and exports issues, pull requests and releases
  github-mirror.service, github-mirror.timer   the daily job (03:30)
  mirror.env.example    owners and group; no secrets
  setup-gitlab.sh       the GitLab group, subgroups, metadata project and the job's group token
  test_github_mirror.py unit tests of the helpers
caddy/
  gitlab.caddy.example  the site snippet for the reverse proxy (lan-proxy in nextcloud-home)
backup/
  gitlab-backup.sh      the nightly job (runs as root)
  gitlab-backup.service systemd unit for the job
  gitlab-backup.timer   02:30 every night
  restore-project.sh    one project's repository out of a backup tar, without a running GitLab
  backup.env.example    where the NAS is, which key, how long to keep
```

## Design

| Piece | Choice | Why |
|---|---|---|
| GitLab | `gitlab/gitlab-ce`, pinned to one patch release (`GITLAB_VERSION`) | Upgrades must be deliberate: GitLab has required upgrade stops, and a floating tag breaks them. |
| Size | one container, `mem_limit` 16 GB, Puma 3 workers, Sidekiq concurrency 10, PostgreSQL `shared_buffers` 1 GB, bundled Prometheus and the Kubernetes agent off | GitLab's own requirements page gives 16 GB and 8 vCPU as the single-node baseline and 8 GB as the floor. Omnibus sizes some parts from the memory of the whole host, not from the container limit, so the large ones are set by hand. |
| Web | container port 80 on `127.0.0.1:8929`, TLS at the reverse proxy | One front door with one wildcard certificate (`lan-proxy` in the `nextcloud-home` repository). GitLab's own Let's Encrypt is off. |
| Git over ssh | the container's sshd on host port 2222 | Port 22 of the host is the host's own sshd. The port is part of every clone URL (`gitlab_shell_ssh_port`). |
| Exposure | web on loopback only, ssh on all interfaces; no router port forward, no public DNS | The LAN interface and the Tailscale interface are the two ways in. This holds only while the machine has no other routable interface and the router forwards nothing to it. |
| Accounts | sign-up off, one initial `root` password from a mode-600 file | Accounts are made by an administrator. The first thing to do after the first start is to create a personal administrator account, set up two-factor authentication on it, and stop using `root`. |
| Visibility | new projects and groups private; public visibility not allowed | A private forge has no public projects. |
| Secrets | files under `./secrets` (directory 700, files 600), passed in as a compose secret | No password in the compose file, in `.env`, in the repo, or on a command line. |
| Data | bind mounts `./config`, `./data`, `./logs` next to the compose file | Easy to find and to back up. |
| Web IDE | single-origin fallback off, extension marketplace off | With the fallback on, GitLab serves VS Code's assets from its own origin when the extension host domain (a public CDN of GitLab's) is unreachable; GitLab's admin banner calls that a high-severity risk. The cost: the Web IDE needs that domain reachable from the browser. |
| Metrics | the Rails endpoint `/-/metrics` on, bundled Prometheus off | The proxy refuses the path; a scraper on the same machine reads the loopback port. |

## Install

You need Docker with the Compose plugin, free ports, a reverse proxy that serves `https://<GITLAB_HOSTNAME>`, and DNS records for that name (LAN and tailnet).

```sh
git clone https://github.com/uncovertechtalent-git/gitlab-home.git ~/services/gitlab
cd ~/services/gitlab
cp .env.example .env            # edit: GITLAB_HOSTNAME (and the ports if they are taken)
sh scripts/init-secrets.sh      # makes ./secrets/root_password
mkdir -p config data logs
docker compose up -d            # the first start takes five to ten minutes
sh scripts/post-install.sh      # settings; waits until the container is healthy
```

Put `caddy/gitlab.caddy.example` into the proxy's `sites/` folder as `gitlab.caddy` and reload the proxy. Check:

```sh
docker compose ps                                            # healthy
curl -sS -o /dev/null -w '%{http_code}\n' https://<GITLAB_HOSTNAME>/users/sign_in   # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://<GITLAB_HOSTNAME>/-/metrics        # 403 from the proxy
```

The first password of `root` is in `secrets/root_password` on the machine. To put it on your own clipboard without printing it, run `ssh <machine> 'cat ~/services/gitlab/secrets/root_password' | pbcopy` on a Mac. Log in, create your own account with the Administrator role, sign in as that account, set up two-factor authentication, then block or demote `root`. After that the file is out of date.

### Put existing repositories in

Bare repositories (`name.git` folders) become private projects of one group. Run it on the GitLab machine:

```sh
sh scripts/create-api-token.sh 1         # a token for one day, in ./secrets/api_token
sh scripts/import-bare-repos.sh house /path/to/bare-repos
sh scripts/revoke-api-token.sh
```

For each repository the script creates `<group>/<name>`, private, and pushes every branch and tag (`git push --mirror`). A project that already has commits is skipped. Afterwards clone each project once and compare `HEAD` with the source before you delete the source.

### Push access for a machine

A write-enabled **deploy key** per machine is enough for a laptop that only pushes: the key belongs to no person and is removed with one click when the machine is lost.

```sh
sh scripts/create-api-token.sh 1
sh scripts/add-deploy-key.sh house /path/to/key.pub "laptop push key"
sh scripts/revoke-api-token.sh
```

A personal ssh key on your own account works the same way and reaches everything you can reach.

## Upgrade

Once a month, after a backup:

1. `systemctl start gitlab-backup.service`, and check that the run ended with `done <stamp>` and that `LAST_OK` on the NAS holds the stamp.
2. Read the [upgrade path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/) for the current version and the one you want. GitLab needs certain versions on the way (required stops); skipping one breaks the database migration.
3. Change `GITLAB_VERSION` in `.env` to the next stop (or the target), `docker compose pull && docker compose up -d`. The container migrates the database on start; the first start after an upgrade takes several minutes. Background migrations keep running after the web interface is up: Admin area, Monitoring, Background migrations, must show them finished before the next upgrade.
4. `docker compose ps` shows `healthy`; sign in; open a project; clone one.

Patch releases inside one minor version (19.5.8 to 19.5.9) can be taken at any time and carry security fixes: subscribe to the GitLab security release notices.

To roll back, restore the backup of step 1 into the older image (see Restore). A database migration cannot be undone by starting the old image.

## Backup

### What is backed up, and where it goes

`backup/gitlab-backup.sh` runs as root every night at 02:30 (the timer adds up to five minutes of random delay). It logs in to the NAS over ssh and writes under one folder there (`NAS_DIR`), which only root can read:

```
backups/<stamp>_gitlab_backup.tar    GitLab's own backup: database, repositories, uploads, ...
config/config-<stamp>.tar            config/ (gitlab.rb, gitlab-secrets.json, ssh host keys), .env, docker-compose.yml
LAST_OK                              stamp of the last run that finished
```

A run takes these steps:

1. `gitlab-backup create STRATEGY=copy` inside the container. GitLab copies each repository before it archives it, so a push during the run cannot tear the archive. The script lists the finished tar and refuses one without a database dump.
2. A config archive. `gitlab-secrets.json` holds the keys that encrypt two-factor secrets and CI variables in the database; it is not part of the backup tar, and a restore without it loses them. The ssh host keys sit in `config/` too, so a restored machine keeps its identity and clients' `known_hosts` stay valid. The initial root password file is left out.
3. Both files are streamed to the NAS as `.partial` files, compared by size with the local file, then renamed into place.
4. `LAST_OK` is written, old files on the NAS are removed (newest 28 kept, `KEEP`), and local backup tars beyond the newest two are removed (`KEEP_LOCAL`).

A run takes the lock `/run/lock/gitlab-backup.lock`, so two runs never overlap, and it refuses to start when the container is not healthy.

The config archive and the backup tar sit in the same NAS folder, which is mode 700 and owned by root. That is what makes a restore possible with nothing but the NAS, and it is why the folder must never be shared to other users through SMB, NFS or a sync service.

### Install the job

On the GitLab machine, as a user with sudo:

```sh
sudo install -d /etc/gitlab-home
sudo install -m 600 backup/backup.env.example /etc/gitlab-home/backup.env   # then edit it
sudo install -m 755 backup/gitlab-backup.sh /usr/local/sbin/gitlab-backup
sudo install -m 644 backup/gitlab-backup.service backup/gitlab-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

`backup.env` names the NAS user and address, the folder on the NAS, the private key and the `known_hosts` file. The key can be the one an existing NAS backup job already uses. By default the NAS user needs passwordless `sudo` and the files are written as root; the safer set-up is a dedicated NAS user that owns `NAS_DIR`, with `NAS_SUDO=` (empty). Run it once by hand and look at the result before you arm the timer:

```sh
sudo systemctl start gitlab-backup.service
sudo journalctl -u gitlab-backup.service -n 30 -o cat      # ends with "done <stamp>"
sudo systemctl enable --now gitlab-backup.timer
systemctl list-timers gitlab-backup.timer
```

### Watch it

Nothing in this repository alerts when the job stops. `LAST_OK` on the NAS and `systemctl list-timers` are the two places to look; an alert on the age of `LAST_OK` is the missing piece.

## Restore

A restore point is one stamp: the backup tar and the config archive of that stamp. Restore into the same GitLab version that made the backup; GitLab refuses a mismatch. Do it as root on the machine that will run GitLab, which can be a new machine.

```sh
. /etc/gitlab-home/backup.env
SUDO=${NAS_SUDO-sudo}
nas() { ssh -n -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" "$NAS_TARGET" "$@"; }
STACK=/path/to/services/gitlab ; mkdir -p "$STACK" && cd "$STACK"
stamp=$(nas "$SUDO cat $NAS_DIR/LAST_OK")       # or any stamp from backups/
```

1. **Compose files and configuration.** The config archive restores `config/`, `.env` and `docker-compose.yml`. Set `GITLAB_VERSION` in `.env` to the version of the backup (it is in the tar's `backup_information.yml`). `scripts/init-secrets.sh` recreates the root password file, which only seeds an empty database.

   ```sh
   nas "$SUDO cat $NAS_DIR/config/config-$stamp.tar" | tar -x --numeric-owner -C "$STACK"
   sh scripts/init-secrets.sh
   ```

2. **The backup tar** goes where GitLab looks for it, owned by the container's `git` user:

   ```sh
   mkdir -p data/backups
   nas "$SUDO cat $NAS_DIR/backups/${stamp}_gitlab_backup.tar" > "data/backups/${stamp}_gitlab_backup.tar"
   ```

3. **Start, stop the writers, restore.** Start GitLab on the restored configuration with an empty database, wait until it is healthy, stop Puma and Sidekiq, restore, restart:

   ```sh
   docker compose up -d
   until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gitlab)")" = healthy ]; do sleep 15; done
   docker compose exec -T gitlab chown git:git "/var/opt/gitlab/backups/${stamp}_gitlab_backup.tar"
   docker compose exec -T gitlab gitlab-ctl stop puma
   docker compose exec -T gitlab gitlab-ctl stop sidekiq
   docker compose exec -T gitlab gitlab-backup restore BACKUP="$stamp" GITLAB_ASSUME_YES=1 </dev/null
   docker compose restart gitlab
   until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gitlab)")" = healthy ]; do sleep 15; done
   docker compose exec -T gitlab gitlab-rake gitlab:check SANITIZE=true
   ```

   On 2026-11-21 these commands ran as written into a second instance (another compose project name, other host ports, the same image) from the NAS copy of the first backup. The restore took about two minutes, the instance was healthy again after the restart, and the restored database held the ten projects, the settings (sign-up off, private by default, metrics on) and the deploy key; clones of three projects from it had the `HEAD` they had when the backup ran; `gitlab:check` listed no problem. GitLab prints a warning that `gitlab.rb` and `gitlab-secrets.json` are not in the backup tar: that is why step 1 restores them from the config archive first.

To get one project back without a full restore, take its repository out of the backup tar with `backup/restore-project.sh`. GitLab stores each repository as a git bundle named after the SHA-256 of the project id; the script reads the id from the database dump in the same tar, extracts the bundle and clones it:

```sh
nas "$SUDO cat $NAS_DIR/backups/${stamp}_gitlab_backup.tar" > "${stamp}_gitlab_backup.tar"
sh backup/restore-project.sh "${stamp}_gitlab_backup.tar" house/opskit ./opskit
```

On 2026-11-21 the first backup was pulled back from the NAS and two projects were rebuilt this way (the vault, about 270 MB, in 5 seconds); `HEAD` of each equalled the `HEAD` that had been pushed, and `git fsck` was clean.

## GitHub mirror

GitLab CE has no pull mirroring (that is a paid feature), so `mirror/github-mirror.py` does it once a day. If GitHub is down, degraded or gone, the code, the history and the audit trail are in GitLab already.

For every repository of the listed GitHub owners (users and organisations) the job:

1. keeps a bare mirror on disk (`git clone --mirror`, then `remote update --prune`; all branches and tags, forks and archived repositories included);
2. pushes branches and tags to a private GitLab project `<group>/<owner>/<repo>` (forced, with `--prune`, so the copy follows rewrites and deletions of branches; the project's default branch follows GitHub's);
3. with a GitHub token for the owner, exports issues, pull requests, issue comments, review comments, reviews and releases as JSON into the GitLab project `<group>/metadata` (`<owner>/<repo>/*.json`), one commit per run that changed anything.

Everything ends up in GitLab, so the nightly GitLab backup covers it. The run is a systemd service with a transient user, tokens as systemd credentials, and a timer at 03:30, after the backup. A repository deleted on GitHub stays in GitLab. `/var/lib/github-mirror/status.json` holds the result of the last run per repository and `LAST_OK` the time of the last run without a failure.

### Install

On the GitLab machine, as a user with sudo, after the stack is running:

```sh
sh scripts/create-api-token.sh 1
bash mirror/setup-gitlab.sh your-org your-user          # group, subgroups, metadata project, group token
sudo install -m 600 secrets/github_mirror_gitlab_token /etc/credstore/github-mirror.gitlab_token && rm secrets/github_mirror_gitlab_token
sh scripts/revoke-api-token.sh
sudo install -d -m 755 /etc/github-mirror
sudo install -m 644 mirror/mirror.env.example /etc/github-mirror/mirror.env      # then edit OWNERS
sudo install -m 755 mirror/github-mirror.py /usr/local/sbin/github-mirror
sudo install -m 644 mirror/github-mirror.service mirror/github-mirror.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start github-mirror.service && sudo journalctl -u github-mirror.service -n 40 -o cat
sudo systemctl enable --now github-mirror.timer
```

Without any GitHub token the job mirrors the public repositories of each owner and exports no metadata. For private repositories and for the metadata, give each owner a **read-only fine-grained token**: GitHub, Settings, Developer settings, Fine-grained personal access tokens; resource owner the user or organisation; all repositories; repository permissions Contents, Issues and Pull requests set to read-only (Metadata is read-only by itself); the longest expiry you will keep up with. An organisation may have to allow fine-grained tokens and approve the request first. A token belongs to one owner and works only for that owner's repositories, so a user and an organisation need one each. Put each one in place without printing it, from the clipboard:

```sh
pbpaste | ssh <machine> 'sudo install -m 600 /dev/stdin /etc/credstore/github-mirror.token.<owner>'
```

The next run picks it up; no restart and no config change. The job logs the expiry date of each GitHub token and of its own GitLab token, and prints `RENEW SOON` for the GitLab one 30 days before. Renew the GitLab token with `mirror/setup-gitlab.sh --renew <owners>` and the same `install` as above.

### What is not in the copy

Wikis; Actions workflows' secrets and variables; rulesets, environments and organisation settings; Pages sites; Git LFS objects (the copy holds the pointer files; the mirror projects have LFS switched off, because GitLab refuses a push whose LFS objects it does not hold); binary release assets and issue attachments (the JSON names them); pull request refs (`refs/pull/*` are fetched into the bare mirror on disk but not pushed to GitLab). Issues and pull requests are a read-only record in JSON, not importable projects.

### Use the copy

Clone from `<group>/<owner>/<repo>` like any GitLab project. To read an issue thread, open `<owner>/<repo>/issues.json` and `issue_comments.json` in the metadata project (`jq` works on them). The copy is private and read-only by convention; a push to it is overwritten by the next run.

## Repository settings

`.github/rulesets/main.json` is the ruleset of the `main` branch, the same shape as in `site-infra`: no deletion, no force push, one approving review from the code owner, a fresh approval after the last push, resolved review threads, and the two checks of `.github/workflows/check.yml` must pass. Apply it once with `gh api -X POST repos/<owner>/gitlab-home/rulesets --input .github/rulesets/main.json`.

## Not done

- **Single sign-on.** Accounts are local. GitLab can use an OIDC provider; not set up.
- **Alerting on a stale backup**, see "Watch it".
- **Off-site copy.** The NAS is a second disk in the same building, not a disaster recovery plan.
- **Encryption at rest.** The machine's disk is not encrypted; the repositories and `gitlab-secrets.json` are readable to anyone with the disk.
- **Runners.** No CI runner is registered.
- **GitHub wikis, secrets and settings** are not mirrored (see "What is not in the copy").
- **A scrape job** for `/-/metrics`.

## License

MIT, see `LICENSE`.
