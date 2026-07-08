#!/bin/bash

# --- Configuration ---
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG_FILE="/var/log/smart_test.log"
EMAIL_RECIPIENT="your-email@gmail.com"
SCRIPT_NAME="SMART_Auto_Test"
SMARTCTL="/usr/sbin/smartctl"

# --- Helper Functions ---
log_message() {
    local message="$1"
    # Print to stdout and append to the single log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

extract_smart_field() {
    local output="$1"
    local field="$2"

    printf '%s\n' "$output" | awk -F: -v field="$field" '$1 == field { sub(/^[[:space:]]+/, "", $2); print $2; exit }'
}

extract_smart_attribute_raw() {
    local output="$1"
    local attribute="$2"

    printf '%s\n' "$output" | awk -v attribute="$attribute" '$2 == attribute { print $NF; exit }'
}

extract_long_test_status() {
    local output="$1"

    printf '%s\n' "$output" | awk '/Extended offline/ { sub(/^[[:space:]]*#[[:space:]]*[0-9]+[[:space:]]+Extended offline[[:space:]]+/, ""); sub(/[[:space:]]+[0-9]+%.*$/, ""); print; exit }'
}

print_smart_summary() {
    local drive_name="$1"
    local smart_output="$2"
    local model serial capacity health long_test temperature reallocated pending uncorrectable crc_errors

    model=$(extract_smart_field "$smart_output" "Device Model")
    serial=$(extract_smart_field "$smart_output" "Serial Number")
    capacity=$(extract_smart_field "$smart_output" "User Capacity")
    health=$(extract_smart_field "$smart_output" "SMART overall-health self-assessment test result")
    long_test=$(extract_long_test_status "$smart_output")
    temperature=$(extract_smart_attribute_raw "$smart_output" "Temperature_Celsius")
    reallocated=$(extract_smart_attribute_raw "$smart_output" "Reallocated_Sector_Ct")
    pending=$(extract_smart_attribute_raw "$smart_output" "Current_Pending_Sector")
    uncorrectable=$(extract_smart_attribute_raw "$smart_output" "Offline_Uncorrectable")
    crc_errors=$(extract_smart_attribute_raw "$smart_output" "UDMA_CRC_Error_Count")

    echo "RESULTS FOR: $drive_name"
    echo "Model: ${model:-Unknown}"
    echo "Serial: ${serial:-Unknown}"
    echo "Capacity: ${capacity:-Unknown}"
    echo "Health: ${health:-Unknown}"
    echo "Long test: ${long_test:-Unknown}"
    echo "Temperature: ${temperature:-Unknown} C"
    echo "Reallocated sectors: ${reallocated:-Unknown}"
    echo "Pending sectors: ${pending:-Unknown}"
    echo "Offline uncorrectable: ${uncorrectable:-Unknown}"
    echo "UDMA CRC errors: ${crc_errors:-Unknown}"
}

# --- Initialization ---
log_message "======= $SCRIPT_NAME Script Started ======="

if [[ ! -x "$SMARTCTL" ]]; then
    SMARTCTL=$(command -v smartctl)
fi

if [[ -z "$SMARTCTL" ]]; then
    log_message "ERROR: smartctl was not found. Exiting."
    exit 1
fi

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
    
    OUTPUT=$("$SMARTCTL" -t long "$drive" 2>&1)
    
    # Extract the exact completion string
    COMPLETION_STR=$(echo "$OUTPUT" | grep "Test will complete after" | sed 's/Test will complete after //')

    if [[ -n "$COMPLETION_STR" ]]; then
        # Convert to Unix timestamp
        if ! COMPLETION_EPOCH=$(date -d "$COMPLETION_STR" +%s 2>/dev/null); then
            log_message " -> Failed to parse completion time for $drive_name: $COMPLETION_STR"
            log_message " -> smartctl output:"
            printf '%s\n' "$OUTPUT" | tee -a "$LOG_FILE"
            continue
        fi

        DRIVE_FINISH_TIMES["$drive"]=$COMPLETION_EPOCH
        ((SUCCESSFUL_TESTS++))
        
        log_message " -> Expected completion: $COMPLETION_STR"
        
        # Track the maximum wait time
        if [[ $COMPLETION_EPOCH -gt $MAX_WAIT_TIME ]]; then
            MAX_WAIT_TIME=$COMPLETION_EPOCH
        fi
    else
        log_message " -> Failed to start test or parse completion time for $drive_name. Skipping."
        log_message " -> smartctl output:"
        printf '%s\n' "$OUTPUT" | tee -a "$LOG_FILE"
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
    if [[ -t 1 ]]; then
        printf "\rWaiting for tests to finish... %02d:%02d:%02d remaining." $((REMAINING/3600)) $(( (REMAINING%3600)/60 )) $((REMAINING%60))
    fi
    
    sleep 60
done

echo "" # Clear the printf line
log_message "All tests reached completion time. Gathering results..."

# --- Construct and Send Email ---
log_message "Generating and sending email notification to $EMAIL_RECIPIENT..."
EMAIL_SUBJECT="[$SCRIPT_NAME]: S.M.A.R.T. Tests Completed"

# Group the output block to stream directly into mail without using temp files
{
    echo "All scheduled S.M.A.R.T. long tests have completed successfully."
    echo ""
    
    for drive in "${!DRIVE_FINISH_TIMES[@]}"; do
        drive_name=$(basename "$drive")
        SMART_OUTPUT=$("$SMARTCTL" -a "$drive" 2>&1)

        {
            echo "================================================================================"
            echo "FULL SMART RESULTS FOR: $drive_name"
            echo "================================================================================"
            printf '%s\n' "$SMART_OUTPUT"
            echo ""
            echo ""
        } >> "$LOG_FILE"

        print_smart_summary "$drive_name" "$SMART_OUTPUT"
        echo ""
    done
    
    echo "================================================================================"
    echo "See the log file for full diagnostic output and script execution details: $LOG_FILE"
} | mail -s "$EMAIL_SUBJECT" "$EMAIL_RECIPIENT"

if [ $? -eq 0 ]; then
    log_message "Email notification sent successfully."
else
    log_message "ERROR: Failed to send email notification."
    exit 1
fi

log_message "======= $SCRIPT_NAME Script Finished ======="
echo "" >> "$LOG_FILE"

exit 0
