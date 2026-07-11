#!/bin/bash

# Frigate Custom Backup Script
# Mounts a drive, syncs Frigate recordings, unmounts, and alerts on failure/disk usage.

# Configuration
DEVICE="/dev/sdb1"                        # Backup drive partition
MOUNT_POINT="/mnt/frigate_backups"        # Mount destination
FRIGATE_SOURCE_DIR="/mnt/frigate/recordings/" # Source (requires trailing slash)
RSYNC_DEST_SUBDIR="recordings"            # Subdirectory in mount point
CAMERAS_TO_INCLUDE=("living_room" "hallway" "kitchen")

LOG_FILE="/var/log/frigate_custom_backup.log"
SCRIPT_NAME="Frigate Backup"
EMAIL_RECIPIENT="your-email@gmail.com"                # Proxmox admin recipient
DISK_THRESHOLD=80                         # Alert if disk usage % exceeds this

# Helpers
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
}

# Main
if sudo truncate -s 0 "$LOG_FILE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Log file truncated." | sudo tee "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Failed to truncate $LOG_FILE." | sudo tee -a "$LOG_FILE" >&2
fi

log_message "======= Starting $SCRIPT_NAME ======="

# Prepare mount point
if [ ! -d "$MOUNT_POINT" ]; then
    log_message "Mount point $MOUNT_POINT missing. Creating..."
    if ! sudo mkdir -p "$MOUNT_POINT"; then
        log_message "ERROR: Failed to create $MOUNT_POINT."
        {
            echo "Failed to create $MOUNT_POINT."
            echo ""
            echo "Check $LOG_FILE."
        } | mail -s "[$SCRIPT_NAME] CRITICAL FAILURE" "$EMAIL_RECIPIENT"
        exit 1
    fi
fi

# Mount backup drive
IS_CORRECTLY_MOUNTED=false
CRITICAL_ERROR_MESSAGE=""

if mountpoint -q "$MOUNT_POINT"; then
    CURRENTLY_MOUNTED_DEVICE=$(findmnt -n -o SOURCE --target "$MOUNT_POINT")
    if [ "$CURRENTLY_MOUNTED_DEVICE" == "$DEVICE" ]; then
        log_message "$DEVICE already mounted at $MOUNT_POINT."
        IS_CORRECTLY_MOUNTED=true
    else
        CRITICAL_ERROR_MESSAGE="Wrong device mounted at $MOUNT_POINT: $CURRENTLY_MOUNTED_DEVICE. Expected $DEVICE."
    fi
else
    log_message "Attempting to mount $DEVICE..."
    if sudo mount "$DEVICE" "$MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
        log_message "$DEVICE mounted successfully."
        IS_CORRECTLY_MOUNTED=true
    else
        CRITICAL_ERROR_MESSAGE="Failed to mount $DEVICE (Code: $?)."
    fi
fi

if ! $IS_CORRECTLY_MOUNTED; then
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE Exiting."
    {
        echo "$CRITICAL_ERROR_MESSAGE"
        echo ""
        echo "Check $LOG_FILE."
    } | mail -s "[$SCRIPT_NAME] CRITICAL FAILURE" "$EMAIL_RECIPIENT"
    exit 1
fi

# Prepare rsync destination
FULL_RSYNC_DEST="$MOUNT_POINT/$RSYNC_DEST_SUBDIR"
if ! sudo mkdir -p "$FULL_RSYNC_DEST"; then
    CRITICAL_ERROR_MESSAGE="Failed to create destination $FULL_RSYNC_DEST."
    log_message "ERROR: $CRITICAL_ERROR_MESSAGE"
    {
        echo "$CRITICAL_ERROR_MESSAGE"
        echo ""
        echo "Check $LOG_FILE."
    } | mail -s "[$SCRIPT_NAME] CRITICAL FAILURE" "$EMAIL_RECIPIENT"
    sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
    exit 1
fi

# Configure rsync includes
RSYNC_INCLUDE_OPTS=(--include='*/')
for CAM_NAME in "${CAMERAS_TO_INCLUDE[@]}"; do
    RSYNC_INCLUDE_OPTS+=(--include="*/$CAM_NAME/**")
done

# Run rsync
log_message "Starting rsync to $FULL_RSYNC_DEST..."
sudo rsync -avz --no-owner --no-group \
  "${RSYNC_INCLUDE_OPTS[@]}" \
  --exclude='*' \
  "$FRIGATE_SOURCE_DIR" \
  "$FULL_RSYNC_DEST" >> "$LOG_FILE" 2>&1
