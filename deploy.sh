#!/bin/bash
#
# deploy.sh — idempotently provision the NAS-side VM-state backup on TrueNAS CORE,
# entirely via the REST API (no sudo). Re-runnable: it only creates what's
# missing and re-uploads the script/config/key in place. After this, the offload
# VMs' state is pulled nightly into the cloud-synced archive dataset and the VM
# zvols are snapshotted on-box.
#
# It sets up:
#   1. the backup SSH key (generates one if absent — see the warning it prints),
#   2. uploads vm-state-backup.sh + vm-state-backup.conf + the private key to the NAS,
#   3. a recursive ZFS snapshot task on the VM dataset (on-box protection),
#   4. a daily cron job that runs vm-state-backup.sh (offsite via Cloud Sync).
#
# Config comes from .env (TRUENAS_HOST + TRUENAS_API_KEY required). The VM list
# lives in vm-state-backup.conf (gitignored; copy vm-state-backup.conf.example).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# --- config (override any of these in .env) -------------------------------- #
load_config() {
    [[ -f "$ENV_FILE" ]] || { log_error ".env not found — copy .env.example to .env"; exit 1; }
    set -a; # shellcheck disable=SC1090
    source "$ENV_FILE"; set +a
    : "${TRUENAS_HOST:?set TRUENAS_HOST in .env}"
    if [[ -z "${TRUENAS_API_KEY:-}" && -z "${TRUENAS_PASSWORD:-}" ]]; then
        log_error "set TRUENAS_API_KEY (recommended) or TRUENAS_USER/TRUENAS_PASSWORD in .env"; exit 1
    fi
    VM_BACKUP_DATASET="${VM_BACKUP_DATASET:-tank/vms}"
    VM_BACKUP_DEST="${VM_BACKUP_DEST:-/mnt/tank/archive/vm-state}"
    NAS_SCRIPT="${NAS_SCRIPT:-/root/vm-state-backup.sh}"
    NAS_CONF="${NAS_CONF:-/root/vm-state-backup.conf}"
    NAS_KEY="${NAS_KEY:-/root/id_vmbackup}"
    SNAP_KEEP_VALUE="${SNAP_KEEP_VALUE:-2}"; SNAP_KEEP_UNIT="${SNAP_KEEP_UNIT:-WEEK}"
    SNAP_MIN="${SNAP_MIN:-30}"; SNAP_HOUR="${SNAP_HOUR:-3}"
    CRON_MIN="${CRON_MIN:-30}";  CRON_HOUR="${CRON_HOUR:-4}"
    for c in curl jq ssh-keygen; do command -v "$c" >/dev/null || { log_error "missing dependency: $c"; exit 1; }; done
}

get_auth() {
    if [[ -n "${TRUENAS_API_KEY:-}" ]]; then echo "Authorization: Bearer ${TRUENAS_API_KEY}";
    else echo "Authorization: Basic $(printf '%s' "${TRUENAS_USER:-root}:${TRUENAS_PASSWORD}" | base64)"; fi
}

api() {  # method endpoint [json-body]
    local method="$1" endpoint="$2" data="${3:-}"
    if [[ -n "$data" ]]; then
        curl -sk -H "$(get_auth)" -H "Content-Type: application/json" -X "$method" \
            "https://${TRUENAS_HOST}/api/v2.0${endpoint}" -d "$data"
    else
        curl -sk -H "$(get_auth)" -X "$method" "https://${TRUENAS_HOST}/api/v2.0${endpoint}"
    fi
}

put_file() {  # localfile naspath octal-mode-decimal
    local src="$1" dst="$2" mode="$3" code
    code="$(curl -sk -H "$(get_auth)" \
        -F "data={\"method\":\"filesystem.put\",\"params\":[\"${dst}\",{\"mode\":${mode}}]}" \
        -F "file=@${src}" "https://${TRUENAS_HOST}/_upload" -o /dev/null -w '%{http_code}')"
    [[ "$code" == "200" ]] || { log_error "upload of ${dst} failed (HTTP ${code})"; exit 1; }
    log_info "uploaded ${src##*/} -> ${dst}"
}

