#!/bin/bash
# vm-snapshot.sh - Create and prune VM snapshots
# Usage: ./vm-snapshot.sh <vmid> [--daily N] [--weekly N] [--monthly N]
# Example: ./vm-snapshot.sh 100 --daily 7 --weekly 4 --monthly 3

set -euo pipefail

# ---------- Defaults ----------
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3
VMID=""
DRY_RUN=false

# ---------- Usage ----------
usage() {
  echo "Usage: $0 <vmid> [options]"
  echo ""
  echo "Options:"
  echo "  --daily N      Number of daily snapshots to keep   (default: $KEEP_DAILY)"
  echo "  --weekly N     Number of weekly snapshots to keep  (default: $KEEP_WEEKLY)"
  echo "  --monthly N    Number of monthly snapshots to keep (default: $KEEP_MONTHLY)"
  echo "  --dry-run      Show what would be deleted without deleting"
  echo "  --help         Show this help message"
  echo ""
  echo "Snapshot naming convention:"
  echo "  daily-YYYY-MM-DD"
  echo "  weekly-YYYY-Www"
  echo "  monthly-YYYY-MM"
  exit 1
}

# ---------- Argument Parsing ----------
if [[ $# -lt 1 ]]; then
  echo "Error: VMID is required."
  echo ""
  usage
fi

if [[ "$1" == --* ]]; then
  echo "Error: VMID must be the first argument, got '$1' instead."
  echo ""
  usage
fi

if ! [[ "$1" =~ ^[0-9]+$ ]]; then
  echo "Error: VMID must be a positive integer, got '$1'."
  echo ""
  usage
fi

VMID="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daily)   KEEP_DAILY="$2";   shift 2 ;;
    --weekly)  KEEP_WEEKLY="$2";  shift 2 ;;
    --monthly) KEEP_MONTHLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;      shift   ;;
    --help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------- Helpers ----------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }

delete_snapshot() {
  local snap="$1"
  if $DRY_RUN; then
    log "DRY-RUN: would delete snapshot '$snap'"
  else
    log "Deleting snapshot '$snap'..."
    qm delsnapshot "$VMID" "$snap"
  fi
}

# ---------- Validate VMID ----------
if ! qm status "$VMID" &>/dev/null; then
  echo "Error: VM $VMID not found or not accessible."
  exit 1
fi

# ---------- Create Snapshot ----------
NOW=$(date '+%Y-%m-%d %H:%M:%S')
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
WEEK=$(date '+%Y-W%V')
MONTH=$(date '+%Y-%m')
DOW=$(date '+%u')   # 1=Mon ... 7=Sun
DOM=$(date '+%d')   # day of month

snapshot_exists() {
  local name="$1"
  qm listsnapshot "$VMID" | awk '{print $2}' | grep -qx "$name"
}

create_snapshot() {
  local name="$1"
  local desc="$2"
  if $DRY_RUN; then
    log "DRY-RUN: would create snapshot '$name'"
  else
    log "Creating snapshot '$name' for VM $VMID..."
    qm snapshot "$VMID" "$name" --description "$desc"
  fi
}

# Always create a daily snapshot -- timestamp in name allows multiple per day
create_snapshot "daily-${TIMESTAMP}" "Daily snapshot $NOW"

# Create weekly snapshot on Sunday (DOW=7), skip if one already exists for this week
if [[ "$DOW" == "7" ]]; then
  if snapshot_exists "weekly-${WEEK}"; then
    log "Weekly snapshot for $WEEK already exists, skipping."
  else
    create_snapshot "weekly-${WEEK}" "Weekly snapshot $NOW"
  fi
fi

# Create monthly snapshot on 1st of month, skip if one already exists for this month
if [[ "$DOM" == "01" ]]; then
  if snapshot_exists "monthly-${MONTH}"; then
    log "Monthly snapshot for $MONTH already exists, skipping."
  else
    create_snapshot "monthly-${MONTH}" "Monthly snapshot $NOW"
  fi
fi

# ---------- Prune Snapshots ----------
log "Pruning snapshots for VM $VMID (keep: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY)..."

# Get all snapshot names (skip 'current')
ALL_SNAPS=$(qm listsnapshot "$VMID" | awk '{print $2}' | grep -v '^current$' || true)

prune_group() {
  local prefix="$1"
  local keep="$2"

  # Filter and sort descending (newest first)
  local snaps
  snaps=$(echo "$ALL_SNAPS" | grep "^${prefix}-" | sort -r || true)

  local count=0
  while IFS= read -r snap; do
    [[ -z "$snap" ]] && continue
    count=$((count + 1))
    if [[ $count -gt $keep ]]; then
      delete_snapshot "$snap"
    else
      log "Keeping snapshot '$snap' ($count/$keep)"
    fi
  done <<< "$snaps"
}

prune_group "daily"   "$KEEP_DAILY"
prune_group "weekly"  "$KEEP_WEEKLY"
prune_group "monthly" "$KEEP_MONTHLY"

log "Done."
