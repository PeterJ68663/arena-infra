#!/bin/bash
set -euo pipefail
python3 ~/arena-infra/proxy/nginx_pods.py > ~/proxy.conf
nginx -t
systemctl reload nginx
