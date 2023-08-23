#!/bin/bash

set -xeuo pipefail

cd /root/markinim

# docker stop markinimbot || true
if bash tools/backup_script.sh; then
    echo "Backup completed"
else
    echo "Backup failed"
fi
# docker restart markinimbot