RSYNC_STATUS=$?

if [ $RSYNC_STATUS -eq 0 ]; then
    log_message "Rsync successful."
    RSYNC_MESSAGE_DETAIL="Success."
elif [ $RSYNC_STATUS -eq 24 ]; then
    log_message "Rsync warning (Code 24: Vanished source files)."
    RSYNC_MESSAGE_DETAIL="Warning (Code 24)."
else
    log_message "ERROR: Rsync failed (Code $RSYNC_STATUS)."
    RSYNC_MESSAGE_DETAIL="FAILED (Code $RSYNC_STATUS)."
fi

FINAL_EXIT_CODE=0
EMAIL_SUBJECT_STATUS="SUCCESS"

if [ $RSYNC_STATUS -ne 0 ] && [ $RSYNC_STATUS -ne 24 ]; then
    FINAL_EXIT_CODE=$RSYNC_STATUS
    EMAIL_SUBJECT_STATUS="FAILED (Rsync Error)"
fi

# Check disk usage
DISK_USAGE_PERCENT=$(df "$MOUNT_POINT" | tail -n 1 | awk '{print $5}')
DISK_USAGE_NUM=0

if [ -n "$DISK_USAGE_PERCENT" ]; then
    DISK_USAGE_LOG_MESSAGE="Disk usage: $DISK_USAGE_PERCENT."
    log_message "$DISK_USAGE_LOG_MESSAGE"
    DISK_USAGE_NUM=$(echo "$DISK_USAGE_PERCENT" | tr -d '%')
else
    DISK_USAGE_LOG_MESSAGE="Could not determine disk usage."
    log_message "WARNING: $DISK_USAGE_LOG_MESSAGE"
fi

# Unmount backup drive
UMOUNT_MESSAGE_DETAIL=""
log_message "Unmounting $MOUNT_POINT..."
sudo umount "$MOUNT_POINT" >> "$LOG_FILE" 2>&1
UMOUNT_STATUS=$?
if [ $UMOUNT_STATUS -ne 0 ]; then
    log_message "ERROR: Failed to unmount $MOUNT_POINT (Code: $UMOUNT_STATUS)."
    UMOUNT_MESSAGE_DETAIL="Unmount failed (Code: $UMOUNT_STATUS)."
    if [ "$EMAIL_SUBJECT_STATUS" == "SUCCESS" ]; then
        EMAIL_SUBJECT_STATUS="COMPLETED WITH UNMOUNT ISSUE"
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=100; fi
    fi
else
    log_message "$MOUNT_POINT unmounted."
    UMOUNT_MESSAGE_DETAIL="Unmounted successfully."
fi

# Send notification
SEND_EMAIL=false

if [ "$FINAL_EXIT_CODE" -ne 0 ]; then
    SEND_EMAIL=true
fi

if [[ "$DISK_USAGE_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_USAGE_NUM" -ge "$DISK_THRESHOLD" ]; then
    SEND_EMAIL=true
    EMAIL_SUBJECT_STATUS="WARNING: Disk Usage at ${DISK_USAGE_PERCENT}" 
fi

if $SEND_EMAIL; then
    log_message "Preparing email notification..."
    EMAIL_SUBJECT="[$SCRIPT_NAME]: $EMAIL_SUBJECT_STATUS"

    {
        echo "Script execution finished."
        echo "Rsync Status: $RSYNC_MESSAGE_DETAIL"
        [ -n "$DISK_USAGE_LOG_MESSAGE" ] && echo "$DISK_USAGE_LOG_MESSAGE"
        [ -n "$UMOUNT_MESSAGE_DETAIL" ] && echo "Unmount Status: $UMOUNT_MESSAGE_DETAIL"
        echo ""
        echo "See the log file for full details: $LOG_FILE"
    } | mail -s "$EMAIL_SUBJECT" "$EMAIL_RECIPIENT"

    MAIL_STATUS=$?
    if [ $MAIL_STATUS -eq 0 ]; then
        log_message "Email sent successfully."
    else
        log_message "ERROR: Failed to send email (Code: $MAIL_STATUS)."
        if [ $FINAL_EXIT_CODE -eq 0 ]; then FINAL_EXIT_CODE=102; fi
    fi
else
    log_message "Success. Disk usage below ${DISK_THRESHOLD}%. Skipping email."
fi

log_message "======= Finished ======="
echo "" >> "$LOG_FILE"

exit $FINAL_EXIT_CODE
