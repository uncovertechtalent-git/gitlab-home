#!/bin/sh
# Create ./secrets with the initial password of the root account (32 random
# characters, file mode 600, directory mode 700). An existing file is kept, so
# running this again is safe. Nothing is printed except the file names.
#
# GitLab reads the file once, when it creates its database. Changing the file
# later does not change the password.
set -eu
cd "$(dirname "$0")/.."

umask 077
mkdir -p secrets
chmod 700 secrets

for name in root_password; do
  file="secrets/$name"
  if [ -e "$file" ]; then
    echo "kept    $file"
    continue
  fi
  # Letters and digits only: no quoting problems in any config file.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 >"$file"
  chmod 600 "$file"
  echo "created $file"
done
