#!/bin/bash

set -xeuo pipefail

echo "Modify this script before running it!"
exit 1  # Remove this line after modifying the script

root_dir="/root/markinim"
backup_directory="$root_dir/backup"
backup_filename="markov_backup.db"

# If you want to send a message to your telegram bot when
# the backup is completed, set the TELEGRAM_ID variable
# to your telegram user id.
TELEGRAM_ID=

cd "$root_dir"
mkdir -p "$backup_directory"

while true; do
    # Clean redundant data
    python3 tools/cleaner.py

    sqlite3 "$root_dir/markov.db" ".backup '$backup_directory/$backup_filename'"

    if [ -n "$TELEGRAM_ID" ]; then
        source "$root_dir/.env" || true
        # if BOT_TOKEN env var exists
        if [ -n "$BOT_TOKEN" ]; then
            # curl telegram botapi
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=$TELEGRAM_ID" -d "text=Backup started at $(date)"
        fi
    fi

    # syncthing will sync the backup in background
    sleep 4h
done
