#!/bin/bash
set -euo pipefail

# Resolve paths relative to this script, not the caller's CWD, so it works no
# matter which directory it is invoked from (e.g. `sudo bash ./proxy/setup_nginx.sh`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo apt update && sudo apt install nginx-full git vim -y

cp "$SCRIPT_DIR/update.sh" ~/
cp "$SCRIPT_DIR/nginx.conf" /etc/nginx/nginx.conf

mkdir -p /etc/nginx/streams-enabled
touch /etc/nginx/streams-enabled/proxy.conf
ln -sf /etc/nginx/streams-enabled/proxy.conf ~/proxy.conf

# Catch a broken/incomplete install immediately instead of failing silently.
nginx -t
