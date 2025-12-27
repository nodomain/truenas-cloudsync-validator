#!/bin/bash
#
# Validate TrueNAS Cloud Sync encrypted backups using rclone cryptcheck
# Fetches config from TrueNAS REST API and validates against remote storage
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOCK_FILE="/tmp/validate-cloud-sync.lock"
TEMP_RCLONE_CONF=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

cleanup() {
    if [[ -n "$TEMP_RCLONE_CONF" && -f "$TEMP_RCLONE_CONF" ]]; then
        rm -f "$TEMP_RCLONE_CONF"
    fi
}

# Release lock on exit
release_lock() {
    if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
}
trap release_lock EXIT

# Acquire lock (prevents concurrent runs)
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Another instance is already running (PID: $pid)"
            log_info "If this is incorrect, remove $LOCK_FILE"
            exit 1
        else
            log_warn "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Load .env file
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found at $ENV_FILE"
        log_info "Copy .env.example to .env and fill in your credentials"
        exit 1
    fi
    
    set -a
    source "$ENV_FILE"
    set +a
    
    if [[ -z "${TRUENAS_HOST:-}" ]]; then
        log_error "TRUENAS_HOST not set in .env"
        exit 1
    fi
}

# Check dependencies
check_deps() {
    local missing=()
    for cmd in curl jq rclone; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

# Build auth header
get_auth() {
    if [[ -n "${TRUENAS_API_KEY:-}" ]]; then
        echo "Authorization: Bearer $TRUENAS_API_KEY"
    else
        echo "Authorization: Basic $(echo -n "${TRUENAS_USER}:${TRUENAS_PASSWORD}" | base64)"
    fi
}

# API call helper
api_call() {
    local endpoint="$1"
    curl -sk -H "$(get_auth)" "https://${TRUENAS_HOST}/api/v2.0${endpoint}"
}

# List cloud sync tasks
list_tasks() {
    log_info "Fetching cloud sync tasks..."
    echo
    
    local tasks
    tasks=$(api_call "/cloudsync")
    
    if [[ -z "$tasks" || "$tasks" == "[]" ]]; then
        log_error "No cloud sync tasks found"
        exit 1
    fi
    
    echo "Cloud Sync Tasks:"
    echo "================="
    echo "$tasks" | jq -r '.[] | "  \(.id)) \(.description)\n     Local: \(.path)\n     Encrypted: \(.encryption // false)\n"'
}

# Get task details
get_task() {
    local task_id="$1"
    api_call "/cloudsync" | jq ".[] | select(.id == $task_id)"
}

# Get credential details
get_credential() {
    local cred_id="$1"
    api_call "/cloudsync/credentials" | jq ".[] | select(.id == $cred_id)"
}


# Generate rclone config for a cloud sync task
# Sets global: TEMP_RCLONE_CONF, LOCAL_PATH
generate_rclone_config() {
    local task_id="$1"
    
    log_step "Fetching task configuration..."
    
    local task cred_id credential
    task=$(get_task "$task_id")
    
    if [[ -z "$task" || "$task" == "null" ]]; then
        log_error "Task ID $task_id not found"
        exit 1
    fi
    
    # Check if encrypted
    local encrypted
    encrypted=$(echo "$task" | jq -r '.encryption // false')
    if [[ "$encrypted" != "true" ]]; then
        log_warn "Task is not encrypted - use 'rclone check' instead of cryptcheck"
    fi
    
    # Get credential info
    cred_id=$(echo "$task" | jq -r '.credentials.id')
    credential=$(get_credential "$cred_id")
    
    local provider host port user pass
    provider=$(echo "$credential" | jq -r '.provider')
    
    # Extract connection details based on provider
    case "$provider" in
        SFTP)
            host=$(echo "$credential" | jq -r '.attributes.host')
            port=$(echo "$credential" | jq -r '.attributes.port // 22')
            user=$(echo "$credential" | jq -r '.attributes.user')
            pass=$(echo "$credential" | jq -r '.attributes.pass // empty')
            ;;
        *)
            log_error "Provider '$provider' not yet supported in this script"
            log_info "Supported: SFTP (Hetzner Storage Box)"
            exit 1
            ;;
    esac
    
    # Get encryption settings
    local enc_password enc_salt filename_enc
    enc_password=$(echo "$task" | jq -r '.encryption_password // empty')
    enc_salt=$(echo "$task" | jq -r '.encryption_salt // empty')
    filename_enc=$(echo "$task" | jq -r '.filename_encryption // false')
    
    local filename_enc_mode="off"
    [[ "$filename_enc" == "true" ]] && filename_enc_mode="standard"
    
    # Get paths (set global for caller)
    LOCAL_PATH=$(echo "$task" | jq -r '.path')
    local remote_folder
    remote_folder=$(echo "$task" | jq -r '.attributes.folder // ""')
    
    # Create temp rclone config (global for cleanup)
    TEMP_RCLONE_CONF=$(mktemp)
    
    # Obscure passwords for rclone config
    local obscured_pass obscured_enc_pass obscured_salt
    obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "")
    obscured_enc_pass=$(rclone obscure "$enc_password" 2>/dev/null || echo "")
    
    cat > "$TEMP_RCLONE_CONF" << EOF
