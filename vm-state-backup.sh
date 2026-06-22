#!/bin/sh
# vm-state-backup.sh — pull each VM's state directory into the cloud-synced
# archive dataset, so it rides the existing 'archive' -> offsite Cloud Sync
# (e.g. to a Hetzner Storage Box).
#
# Runs on TrueNAS CORE as root (via a cron job). For each configured VM it SSHes
# in with a dedicated key (admin has passwordless sudo, so root-owned data dirs
# are readable) and streams a gzip'd tar back, written atomically (.tmp -> mv) so
# Cloud Sync never grabs a half-written file.
#
# Targets are read from a config file (NOT committed — it holds your LAN IPs),
# one VM per line:   name  ip  parent_dir  subdir
# Default path: a `vm-state-backup.conf` next to this script. Override with
# VMBACKUP_CONF. See vm-state-backup.conf.example.
#
# Restore: re-provision the VM from its repo, then extract the matching tarball
# into the VM's data dir.
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF="${VMBACKUP_CONF:-$SELF_DIR/vm-state-backup.conf}"
DEST="${VMBACKUP_DEST:-/mnt/tank/archive/vm-state}"
KEY="${VMBACKUP_KEY:-$SELF_DIR/id_vmbackup}"
SSH_USER="${VMBACKUP_SSH_USER:-admin}"
SSHOPTS="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes"

[ -f "$CONF" ] || { echo "config not found: $CONF (copy vm-state-backup.conf.example)"; exit 1; }

# Single-run lock so overlapping invocations can't clobber each other's .tmp
# files (the daily schedule never overlaps, but manual runs might).
LOCK="${TMPDIR:-/tmp}/vm-state-backup.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another vm-state-backup run is in progress ($LOCK); exiting."
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

mkdir -p "$DEST"
LOG="$DEST/last-run.log"
: > "$LOG"

log() { echo "$1"; echo "$1" >> "$LOG"; }

# Read "name ip parent subdir" lines, skipping blanks and # comments.
while read -r name ip parent sub _rest; do
    case "$name" in '' | \#*) continue ;; esac
    [ -n "$ip" ] && [ -n "$parent" ] && [ -n "$sub" ] || continue
    out="$DEST/$name.tar.gz"; tmp="$out.tmp"
    if ssh $SSHOPTS "$SSH_USER@$ip" "sudo tar czf - -C '$parent' '$sub'" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$out"
        log "$(date '+%F %T') OK   $name -> $(du -h "$out" | cut -f1)"
    else
        rm -f "$tmp"
        log "$(date '+%F %T') FAIL $name ($ip) — VM down or backup key not authorized?"
    fi
done < "$CONF"
