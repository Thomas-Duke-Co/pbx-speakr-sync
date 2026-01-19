#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

# =========================
# PBX Speakr Sync
# Unattended sync of PBX recordings to Speakr
# =========================

# =========================
# Configuration (override via config file or environment)
# =========================
CONFIG_FILE="${HOME}/.config/speakr/sync.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# PBX settings
PBX_HOST="${PBX_HOST:-thomasduke.crosstalksolutions.com}"
PBX_USER="${PBX_USER:-root}"
PBX_PORT="${PBX_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/var/spool/asterisk/monitor/}"

# Extension to filter
EXT="${EXT:-1104}"

# Local paths
BASE="${BASE:-${HOME}/pbx_recordings}"
DEST_ALL="${BASE}/monitor"
DEST_EXT="${BASE}/ext_${EXT}"
DEST_FLAT="${BASE}/ext_${EXT}_flat"
UPLOADED_DIR="${BASE}/uploaded_to_speakr"
FAILED_DIR="${BASE}/failed_speakr"
LOG_FILE="${BASE}/sync.log"

# Hash tracking
UPLOADED_HASHES="${HOME}/.config/speakr/uploaded_hashes.txt"

mkdir -p "$DEST_ALL" "$DEST_EXT" "$DEST_FLAT" "$UPLOADED_DIR" "$FAILED_DIR"
mkdir -p "$(dirname "$UPLOADED_HASHES")"
touch "$UPLOADED_HASHES"

# =========================
# Speakr auth
# =========================
AUTH_FILE="${HOME}/.config/speakr/auth.env"
if [[ ! -f "$AUTH_FILE" ]]; then
    echo "[ERROR] Missing auth file: $AUTH_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$AUTH_FILE"

if [[ -z "${SPEAKR_BASE_URL:-}" || -z "${SPEAKR_COOKIE:-}" || -z "${SPEAKR_CSRF:-}" ]]; then
    echo "[ERROR] auth.env must define SPEAKR_BASE_URL, SPEAKR_COOKIE, SPEAKR_CSRF"
    exit 1
fi

SPEAKR_UPLOAD_URL="${SPEAKR_BASE_URL}/upload"

# =========================
# Logging
# =========================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# =========================
# Functions
# =========================
file_size_bytes() {
    stat -f%z "$1"
}

get_file_hash() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

is_duplicate() {
    local file="$1"
    local hash
    hash=$(get_file_hash "$file")
    grep -q "^$hash " "$UPLOADED_HASHES" 2>/dev/null
}

record_uploaded_hash() {
    local file="$1"
    local hash
    hash=$(get_file_hash "$file")
    echo "$hash $(basename "$file") $(date -Iseconds)" >> "$UPLOADED_HASHES"
}

upload_one() {
    local f="$1"
    local base
    base="$(basename "$f")"

    local size
    size="$(file_size_bytes "$f")"

    # Skip tiny placeholder recordings
    if [[ "$size" -le 1000 ]]; then
        log "[SKIP] Too small ($size bytes): $base"
        mv -f "$f" "${FAILED_DIR}/${base}"
        return 0
    fi

    # Skip duplicates
    if is_duplicate "$f"; then
        log "[SKIP] Duplicate: $base"
        rm -f "$f"
        return 0
    fi

    log "[UPLOAD] $base"
    http_code="$(
        curl -sS -o /tmp/speakr_upload_resp.json -w "%{http_code}" \
            -X POST "$SPEAKR_UPLOAD_URL" \
            -H "Accept: */*" \
            -H "Origin: ${SPEAKR_BASE_URL}" \
            -H "Referer: ${SPEAKR_BASE_URL}/" \
            -H "X-CSRFToken: ${SPEAKR_CSRF}" \
            -H "Cookie: ${SPEAKR_COOKIE}" \
            -F "file=@${f};type=audio/x-wav"
    )"

    if [[ "$http_code" == "202" ]]; then
        rec_id="$(python3 - <<'PY'
import json
try:
    with open("/tmp/speakr_upload_resp.json","r") as f:
        d=json.load(f)
    print(d.get("recording_id") or d.get("id") or "")
except Exception:
    print("")
PY
)"
        log "[OK] Uploaded (HTTP 202) RecordingID=${rec_id:-unknown}"
        record_uploaded_hash "$f"
        mv -f "$f" "${UPLOADED_DIR}/${base}"
    else
        log "[FAIL] HTTP $http_code for $base"
        cat /tmp/speakr_upload_resp.json >> "$LOG_FILE" 2>/dev/null || true
        mv -f "$f" "${FAILED_DIR}/${base}"
    fi
}

# =========================
# Main
# =========================
log "========== PBX Speakr Sync Started =========="
log "PBX: ${PBX_USER}@${PBX_HOST}:${REMOTE_DIR}"
log "Extension filter: ${EXT}"

# Step 1: Pull all recordings from PBX
log "==> Step 1: Pulling recordings from PBX"
rsync -av --ignore-existing --partial \
    -e "ssh -p ${PBX_PORT}" \
    "${PBX_USER}@${PBX_HOST}:${REMOTE_DIR}" \
    "${DEST_ALL}/" >> "$LOG_FILE" 2>&1

# Step 2: Copy only matching extension
log "==> Step 2: Filtering extension ${EXT}"
rsync -av --ignore-existing \
    --include='*/' \
    --include="*-${EXT}-*.wav" \
    --exclude='*' \
    "${DEST_ALL}/" \
    "${DEST_EXT}/" >> "$LOG_FILE" 2>&1

# Step 3: Flatten directory structure
log "==> Step 3: Flattening directory structure"
find "$DEST_EXT" -type f -name "*.wav" -exec cp -n {} "$DEST_FLAT/" \; 2>/dev/null || true

# Step 4: Upload new files
log "==> Step 4: Uploading to Speakr"
shopt -s nullglob
upload_count=0
for f in "$DEST_FLAT"/*.wav; do
    upload_one "$f"
    ((upload_count++)) || true
done

log "========== Sync Complete: $upload_count files processed =========="
log "Uploaded:  $UPLOADED_DIR"
log "Failed:    $FAILED_DIR"
log "Log:       $LOG_FILE"
