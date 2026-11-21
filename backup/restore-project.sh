#!/bin/bash
# Get one project's repository out of a GitLab backup tar, without a running
# GitLab and without restoring anything else. Reads the project id from the
# database dump inside the tar, finds the repository bundle GitLab stored for
# that id and clones it into a new folder.
#   usage: restore-project.sh <backup tar> <group/project> <new folder>
# The backup tar is the file from the NAS (<stamp>_gitlab_backup.tar); see the
# README for how to fetch it. Needs tar, gzip, python3 and git. Wikis are in the
# same tar next to the repository (<hash>.wiki.git) and are not restored here.
set -euo pipefail

tarfile="${1:?usage: restore-project.sh <backup tar> <group/project> <new folder>}"
project="${2:?usage: restore-project.sh <backup tar> <group/project> <new folder>}"
target="${3:?usage: restore-project.sh <backup tar> <group/project> <new folder>}"
[ -r "$tarfile" ] || { echo "cannot read $tarfile" >&2; exit 1; }
[ ! -e "$target" ] || { echo "$target exists already" >&2; exit 1; }
case "$project" in */*) ;; *) echo "give the project as group/project" >&2; exit 64 ;; esac

backup_id="$(tar -xOf "$tarfile" backup_information.yml | sed -n 's/^:backup_id: *//p')"
[ -n "$backup_id" ] || { echo "no backup_id in $tarfile" >&2; exit 1; }

# Project id: the namespace of the group (no parent) and the project path in
# the dump of the database. Only the two tables are read.
id="$(tar -xOf "$tarfile" db/database.sql.gz | gunzip | python3 -c '
import sys
group, name = sys.argv[1].split("/", 1)
tables = {}
cur = None
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if cur is None:
        if line.startswith("COPY public.namespaces ") or line.startswith("COPY public.projects "):
            tname = line.split()[1].split(".", 1)[1]
            cols = line[line.index("(") + 1:line.index(")")].split(", ")
            cur = (tname, cols)
            tables.setdefault(tname, [])
    elif line == "\\.":
        cur = None
    else:
        tname, cols = cur
        tables[tname].append(dict(zip(cols, line.split("\t"))))
ns = [n for n in tables["namespaces"] if n["path"] == group and n["parent_id"] == "\\N"]
if len(ns) != 1:
    sys.exit("namespace %s not found in the dump" % group)
pr = [p for p in tables["projects"] if p["path"] == name and p["namespace_id"] == ns[0]["id"]]
if len(pr) != 1:
    sys.exit("project %s not found in the dump" % sys.argv[1])
print(pr[0]["id"])
' "$project")"

hash="$(printf '%s' "$id" | sha256sum | awk '{print $1}')"
dir="repositories/default/@hashed/${hash:0:2}/${hash:2:2}/${hash}.git/${backup_id}"
echo "project $project has id $id; bundle in the tar: $dir/001.bundle"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xf "$tarfile" -C "$work" "$dir/001.bundle" "$dir/001.refs"
git clone -q "$work/$dir/001.bundle" "$target"
echo "restored $project into $target: HEAD $(git -C "$target" rev-parse HEAD), $(git -C "$target" branch -r | grep -vc HEAD) branches"
