#!/bin/bash

# Frigate LXC Wait
# Starts the Frigate container after its required mount point is available.
#
# This avoids SMB mount timing errors by waiting for the TrueNAS-backed mount
# before starting the Frigate LXC, instead of relying on a fixed startup delay.
#
# Systemd service setup:
#   sudo nano /etc/systemd/system/frigate-lxc-wait.service
#
# Service contents:
#   [Unit]
#   Description=Wait for SMB Mount and Start Frigate LXC
#   After=network-online.target local-fs.target remote-fs.target
#
#   [Service]
#   Type=simple
#   User=root
#   ExecStart=/path/to/frigate_lxc_wait.sh
#   Restart=on-failure
#   RestartSec=5
#
#   [Install]
#   WantedBy=multi-user.target
#
# Frigate backup cron setup:
#   sudo crontab -e
#
# Cron entry:
#   0 1 * * * /path/to/frigate_backup.sh

# Configuration
CT_ID="105"
REQUIRED_MOUNT="/mnt/frigate"
DELAY_SECONDS=120

# Main
echo "--- Starting LXC startup wait script for CT ${CT_ID} ---"

if pct status ${CT_ID} >/dev/null 2>&1 && pct status ${CT_ID} | grep -q "status: running"; then
    echo "Container ${CT_ID} is already running. Exiting."
    exit 0
fi

echo "Waiting indefinitely for mount point '${REQUIRED_MOUNT}' to become available..."

while true; do
    if mountpoint -q "${REQUIRED_MOUNT}"; then
        echo "Success! Mount point '${REQUIRED_MOUNT}' is active."
        echo "Proceeding to start container ${CT_ID}..."

        if pct start ${CT_ID}; then
            echo "Container ${CT_ID} started successfully. Script will now terminate."
            exit 0
        else
            echo "Error: Failed to start container ${CT_ID} even though mount point was ready."
            exit 1
        fi
    fi

    sleep ${DELAY_SECONDS}
done
