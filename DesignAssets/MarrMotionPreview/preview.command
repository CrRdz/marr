#!/bin/zsh
set -eu
cd "$(dirname "$0")"
if [[ -x /tmp/marr-rive-tools/bin/rive ]]; then
  export RIVE_HOME=/tmp/marr-rive-tools
  exec /tmp/marr-rive-tools/bin/rive . --fit=contain
elif command -v rive >/dev/null 2>&1; then
  exec rive . --fit=contain
elif [[ -x "$HOME/.rive/bin/rive" ]]; then
  exec "$HOME/.rive/bin/rive" . --fit=contain
else
  print 'Install the official Rive CLI from https://rive.app/cli, then reopen this file.'
  read -r '?Press Return to close.'
fi