[remote]
type = sftp
host = $host
port = $port
user = $user
pass = $obscured_pass

[encrypted]
type = crypt
remote = remote:${remote_folder}
filename_encryption = $filename_enc_mode
password = $obscured_enc_pass
EOF

    if [[ -n "$enc_salt" ]]; then
        obscured_salt=$(rclone obscure "$enc_salt" 2>/dev/null || echo "")
        echo "password2 = $obscured_salt" >> "$TEMP_RCLONE_CONF"
    fi
    
    log_info "Generated rclone config for task: $(echo "$task" | jq -r '.description')"
    log_info "Local path: $LOCAL_PATH"
    log_info "Remote: $host:$remote_folder"
}

# Run validation
run_validation() {
    local task_id="$1"
    local mode="${2:-cryptcheck}"
    
    generate_rclone_config "$task_id"
    
    echo
    log_step "Running rclone $mode..."
    echo
    
    case "$mode" in
        cryptcheck)
            # Full bit-perfect verification - downloads and compares checksums
            log_warn "Downloading and verifying all files - this may take a long time!"
            log_info "Local: $LOCAL_PATH"
            log_info "Remote: encrypted (will decrypt and compare MD5)"
            echo
            rclone check "$LOCAL_PATH" encrypted: \
                --config "$TEMP_RCLONE_CONF" \
                --download \
                --checkers 16 \
                --transfers 16 \
                --progress
            
            local rc=$?
            echo
            if [[ $rc -eq 0 ]]; then
                log_info "✓ All files verified bit-perfect!"
            else
                log_error "✗ Verification failed - some files differ or are missing"
            fi
            return $rc
            ;;
        quick)
            # Quick size-only check (not bit-perfect)
            log_warn "Size-only comparison - NOT bit-perfect verification"
            rclone check "$LOCAL_PATH" encrypted: \
                --config "$TEMP_RCLONE_CONF" \
                --size-only \
                --checkers 16 \
                2>&1 | grep -v "No common hash"
            ;;
        list)
            # Just list files to verify access
            log_info "Listing remote encrypted files (decrypted view):"
            rclone ls encrypted: --config "$TEMP_RCLONE_CONF" | head -20
            echo "..."
            ;;
        sample)
            # Download and verify a random sample of files
            log_info "Downloading sample files to verify decryption..."
            local sample_dir
            sample_dir=$(mktemp -d)
            rclone copy encrypted: "$sample_dir" \
                --config "$TEMP_RCLONE_CONF" \
                --max-transfer 50M \
                --transfers 8 \
                -v
            local count
            count=$(find "$sample_dir" -type f | wc -l)
            log_info "Successfully decrypted $count files to $sample_dir"
            rm -rf "$sample_dir"
            ;;
    esac
}

