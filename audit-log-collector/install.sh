#!/bin/bash
CRON_JOB="9-59/10 * * * * $(pwd)/venv/bin/python3 $(pwd)/main.py >> $(pwd)/cron.log 2>&1 #automox-audit-log-collector"
CRONTAB_CONTENTS=$(crontab -l)

# Check if the cron job already exists
if ! echo "$CRONTAB_CONTENTS" | grep -q "#automox-audit-log-collector"; then
    # Add the cron job if it doesn't exist
    (echo "$CRONTAB_CONTENTS"; echo "$CRON_JOB") | crontab -
    echo "Cron job added successfully!"
    crontab -l
else
    echo "Cron job already exists!" No changes made.
fi