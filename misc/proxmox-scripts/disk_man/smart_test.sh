#!/bin/bash

# --- Configuration ---
LOG_FILE="/var/log/smart_test.log"
EMAIL_RECIPIENT="root@pam"
PROXMOX_MAILER="/usr/bin/proxmox-mail-forward"
SCRIPT_NAME="SMART_Auto_Test"

# --- Helper Functions ---
log_message() {
    local message="$1"
    # Print to stdout and append to the single log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# --- Initialization ---
log_message "======= $SCRIPT_NAME Script Started ======="
declare -A DRIVE_FINISH_TIMES
MAX_WAIT_TIME=0
SUCCESSFUL_TESTS=0

# --- Find Drives ---
log_message "Scanning /dev/disk/by-id/ for ATA drives..."
DRIVES=$(find /dev/disk/by-id/ -name "ata-*" ! -name "*-part*")

if [[ -z "$DRIVES" ]]; then
    log_message "ERROR: No ATA drives found. Exiting."
    exit 1
fi

# --- Start Tests ---
for drive in $DRIVES; do
    drive_name=$(basename "$drive")
    log_message "Starting long test on: $drive_name"
    
    OUTPUT=$(smartctl -t long "$drive" 2>&1)
    
    # Extract the exact completion string
    COMPLETION_STR=$(echo "$OUTPUT" | grep "Test will complete after" | sed 's/Test will complete after //')

    if [[ -n "$COMPLETION_STR" ]]; then
        # Convert to Unix timestamp
        COMPLETION_EPOCH=$(date -d "$COMPLETION_STR" +%s)
        DRIVE_FINISH_TIMES["$drive"]=$COMPLETION_EPOCH
        ((SUCCESSFUL_TESTS++))
        
        log_message " -> Expected completion: $COMPLETION_STR"
        
        # Track the maximum wait time
        if [[ $COMPLETION_EPOCH -gt $MAX_WAIT_TIME ]]; then
            MAX_WAIT_TIME=$COMPLETION_EPOCH
        fi
    else
        log_message " -> Failed to start test or parse completion time for $drive_name. Skipping."
    fi
done

if [[ $SUCCESSFUL_TESTS -eq 0 ]]; then
    log_message "ERROR: No valid tests were initiated. Exiting."
    exit 1
fi

# --- Wait Loop ---
log_message "Waiting for all tests to finish. Maximum wait time: $(date -d @$MAX_WAIT_TIME)"
while true; do
    CURRENT_TIME=$(date +%s)
    
    if [[ $CURRENT_TIME -ge $MAX_WAIT_TIME ]]; then
        break
    fi
    
    REMAINING=$((MAX_WAIT_TIME - CURRENT_TIME))
    printf "\rWaiting for tests to finish... %02d:%02d:%02d remaining." $((REMAINING/3600)) $(( (REMAINING%3600)/60 )) $((REMAINING%60))
    
    sleep 60
done

echo "" # Clear the printf line
log_message "All tests reached completion time. Gathering results..."

# --- Construct and Send Email ---
log_message "Generating and sending email notification to $EMAIL_RECIPIENT..."
EMAIL_SUBJECT="[$SCRIPT_NAME]: S.M.A.R.T. Tests Completed"

# Group the output block to stream directly into the mailer without using temp files
{
    echo "Subject: $EMAIL_SUBJECT"
    echo ""
    echo "All scheduled S.M.A.R.T. long tests have completed successfully."
    echo "Below are the full diagnostic logs for each tested drive."
    echo ""
    
    for drive in "${!DRIVE_FINISH_TIMES[@]}"; do
        drive_name=$(basename "$drive")
        echo "================================================================================"
        echo "RESULTS FOR: $drive_name"
        echo "================================================================================"
        smartctl -a "$drive"
        echo ""
        echo ""
    done
    
    echo "================================================================================"
    echo "See the log file for script execution details: $LOG_FILE"
} | "$PROXMOX_MAILER" "$EMAIL_RECIPIENT"

if [ $? -eq 0 ]; then
    log_message "Email notification sent successfully."
else
    log_message "ERROR: Failed to send email notification."
    exit 1
fi

log_message "======= $SCRIPT_NAME Script Finished ======="
echo "" >> "$LOG_FILE"

exit 0
