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
# Run-overlap lock (mkdir is atomic; flock is unavailable on macOS)
# Prevents the 15-min cron from launching a second run on top of a slow one.
# =========================
LOCK_DIR="${BASE}/.sync.lock"
RESP_FILE=""
cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    [[ -n "$RESP_FILE" ]] && rm -f "$RESP_FILE"
}
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SKIP] Another run holds the lock ($LOCK_DIR); exiting." | tee -a "$LOG_FILE"
    exit 0
fi
trap cleanup EXIT

# Per-run curl response file (avoids cross-run clobbering of a shared /tmp path).
# Trailing XXXXXX (no suffix) so BSD/macOS mktemp actually randomizes the name.
RESP_FILE="$(mktemp "${TMPDIR:-/tmp}/speakr_upload_resp_XXXXXX")"

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
    # --max-time bounds a single attempt; --retry handles transient network/5xx
    # errors with backoff. Multipart upload is the same file each time, so a
    # retried POST is safe (Speakr de-dupes server-side; we also hash locally).
    http_code="$(
        curl -sS -o "$RESP_FILE" -w "%{http_code}" \
            --connect-timeout 30 --max-time 300 \
            --retry 3 --retry-delay 5 --retry-connrefused \
            -X POST "$SPEAKR_UPLOAD_URL" \
            -H "Accept: */*" \
            -H "Origin: ${SPEAKR_BASE_URL}" \
            -H "Referer: ${SPEAKR_BASE_URL}/" \
            -H "X-CSRFToken: ${SPEAKR_CSRF}" \
            -H "Cookie: ${SPEAKR_COOKIE}" \
            -F "file=@${f};type=audio/x-wav"
    )" || http_code="000"

    if [[ "$http_code" == "202" ]]; then
        rec_id="$(RESP_FILE="$RESP_FILE" python3 - <<'PY'
import json, os
try:
    with open(os.environ["RESP_FILE"], "r") as f:
        d = json.load(f)
    print(d.get("recording_id") or d.get("id") or "")
except Exception:
    print("")
PY
)"
        log "[OK] Uploaded (HTTP 202) RecordingID=${rec_id:-unknown}"
        record_uploaded_hash "$f"
        mv -f "$f" "${UPLOADED_DIR}/${base}"
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        # Auth (cookie/CSRF) is bad for ALL files, not just this one. The
        # scraped browser session has almost certainly expired. Stop the batch
        # loudly so the failure is noticed instead of silently dropping every
        # recording into failed_speakr/. Leave the file in DEST_FLAT to retry.
        log "[AUTH-FAIL] HTTP $http_code for $base — Speakr session likely expired; aborting batch."
        cat "$RESP_FILE" >> "$LOG_FILE" 2>/dev/null || true
        return 2
    elif [[ "$http_code" == 5* || "$http_code" == "000" || "$http_code" == "408" || "$http_code" == "429" ]]; then
        # Transient: server error, network failure, timeout, or rate-limit.
        # Leave the file in DEST_FLAT so the next run retries it instead of
        # permanently parking a recoverable failure in failed_speakr/.
        log "[FAIL] HTTP $http_code for $base (transient — will retry next run)"
        cat "$RESP_FILE" >> "$LOG_FILE" 2>/dev/null || true
        return 1
    else
        # Permanent client rejection (e.g. 400/413/415/422): retrying the same
        # bytes won't help. Park it in failed_speakr/ so it doesn't loop forever.
        log "[FAIL] HTTP $http_code for $base (permanent — moved to failed_speakr/)"
        cat "$RESP_FILE" >> "$LOG_FILE" 2>/dev/null || true
        mv -f "$f" "${FAILED_DIR}/${base}"
        return 1
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
# Skip files already uploaded (present in UPLOADED_DIR) to avoid the redundant
# copy + SHA256 re-hash churn on every run. cp -n still guards DEST_FLAT itself.
log "==> Step 3: Flattening directory structure"
while IFS= read -r -d '' src; do
    b="$(basename "$src")"
    [[ -e "${UPLOADED_DIR}/${b}" ]] && continue
    cp -n "$src" "$DEST_FLAT/" 2>/dev/null || true
done < <(find "$DEST_EXT" -type f -name "*.wav" -print0)

# Step 4: Upload new files
log "==> Step 4: Uploading to Speakr"
shopt -s nullglob
upload_count=0
auth_failed=0
for f in "$DEST_FLAT"/*.wav; do
    # upload_one returns: 0 ok/skip, 1 transient (left for retry), 2 auth failure.
    # Guard the call so set -e doesn't abort on the non-zero retry/auth codes.
    rc=0
    upload_one "$f" || rc=$?
    ((upload_count++)) || true
    if [[ "$rc" -eq 2 ]]; then
        auth_failed=1
        break
    fi
done

log "========== Sync Complete: $upload_count files processed =========="
log "Uploaded:  $UPLOADED_DIR"
log "Failed:    $FAILED_DIR"
log "Log:       $LOG_FILE"

# Exit non-zero on auth failure so cron/launchd/monitoring notices the expired
# Speakr session instead of every recording silently failing to upload.
if [[ "$auth_failed" -eq 1 ]]; then
    log "[ERROR] Speakr authentication failed — credentials need refreshing. See auth.env."
    exit 1
fi
