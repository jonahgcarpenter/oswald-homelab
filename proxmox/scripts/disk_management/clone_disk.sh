#!/bin/bash

# Disk Clone
# Clones one mounted partition to another with rsync and emails the result.
# Usage: sudo /path/to/script <source> <destination>
# Example: nohup sudo /root/clone_disk.sh /dev/sdd1 /dev/sdc1 &

# Configuration
SOURCE_MNT="/mnt/source_clone"
DEST_MNT="/mnt/dest_clone"
EMAIL_RECIPIENT="your-email@gmail.com"
LOG_FILE="/var/log/clone_disk.log"
exec &> "$LOG_FILE"

# Main
if [ "$#" -ne 2 ]; then
  echo "Error: Incorrect number of arguments supplied."
  echo "Usage: $0 <source_partition> <destination_partition>"
  echo "Example: $0 /dev/sdd1 /dev/sdc1"
  exit 1
fi

SOURCE_DEV="$1"
DEST_DEV="$2"

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root. Please use sudo."
   exit 1
fi

# Cleanup
function cleanup {
  echo "---"
  echo "Running cleanup: Unmounting drives..."
  umount "$SOURCE_MNT" &>/dev/null
  umount "$DEST_MNT" &>/dev/null
  echo "Cleanup complete."
}
trap cleanup EXIT

echo "Starting disk clone process from $SOURCE_DEV to $DEST_DEV..."

mkdir -p "$SOURCE_MNT" "$DEST_MNT"

echo "Mounting $SOURCE_DEV to $SOURCE_MNT..."
if ! mount "$SOURCE_DEV" "$SOURCE_MNT"; then
    echo "Error: Failed to mount source drive $SOURCE_DEV." >&2
    exit 1
fi

echo "Mounting $DEST_DEV to $DEST_MNT..."
if ! mount "$DEST_DEV" "$DEST_MNT"; then
    echo "Error: Failed to mount destination drive $DEST_DEV." >&2
    exit 1
fi

echo "Starting rsync... Log will be at $LOG_FILE"
rsync_command="rsync -ah --info=progress2 --exclude='/lost+found' '$SOURCE_MNT/' '$DEST_MNT/'"

if eval "$rsync_command"; then
  echo "Rsync completed successfully."
  SUBJECT="✅ Success: Disk Clone from $SOURCE_DEV to $DEST_DEV Complete"
  BODY="The rsync clone process finished without errors."
else
  echo "Rsync failed. Check $LOG_FILE for details."
  SUBJECT="❌ Error: Disk Clone from $SOURCE_DEV to $DEST_DEV Failed"
  BODY="The rsync clone process from $SOURCE_DEV to $DEST_DEV failed. See the attached log for details.\n\n$(cat $LOG_FILE)"
fi

# Send notification
echo "Sending notification email to $EMAIL_RECIPIENT..."
echo -e "$BODY" | mail -s "$SUBJECT" "$EMAIL_RECIPIENT"

echo "---"
echo "Script finished."

exit 0
