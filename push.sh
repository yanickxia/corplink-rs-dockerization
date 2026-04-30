#!/usr/bin/env bash
# One-shot helper to push this repo to GitHub.
#
# Usage (pick ONE):
#
#   # 1) with a Personal Access Token (needs: repo + write:packages):
#   GITHUB_TOKEN=ghp_xxx GITHUB_USER=yanickxia ./push.sh
#
#   # 2) with SSH (after adding your key to GitHub):
#   ./push.sh --ssh

set -euo pipefail

REMOTE_HTTPS="https://github.com/yanickxia/corplink-rs-dockerization.git"
REMOTE_SSH="git@github.com:yanickxia/corplink-rs-dockerization.git"

cd "$(dirname "$0")"

if [ "${1:-}" = "--ssh" ]; then
    git remote set-url origin "$REMOTE_SSH"
    git push -u origin master
    exit 0
fi

: "${GITHUB_TOKEN:?set GITHUB_TOKEN env var or pass --ssh}"
: "${GITHUB_USER:=yanickxia}"

git remote set-url origin "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/yanickxia/corplink-rs-dockerization.git"
git push -u origin master
# Don't leave the token in the remote URL
git remote set-url origin "$REMOTE_HTTPS"
echo "Pushed. Remote reset to $REMOTE_HTTPS"