ensure_key() {
    log_step "Backup SSH key"
    if [[ -f "${SCRIPT_DIR}/id_vmbackup" ]]; then
        log_info "using existing key ${SCRIPT_DIR}/id_vmbackup"
    else
        ssh-keygen -t ed25519 -N "" -C "vm-state-backup@truenas" -f "${SCRIPT_DIR}/id_vmbackup" >/dev/null
        log_warn "generated a NEW backup keypair. Its PUBLIC key must be authorized on the VMs."
        log_warn "Add this line to each VM repo's cloud-init ssh_authorized_keys, then re-create / re-key the VMs:"
        echo "         $(cat "${SCRIPT_DIR}/id_vmbackup.pub")"
    fi
}

ensure_conf() {
    if [[ ! -f "${SCRIPT_DIR}/vm-state-backup.conf" ]]; then
        log_error "vm-state-backup.conf not found — copy vm-state-backup.conf.example and set your VM IPs."
        exit 1
    fi
}

upload_payload() {
    log_step "Uploading backup payload to the NAS"
    put_file "${SCRIPT_DIR}/vm-state-backup.sh"   "${NAS_SCRIPT}" 493   # 0755
    put_file "${SCRIPT_DIR}/vm-state-backup.conf" "${NAS_CONF}"   384   # 0600
    put_file "${SCRIPT_DIR}/id_vmbackup"          "${NAS_KEY}"    384   # 0600
}

ensure_snapshot_task() {
    log_step "ZFS snapshot task for ${VM_BACKUP_DATASET} (on-box)"
    local existing
    existing="$(api GET /pool/snapshottask | jq -r --arg ds "$VM_BACKUP_DATASET" \
        'map(select(.dataset==$ds)) | (.[0].id // empty)')"
    if [[ -n "$existing" ]]; then
        log_info "snapshot task already present (id ${existing}) — leaving as-is"
        return
    fi
    local body
    body="$(jq -nc --arg ds "$VM_BACKUP_DATASET" --argjson kv "$SNAP_KEEP_VALUE" \
        --arg ku "$SNAP_KEEP_UNIT" --arg mi "$SNAP_MIN" --arg ho "$SNAP_HOUR" \
        '{dataset:$ds, recursive:true, exclude:[], lifetime_value:$kv, lifetime_unit:$ku,
          naming_schema:"auto-%Y-%m-%d_%H-%M", enabled:true, allow_empty:true,
          schedule:{minute:$mi, hour:$ho, dom:"*", month:"*", dow:"*"}}')"
    local id
    id="$(api POST /pool/snapshottask "$body" | jq -r '.id // empty')"
    [[ -n "$id" ]] && log_info "created snapshot task id ${id} (keep ${SNAP_KEEP_VALUE} ${SNAP_KEEP_UNIT})" \
        || { log_error "failed to create snapshot task"; exit 1; }
}

ensure_cron_job() {
    log_step "Cron job for ${NAS_SCRIPT} (offsite via Cloud Sync)"
    local existing
    existing="$(api GET /cronjob | jq -r --arg cmd "$NAS_SCRIPT" \
        'map(select(.command==$cmd)) | (.[0].id // empty)')"
    if [[ -n "$existing" ]]; then
        log_info "cron job already present (id ${existing}) — leaving as-is"
        return
    fi
    local body
    body="$(jq -nc --arg cmd "$NAS_SCRIPT" --arg mi "$CRON_MIN" --arg ho "$CRON_HOUR" \
        '{command:$cmd, description:"VM state backup -> archive (offsite via Cloud Sync)",
          enabled:true, stdout:true, stderr:false, user:"root",
          schedule:{minute:$mi, hour:$ho, dom:"*", month:"*", dow:"*"}}')"
    local id
    id="$(api POST /cronjob "$body" | jq -r '.id // empty')"
    [[ -n "$id" ]] && log_info "created cron job id ${id} (daily ${CRON_HOUR}:${CRON_MIN})" \
        || { log_error "failed to create cron job"; exit 1; }
}

main() {
    load_config
    log_step "Deploying VM-state backup to ${TRUENAS_HOST}"
    ensure_key
    ensure_conf
    upload_payload
    ensure_snapshot_task
    ensure_cron_job
    echo
    log_info "✓ Done. Backups: on-box ZFS snapshots of ${VM_BACKUP_DATASET} + nightly"
    log_info "  state pull into ${VM_BACKUP_DEST} (offsite via your 'archive' Cloud Sync)."
    log_info "  Verify a run from the TrueNAS UI (Tasks → Cron Jobs → Run Now) or wait for the schedule."
}

main "$@"