# Get all encrypted task IDs
get_all_task_ids() {
    api_call "/cloudsync" | jq -r '.[] | select(.encryption == true) | .id'
}

# Validate all tasks and collect results
validate_all() {
    local mode="${1:-cryptcheck}"
    local failed_tasks=()
    local passed_tasks=()
    local start_time end_time duration
    
    start_time=$(date +%s)
    
    log_info "Starting validation of all encrypted cloud sync tasks..."
    echo
    
    local task_ids
    task_ids=$(get_all_task_ids)
    
    if [[ -z "$task_ids" ]]; then
        log_error "No encrypted cloud sync tasks found"
        return 1
    fi
    
    local total
    total=$(echo "$task_ids" | wc -l | tr -d ' ')
    local current=0
    
    for task_id in $task_ids; do
        current=$((current + 1))
        local task_name
        task_name=$(get_task "$task_id" | jq -r '.description')
        
        echo
        echo "========================================"
        log_info "[$current/$total] Validating: $task_name (ID: $task_id)"
        echo "========================================"
        
        if run_validation "$task_id" "$mode"; then
            passed_tasks+=("$task_name")
        else
            failed_tasks+=("$task_name")
        fi
        
        # Cleanup between tasks
        cleanup
        TEMP_RCLONE_CONF=""
    done
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Generate report
    echo
    echo "========================================"
    echo "VALIDATION REPORT"
    echo "========================================"
    echo "Duration: $((duration / 3600))h $((duration % 3600 / 60))m $((duration % 60))s"
    echo "Total tasks: $total"
    echo "Passed: ${#passed_tasks[@]}"
    echo "Failed: ${#failed_tasks[@]}"
    echo
    
    if [[ ${#passed_tasks[@]} -gt 0 ]]; then
        echo "✓ Passed:"
        for t in "${passed_tasks[@]}"; do
            echo "  - $t"
        done
    fi
    
    if [[ ${#failed_tasks[@]} -gt 0 ]]; then
        echo
        echo "✗ Failed:"
        for t in "${failed_tasks[@]}"; do
            echo "  - $t"
        done
        return 1
    fi
    
    return 0
}

# Run validate-all with email notification (for cron)
validate_all_cron() {
    local mode="${1:-cryptcheck}"
    local log_file="/tmp/cloud-sync-validation-$(date +%Y%m%d-%H%M%S).log"
    local hostname
    hostname=$(hostname)
    
    # Run validation and capture output
    {
        echo "Cloud Sync Validation Report"
        echo "Host: $hostname"
        echo "Date: $(date)"
        echo
        validate_all "$mode"
    } 2>&1 | tee "$log_file"
    
    local rc=${PIPESTATUS[0]}
    
    # Send alert via TrueNAS alert system
    local subject status
    if [[ $rc -eq 0 ]]; then
        status="SUCCESS"
        subject="[TrueNAS] Cloud Sync Validation PASSED"
    else
        status="FAILURE"
        subject="[TrueNAS] Cloud Sync Validation FAILED"
    fi
    
    # Send email via TrueNAS mail system
    local mail_body
    mail_body=$(cat "$log_file")
    
    echo "$mail_body" | /usr/bin/mail -s "$subject" root
    log_info "Email notification sent"
    
    # Also create a TrueNAS alert if validation failed
    if [[ $rc -ne 0 ]]; then
        curl -sk -H "$(get_auth)" \
            -H "Content-Type: application/json" \
            -X POST "https://${TRUENAS_HOST}/api/v2.0/alert/oneshot_create" \
            -d "$(jq -n \
                --arg msg "Cloud Sync validation failed. Check $log_file for details." \
                '{name: "CloudSyncValidation", level: "WARNING", message: $msg}')" 2>/dev/null || true
    fi
    
    return $rc
}

# Test email notification
test_email() {
    log_info "Sending test email via TrueNAS mail system..."
    
    local hostname
    hostname=$(hostname 2>/dev/null || echo "TrueNAS")
    
    local subject="[TrueNAS] Cloud Sync Validation - Test Email"
    local body="This is a test email from the cloud sync validation script.

Host: $hostname
Date: $(date)
Script: $SCRIPT_DIR/validate-cloud-sync.sh

If you received this email, notifications are working correctly!"

    echo "$body" | /usr/bin/mail -s "$subject" root
    
    if [[ $? -eq 0 ]]; then
        log_info "✓ Test email sent!"
    else
        log_error "✗ Failed to send email"
    fi
}

# Test TrueNAS alert
test_alert() {
    log_info "Creating test alert in TrueNAS..."
    
    local response
    response=$(curl -sk -H "$(get_auth)" \
        -H "Content-Type: application/json" \
        -X POST "https://${TRUENAS_HOST}/api/v2.0/alert/oneshot_create" \
        -d "$(jq -n '{
            name: "CloudSyncValidationTest",
            level: "INFO", 
            message: "Test alert from cloud sync validation script. You can dismiss this."
        }')" 2>&1)
    
    if [[ $? -eq 0 && "$response" != *"error"* ]]; then
        log_info "✓ Test alert created!"
        log_info "Check TrueNAS UI → Alerts (bell icon top right)"
    else
        log_error "✗ Failed to create alert"
        log_error "Response: $response"
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  list                    List all cloud sync tasks
  validate <task_id>      Full bit-perfect verification (downloads all files)
  validate-all            Validate ALL encrypted tasks (for manual run)
  cron                    Validate all + email notification (for cron jobs)
  quick <task_id>         Quick size-only check (fast but not bit-perfect)
  quick-all               Quick check all tasks
  sample <task_id>        Download ~50MB sample to verify decryption works
  test <task_id>          Test connection by listing remote files
  test-email              Send a test email via TrueNAS
  test-alert              Create a test alert in TrueNAS

Examples:
  $0 list
  $0 test 3               # Verify connection works
  $0 test-email           # Test email notifications
  $0 test-alert           # Test TrueNAS alerts
  $0 sample 3             # Quick decryption test (~50MB)
  $0 validate 3           # Full bit-perfect verification (slow!)
  $0 validate-all         # Validate all encrypted tasks
  $0 cron                 # For scheduled runs with email alerts

Cron setup (TrueNAS GUI):
  System -> Advanced -> Cron Jobs -> Add
  Command: /home/fabian/validate-cloud-sync.sh cron
  Schedule: Weekly (e.g., Sunday 2:00 AM)

EOF
}

# Main
main() {
    check_deps
    load_env
    
    local cmd="${1:-}"
    
    case "$cmd" in
        list)
            list_tasks
            ;;
        validate)
            [[ -z "${2:-}" ]] && { log_error "Task ID required"; usage; exit 1; }
            acquire_lock
            run_validation "$2" "cryptcheck"
            ;;
        validate-all)
            acquire_lock
            validate_all "cryptcheck"
            ;;
        quick)
            [[ -z "${2:-}" ]] && { log_error "Task ID required"; usage; exit 1; }
            acquire_lock
            run_validation "$2" "quick"
            ;;
        quick-all)
            acquire_lock
            validate_all "quick"
            ;;
        cron)
            acquire_lock
            validate_all_cron "cryptcheck"
            ;;
        test)
            [[ -z "${2:-}" ]] && { log_error "Task ID required"; usage; exit 1; }
            run_validation "$2" "list"
            ;;
        sample)
            [[ -z "${2:-}" ]] && { log_error "Task ID required"; usage; exit 1; }
            acquire_lock
            run_validation "$2" "sample"
            ;;
        test-email)
            test_email
            ;;
        test-alert)
            test_alert
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
