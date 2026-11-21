#!/bin/bash
# Nightly GitLab backup to a NAS over ssh. Runs as root (the data directory
# belongs to the container's users). Settings come from
# /etc/gitlab-home/backup.env (see backup/backup.env.example).
#
# One run does, in this order:
#   1. gitlab-backup create inside the container: the database, all
#      repositories, uploads and the other data GitLab itself knows about, in
#      one tar file named <stamp>_gitlab_backup.tar (STRATEGY=copy, so
#      repositories are copied before they are archived and a push during the
#      run cannot tear the archive)
#   2. a config archive: gitlab.rb, gitlab-secrets.json, the ssh host keys,
#      the compose file and .env. gitlab-secrets.json is not in the backup
#      tar and a restore does not work without it.
#   3. both go to the NAS over ssh, each checked by size
#   4. publish: write LAST_OK, drop old backups on the NAS and on this machine
#
# On the NAS, under NAS_DIR:
#   backups/<stamp>_gitlab_backup.tar
#   config/config-<stamp>.tar
#   LAST_OK                          stamp of the last run that finished
# A <stamp> is YYYY-MM-DD_HHMMSS. Files still being written end in .partial.
set -euo pipefail
umask 077

CONF="${GITLAB_BACKUP_ENV:-/etc/gitlab-home/backup.env}"
# shellcheck disable=SC1090
. "$CONF"

: "${STACK_DIR:?}" "${NAS_TARGET:?}" "${NAS_DIR:?}" "${SSH_KEY:?}"
# NAS_DIR goes into single-quoted words of remote commands; a quote in it would end them.
case "$NAS_DIR" in *\'*) echo "NAS_DIR must not contain a single quote" >&2; exit 64 ;; esac
KEEP="${KEEP:-28}"                  # newest backups and config archives to keep on the NAS
KEEP_LOCAL="${KEEP_LOCAL:-2}"       # newest backup tars to keep on this machine
KNOWN_HOSTS="${KNOWN_HOSTS:-/root/.ssh/known_hosts}"
# Command put in front of the privileged commands on the NAS. Default sudo; set
# NAS_SUDO= (empty) when NAS_TARGET is a user that owns NAS_DIR and needs none.
SUDO="${NAS_SUDO-sudo}"
if [ "$KEEP" -lt 1 ] || [ "$KEEP_LOCAL" -lt 1 ]; then echo "KEEP and KEEP_LOCAL must be at least 1" >&2; exit 64; fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
STAMP_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}'
LOCAL_DIR="$STACK_DIR/data/backups"
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes
  -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
log() { echo "$(date '+%F %T') $*"; }
nas() { "${SSH[@]}" -n "$NAS_TARGET" "$@"; }            # no stdin: safe inside loops
nas_in() { "${SSH[@]}" "$NAS_TARGET" "$@"; }             # passes stdin through
compose() { docker compose --project-directory "$STACK_DIR" "$@"; }

# One run at a time.
exec 9>/run/lock/gitlab-backup.lock
flock -n 9 || { log "another backup is running, exiting"; exit 1; }

WORK=""
finish() {
  rc=$?
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ "$rc" -eq 0 ] || log "FAILED (exit $rc)"
}
trap finish EXIT
WORK="$(mktemp -d)"

# upload <local file> <remote path> : write to <remote path>.partial, compare
# the size with the local file, then rename into place.
upload() {
  local src=$1 rpath=$2 want got
  want="$(wc -c <"$src")"
  [ "$want" -gt 1000 ] || { log "$src is too small ($want bytes), aborting"; return 1; }
  nas_in "$SUDO tee -- '$rpath.partial' >/dev/null" <"$src"
  got="$(nas "$SUDO wc -c -- '$rpath.partial'" | awk '{print $1}')"
  if [ "$want" != "$got" ]; then
    log "size mismatch for $rpath: local $want, NAS has $got"
    return 1
  fi
  nas "$SUDO mv '$rpath.partial' '$rpath'"
}

log "start $STAMP"
[ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q gitlab)")" = healthy ] ||
  { log "the gitlab container is not healthy, not backing up"; exit 1; }
nas "$SUDO install -d -m 700 '$NAS_DIR' '$NAS_DIR/backups' '$NAS_DIR/config'"

log "gitlab-backup create"
compose exec -T gitlab gitlab-backup create STRATEGY=copy CRON=1 BACKUP="$STAMP" </dev/null
ARCHIVE="$LOCAL_DIR/${STAMP}_gitlab_backup.tar"
[ -s "$ARCHIVE" ] || { log "expected $ARCHIVE after gitlab-backup, it is not there"; exit 1; }
tar -tf "$ARCHIVE" >"$WORK/listing"                       # a torn or truncated tar fails here
grep -q '^db/database.sql.gz$' "$WORK/listing" || { log "the backup tar holds no database dump"; exit 1; }

log "config archive"
# The ssh host keys sit in config/: a restored server keeps its identity, so
# clients' known_hosts entries stay valid. secrets/ is left out on purpose: the
# root password file only seeds an empty database.
tar --numeric-owner -C "$STACK_DIR" -cf "$WORK/config.tar" config .env docker-compose.yml

log "upload"
upload "$WORK/config.tar" "$NAS_DIR/config/config-$STAMP.tar"
upload "$ARCHIVE" "$NAS_DIR/backups/${STAMP}_gitlab_backup.tar"

log "publish"
echo "$STAMP" | nas_in "$SUDO tee -- '$NAS_DIR/LAST_OK' >/dev/null"

# Prune on the NAS: list the names, keep the newest, delete the rest by exact
# name (names must match the stamp pattern, nothing else is touched).
prune() { # <dir> <name regex> <keep>
  nas "$SUDO ls -1 '$NAS_DIR/$1'" | { grep -E "$2" || true; } | sort | head -n "-$3" |
    while read -r name; do nas "$SUDO rm -f -- '$NAS_DIR/$1/$name'"; log "removed $1/$name"; done
}
prune backups "^${STAMP_RE}_gitlab_backup\.tar\$" "$KEEP"
prune config "^config-${STAMP_RE}\.tar\$" "$KEEP"

# Prune here: the tars of earlier nights are on the NAS now.
find "$LOCAL_DIR" -maxdepth 1 -type f -name '*_gitlab_backup.tar' | sort | head -n "-$KEEP_LOCAL" |
  while read -r f; do rm -f -- "$f"; log "removed local $(basename "$f")"; done

# Upload leftovers of runs that failed half way.
nas "$SUDO find '$NAS_DIR' -name '*.partial' -mmin +1440 -exec rm -f {} +"

log "done $STAMP"
