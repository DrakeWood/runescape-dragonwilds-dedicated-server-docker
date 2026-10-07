#!/bin/bash
set -e

# --- DROP PRIVILEGES ---
# If running as root, match the ubuntu user's UID/GID to the volume owner
# so the server process can read/write the mounted directory without the
# host user needing to chmod or chown anything.
if [ "$(id -u)" = "0" ]; then
    VOLUME_UID=$(stat -c '%u' "${SERVERDIR:-/home/ubuntu/Steam}" 2>/dev/null || echo "1000")
    VOLUME_GID=$(stat -c '%g' "${SERVERDIR:-/home/ubuntu/Steam}" 2>/dev/null || echo "1000")
    # If the volume is owned by root (e.g. not yet mounted / empty), fall back to 1000
    if [ "$VOLUME_UID" = "0" ]; then
        VOLUME_UID=1000
        VOLUME_GID=1000
    fi
    groupmod -g "$VOLUME_GID" ubuntu 2>/dev/null || true
    usermod  -u "$VOLUME_UID" ubuntu 2>/dev/null || true
    # Only chown internal dirs — do NOT recurse into the bind-mounted volume
    chown ubuntu:ubuntu /home/ubuntu
    chown -R ubuntu:ubuntu /home/ubuntu/steamcmd
    chown -R ubuntu:ubuntu /home/ubuntu/Steam
    exec gosu ubuntu "$0" "$@"
fi

# --- ENVIRONMENT VARIABLES ---
APPID=4019830
SERVERDIR="${SERVERDIR:-/home/ubuntu/Steam}"
CONFIGFILE="$SERVERDIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
BACKUPDIR="$SERVERDIR/backup"
LOGFILE="$SERVERDIR/logs/entrypoint.log"
LAST_ACTIVITY_FILE="$SERVERDIR/.last_activity"
PLAYER_COUNT_FILE="$SERVERDIR/.player_count"
SERVER_RESTART_FILE="$SERVERDIR/.server_restart"
SERVER_PID_FILE="$SERVERDIR/.server_pid"
LAST_BACKUP_DATE_FILE="$SERVERDIR/.last_backup_date"
LAST_APPLIED_BUILD_FILE="$SERVERDIR/.last_applied_build"
UPDATE_IN_PROGRESS_FILE="$SERVERDIR/.update_in_progress"
BACKUP_IN_PROGRESS_FILE="$SERVERDIR/.backup_in_progress"
SERVER_PORT="${SERVER_PORT:-7777}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-true}"
UPDATE_TIME="${UPDATE_TIME:-3600}"              # How often (seconds) to check for updates (e.g. 3600 = every hour)
ENABLE_DISCORD_NOTIF="${ENABLE_DISCORD_NOTIF:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
IDLE_WAIT="${IDLE_WAIT:-360}"
SERVER_STOP_TIMEOUT="${SERVER_STOP_TIMEOUT:-120}"   # Max seconds to wait for the server to stop before SIGKILL
LOG_TO_STDOUT="${LOG_TO_STDOUT:-true}"              # Also echo script log lines to the container stdout (docker logs)
MAX_LOG_SIZE="${MAX_LOG_SIZE:-5242880}"             # Rotate the script log once it reaches this many bytes (default 5 MB)
LOG_RETENTION="${LOG_RETENTION:-5}"                 # Number of rotated script log generations to keep
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PLAYER_CHECK_INTERVAL=5
# Clients that time out or crash never log a leave line. If the player count has
# not changed for this long, assume it is stale and treat the server as empty.
PLAYER_STALE_TIMEOUT="${PLAYER_STALE_TIMEOUT:-14400}"   # 4 hours
BACKUP_AFTER_UPDATE="${BACKUP_AFTER_UPDATE:-true}"
BACKUP_DAILY="${BACKUP_DAILY:-true}"
BACKUP_TIME="${BACKUP_TIME:-3:00 AM}"           # Time-of-day to run daily backup (12-hour format)
POLL_INTERVAL="${POLL_INTERVAL:-60}"            # How often (seconds) the backup loop checks the schedule

# --- DEDICATEDSERVER.INI CONFIGURATION ---
ADMIN_PASSWORD="${ADMIN_PASSWORD}"              # Provided
OWNER_ID="${OWNER_ID}"                          # Required
SERVER_GUID="${SERVER_GUID}"                    # Provided
SERVER_NAME="${SERVER_NAME}"                    # Provided
WORLD_PASSWORD="${WORLD_PASSWORD}"              # Optional
DEFAULT_WORLD_NAME="${DEFAULT_WORLD_NAME}"      # Provided

HOME=/home/ubuntu
mkdir -p "$BACKUPDIR" "$SERVERDIR/steamapps" "$(dirname "$LOGFILE")"

# Migrate an old entrypoint.log that used to live in the game log directory,
# so existing history isn't lost when the script log moves to logs/.
OLD_LOGFILE="$SERVERDIR/RSDragonwilds/Saved/Logs/entrypoint.log"
if [ -f "$OLD_LOGFILE" ] && [ ! -f "$LOGFILE" ]; then
    mv "$OLD_LOGFILE" "$LOGFILE"
fi

# Rotate the script log once it grows past MAX_LOG_SIZE instead of deleting
# it, so history survives container restarts (e.g. after every update).
# Total footprint is bounded by MAX_LOG_SIZE x LOG_RETENTION.
if [ "$LOG_RETENTION" -gt 1 ] && [ -s "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE")" -ge "$MAX_LOG_SIZE" ]; then
    for n in $(seq $((LOG_RETENTION - 1)) -1 1); do
        [ -f "$LOGFILE.$n" ] && mv "$LOGFILE.$n" "$LOGFILE.$((n + 1))"
    done
    mv "$LOGFILE" "$LOGFILE.1"
fi

log() {
    # Timestamp prefixed in the log file; plain on stdout so that docker logs
    # output keeps its current shape.
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
    if [ "$LOG_TO_STDOUT" = "true" ]; then
        echo "$1"
    fi
}

# --- FUNCTION TO SEND DISCORD NOTIFICATION ---
# jq builds the JSON so quotes/backslashes in names can't break the payload;
# the timeout keeps a slow Discord from stalling the server loops.
send_discord() {
    [ "$ENABLE_DISCORD_NOTIF" = "true" ] && [ -n "$DISCORD_WEBHOOK_URL" ] || return 0
    jq -n --arg c "**[${SERVER_NAME:-Dragonwilds}]** $1" '{content: $c}' \
        | curl -s -m 5 -X POST -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# --- INSTALL / VERIFY SERVER FILES VIA STEAMCMD ---
install_or_verify_server() {
    log "=== Installing/verifying server files via SteamCMD ==="
    send_discord "📥 Installing Dragonwilds Dedicated Server — this may take a while..."
    for i in {1..5}; do
        log "SteamCMD attempt $i..."
        /home/ubuntu/steamcmd/steamcmd.sh \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_update $APPID validate \
            +quit && break
        log "SteamCMD failed, retrying in 5 seconds..."
        sleep 5
    done
    log "=== SteamCMD install/verify complete ==="
    send_discord "✅ Dragonwilds Dedicated Server installed."
}

# -- DEDICATEDSERVER.INI ---
#
# Generate the ini file if needed, then provide it with (at least) the OwnerId
# This avoids an otherwise unnecessary restart during first-time setup that
# occurs in the standard flow where the server generates its own ini file but
# lacks the OwnerId.
#
# This will also update the ini file each time the container starts, making it
# a little easier to change server settings via environment

prepare_dedicated_server_ini() {
    set_key() {
        local key="$1"
        local new_value="$2"
        local escaped

        [ -n "$key" ] || { echo "Error: Key required."; return 1; }

        if grep -qE "^[[:space:]]*$key=" "$CONFIGFILE"; then
            # Key already present. An empty value means "keep what's there"
            # (a manual ini edit or a previous env override is preserved).
            if [ -n "$new_value" ]; then
                # Escape characters that are special in a sed replacement
                # (&, | and backslash) so arbitrary values survive intact.
                escaped=$(printf '%s' "$new_value" | sed -e 's/[\\&|]/\\&/g')
                sed -i.bak -E "s|^([[:space:]]*$key=).*|\1$escaped|" "$CONFIGFILE"
            fi
        elif [ -n "$new_value" ]; then
            # Key absent — only append when we have a value, so we never
            # write bare keys like "OwnerId=" with no value.
            echo "$key=$new_value" >> "$CONFIGFILE"
        fi
    }

    # Echo a generated default only when the key is missing from the ini
    # (i.e. a fresh install). When the key exists, echo nothing so set_key
    # preserves the existing value instead of clobbering it with a new
    # timestamp/random value on every container restart.
    default_echo() {
        if grep -qE "^[[:space:]]*$1=" "$CONFIGFILE"; then
            echo ""
        else
            echo "$2"
        fi
    }

    create_config_file() {
        echo "Config file '$CONFIGFILE' not found, creating."
        mkdir -p "$(dirname "$CONFIGFILE")" && touch "$CONFIGFILE"

        # Add metadata and section header
        echo ";METADATA=(Diff=true, UseCommands=true)" >> "$CONFIGFILE"
        echo "[/Script/Dominion.DedicatedServerSettings]" >> "$CONFIGFILE"
    }

    # Config.presence
    if [[ ! -f "$CONFIGFILE" ]]; then create_config_file; fi

    set_key "OwnerId"          "${OWNER_ID}"
    set_key "ServerGuid"       "${SERVER_GUID}"
    set_key "AdminPassword"    "${ADMIN_PASSWORD:-$(default_echo AdminPassword "$(openssl rand -hex 16 | tr 'a-f' 'A-F')")}"
    set_key "ServerName"       "${SERVER_NAME:-$(default_echo ServerName "Server-$(date +%s)")}"
    set_key "DefaultWorldName" "${DEFAULT_WORLD_NAME:-$(default_echo DefaultWorldName "World-$(date +%s)")}"
    set_key "WorldPassword"    "${WORLD_PASSWORD}"

    # private function cleanup
    unset -f set_key
    unset -f default_echo
    unset -f create_config_file
}

# --- START SERVER ---
start_server() {
    local binary="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
    if [ ! -f "$binary" ]; then
        log "ERROR: Server binary not found at $binary — cannot start"
        return 1
    fi
    log "=== Starting Dragonwilds Server on port ${SERVER_PORT} ==="
    cd "$SERVERDIR/RSDragonwilds/Binaries/Linux"
    ./RSDragonwildsServer-Linux-Shipping RSDragonwilds -log -Port="${SERVER_PORT}" &
    SERVER_PID=$!
    SERVER_STARTED=$(date +%s)
    local build
    build=$(grep '"buildid"' "$SERVERDIR/steamapps/appmanifest_$APPID.acf" 2>/dev/null | head -n1 | sed 's/.*"\([0-9]*\)".*/\1/')
    send_discord "🟢 Server starting on port ${SERVER_PORT} (build ${build:-unknown})"
    echo "$SERVER_PID" > "$SERVER_PID_FILE"
}

# --- STOP SERVER ---
# This may be called from the update/backup subshells, where the inherited
# $SERVER_PID goes stale after the first maintenance restart and `wait` cannot
# reap a process that is not a child of the current shell. We therefore track
# the live PID in a file and poll for actual process exit (escalating to
# SIGKILL after $SERVER_STOP_TIMEOUT) so callers always wait for the old
# server to fully die before running SteamCMD or a backup.
stop_server() {
    local pid stop_timeout="${SERVER_STOP_TIMEOUT:-120}" waited=0
    pid=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "${SERVER_PID:-}")
    [ -n "$pid" ] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log "=== Stopping server (pid $pid) ==="
    kill "$pid" 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$stop_timeout" ]; then
            log "Server did not stop within ${stop_timeout}s — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# --- CLEAN OLD BACKUPS ---
cleanup_backups() {
    log "=== Cleaning backups older than $BACKUP_RETENTION_DAYS days ==="
    find "$BACKUPDIR" -maxdepth 1 -mindepth 1 -type d -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} \;
}

# --- BACKUP SAVES ---
backup_saves() {
    SAVES_DIR="$SERVERDIR/RSDragonwilds/Saved/SaveGames"
    if [ -d "$SAVES_DIR" ]; then
        TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
        BACKUP_SAVE="$BACKUPDIR/SaveGames_$TIMESTAMP"
        if cp -r "$SAVES_DIR" "$BACKUP_SAVE"; then
            log "SaveGames backed up to $BACKUP_SAVE ($(du -sh "$BACKUP_SAVE" | cut -f1))"
        else
            log "ERROR: SaveGames backup failed"
            send_discord "❌ Backup FAILED — check disk space on the server volume."
        fi
    fi
}

# --- PARSE ANY SCHEDULE TIME (12-hour format) ---
# Usage: parse_schedule_time "3:00 AM"  →  "3 0"
#        parse_schedule_time "4:30 PM"  →  "16 30"
parse_schedule_time() {
    local time_str="$1"
    local hour minute ampm

    hour=$(echo "$time_str" | sed 's/^\([0-9]*\):.*/\1/' | tr -d ' ')
    minute=$(echo "$time_str" | sed 's/.*:\([0-9]*\).*/\1/' | tr -d ' ')
    ampm=$(echo "$time_str" | sed 's/.*\([AP]M\).*/\1/' | tr -d ' ')

    # Force base-10 so leading zeros (e.g. "09") don't trigger octal errors in arithmetic
    hour=$((10#$hour))
    minute=$((10#$minute))

    if [ "$ampm" = "PM" ] && [ "$hour" -ne 12 ]; then
        hour=$((hour + 12))
    elif [ "$ampm" = "AM" ] && [ "$hour" -eq 12 ]; then
        hour=0
    fi

    echo "$hour $minute"
}

# --- CHECK IF SERVER IS IDLE (no players + 360s since last activity) ---
# Returns 0 (true) if idle, 1 (false) if not
is_idle() {
    local now last_activity idle player_count
    now=$(date +%s)
    last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
    idle=$((now - last_activity))
    player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
    [ "$idle" -ge "$PLAYER_STALE_TIMEOUT" ] && player_count=0

    if [ "$player_count" -eq 0 ] && [ "$idle" -ge "$IDLE_WAIT" ]; then
        return 0
    fi
    return 1
}

# --- WAIT UNTIL IDLE (blocking, checks every 60s, logs reason) ---
wait_for_idle() {
    local label="${1:-Operation}"
    while true; do
        local now last_activity idle player_count
        now=$(date +%s)
        last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
        idle=$((now - last_activity))
        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
        [ "$idle" -ge "$PLAYER_STALE_TIMEOUT" ] && player_count=0

        if [ "$player_count" -eq 0 ] && [ "$idle" -ge "$IDLE_WAIT" ]; then
            log "$label: Server is idle. Proceeding."
            return 0
        fi

        if [ "$player_count" -gt 0 ]; then
            log "$label: $player_count player(s) online — waiting for them to leave before proceeding..."
        else
            log "$label: Waiting for idle timeout... (${idle}s / ${IDLE_WAIT}s elapsed)"
        fi
        sleep 60
    done
}

# --- RUN DAILY BACKUP ---
run_daily_backup() {
    log "=== Scheduled daily backup time reached ==="
    send_discord "📦 Scheduled daily backup starting — waiting for server idle..."

    wait_for_idle "Daily Backup"

    log "=== Stopping server for daily backup ==="
    touch "$BACKUP_IN_PROGRESS_FILE"
    stop_server

    log "=== Backing up SaveGames ==="
    backup_saves
    cleanup_backups

    send_discord "✅ Daily backup completed — restarting server."

    # Release the main loop to restart the server
    rm -f "$BACKUP_IN_PROGRESS_FILE"
}

# --- RUN UPDATE ---
run_update() {
    log "=== Backing up config ==="
    [ -f "$CONFIGFILE" ] && cp "$CONFIGFILE" "$BACKUPDIR/DedicatedServer.ini"

    log "=== Checking for updates ==="
    LOCAL_BUILD=$(grep '"buildid"' "$SERVERDIR/steamapps/appmanifest_$APPID.acf" 2>/dev/null | head -n1 | sed 's/.*"\([0-9]*\)".*/\1/')
    LOCAL_BUILD="${LOCAL_BUILD:-unknown}"
    log "Local build: $LOCAL_BUILD"

    # app_info_update 1 forces a fresh fetch; without it steamcmd serves cached
    # appinfo and never sees new builds. awk reads buildid from the "public"
    # branch only (the first "buildid" in the dump may belong to another branch).
    REMOTE_BUILD=$(/home/ubuntu/steamcmd/steamcmd.sh +login anonymous +app_info_update 1 +app_info_print $APPID +quit \
        | awk '/"public"/{p=1} p && /"buildid"/{gsub(/[^0-9]/,"",$2); print $2; exit}')
    log "Remote build: $REMOTE_BUILD"

    if [ -z "$REMOTE_BUILD" ]; then
        log "Could not determine remote build ID — skipping update check"
        return
    fi

    LAST_APPLIED_BUILD=$(cat "$LAST_APPLIED_BUILD_FILE" 2>/dev/null || echo "")

    if [ "$LOCAL_BUILD" = "$REMOTE_BUILD" ]; then
        log "Server is up to date (build $LOCAL_BUILD) — no update needed"
        return
    fi

    if [ "$REMOTE_BUILD" = "$LAST_APPLIED_BUILD" ] && [ "$LOCAL_BUILD" = "$LAST_APPLIED_BUILD" ]; then
        log "Update to build $REMOTE_BUILD was already applied — skipping"
        return
    fi

    log "Update available (local: $LOCAL_BUILD → remote: $REMOTE_BUILD) — running SteamCMD"
    send_discord "🛠️ Dragonwilds server update detected (build $REMOTE_BUILD) — waiting for idle before updating..."

    wait_for_idle "Update"
    send_discord "⬇️ Server idle — applying update to build $REMOTE_BUILD now."

    # Signal the main loop that the server is being stopped intentionally so it
    # waits for us to finish rather than exiting the container (which would
    # SIGKILL this subshell before steamcmd completes and we can write files).
    touch "$UPDATE_IN_PROGRESS_FILE"

    stop_server

    UPDATE_SUCCEEDED=false
    for i in {1..5}; do
        log "SteamCMD attempt $i..."
        /home/ubuntu/steamcmd/steamcmd.sh \
            +force_install_dir "$SERVERDIR" \
            +login anonymous \
            +app_update $APPID validate \
            +quit && UPDATE_SUCCEEDED=true && break
        log "SteamCMD failed, retrying in 5 seconds..."
        sleep 5
    done

    log "=== Restoring config ==="
    [ -f "$BACKUPDIR/DedicatedServer.ini" ] && cp "$BACKUPDIR/DedicatedServer.ini" "$CONFIGFILE"

    if [ "$UPDATE_SUCCEEDED" = "true" ]; then
        echo "$REMOTE_BUILD" > "$LAST_APPLIED_BUILD_FILE"
        log "Recorded applied build: $REMOTE_BUILD"
    else
        log "WARNING: SteamCMD failed after 5 attempts — update may be incomplete"
        send_discord "❌ Update to build $REMOTE_BUILD FAILED after 5 attempts — restarting on existing files, will retry next check."
    fi

    if [ "$BACKUP_AFTER_UPDATE" = "true" ]; then
        log "=== Backing up SaveGames (post-update) ==="
        backup_saves
        cleanup_backups
    else
        log "=== Post-update backup skipped (BACKUP_AFTER_UPDATE=false) ==="
    fi

    send_discord "✅ Dragonwilds server updated to build $REMOTE_BUILD — restarting server."

    # Release the main loop to restart the server
    rm -f "$UPDATE_IN_PROGRESS_FILE"
}

# --- MONITOR PLAYERS ---
# Runs in a subshell (background). Uses temp files for shared state since
# associative arrays cannot cross subshell boundaries.
monitor_players() {
    local LOG="$SERVERDIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log"
    local PLAYERS_FILE="$SERVERDIR/.online_players"

    log "Waiting for server log file..."
    while [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; do
        sleep 1
    done
    sleep 2

    local LAST_READ
    if [ -f "$SERVER_RESTART_FILE" ]; then
        rm -f "$SERVER_RESTART_FILE"
        log "Server restarted — resetting log position to 0"
        LAST_READ=0
    else
        LAST_READ=$(wc -l < "$LOG")
    fi

    > "$PLAYERS_FILE"
    echo "0" > "$PLAYER_COUNT_FILE"

    if [ -f "$LAST_ACTIVITY_FILE" ]; then
        : # keep existing timestamp
    else
        date +%s > "$LAST_ACTIVITY_FILE"
    fi

    local log_inode
    log_inode=$(stat -c %i "$LOG")
    log "Player monitor started at line $LAST_READ (inode: $log_inode)"

    while true; do
        local current_inode
        current_inode=$(stat -c %i "$LOG" 2>/dev/null || echo "$log_inode")

        if [ "$current_inode" != "$log_inode" ]; then
            log "Log file recreated (server restarted) — resetting monitor"
            LAST_READ=0
            log_inode=$current_inode
            date +%s > "$LAST_ACTIVITY_FILE"
            > "$PLAYERS_FILE"
            echo "0" > "$PLAYER_COUNT_FILE"
        fi

        local TOTAL_LINES NEW_LINES
        TOTAL_LINES=$(wc -l < "$LOG")
        NEW_LINES=$((TOTAL_LINES - LAST_READ))

        if [ "$NEW_LINES" -gt 0 ]; then
            local line player
            while IFS= read -r line; do
                if [[ "$line" == *"LogNet: Join succeeded:"* ]]; then
                    player=$(echo "$line" | grep -oE 'LogNet: Join succeeded: ([^[:space:]]+)' | sed 's/.*LogNet: Join succeeded: //')
                    if [ -n "$player" ]; then
                        grep -qxF "$player" "$PLAYERS_FILE" 2>/dev/null || echo "$player" >> "$PLAYERS_FILE"
                        local count
                        count=$(wc -l < "$PLAYERS_FILE")
                        echo "$count" > "$PLAYER_COUNT_FILE"
                        date +%s > "$LAST_ACTIVITY_FILE"
                        log "Player connected: $player (online: $count)"
                        send_discord "🟢 Player connected: $player"
                    fi
                fi

                # "Player Removed from session [<id>]-[<name>]" uses the same name as
                # the join line (ClientRequestDisconnect only has the character
                # name) and also fires when a client times out or crashes.
                if [[ "$line" == *"LogDomMatcherSession: Player Removed from session"* ]]; then
                    player=$(echo "$line" | sed -nE 's/.*Player Removed from session \[[^]]*\]-\[([^]]*)\].*/\1/p')
                    # Fall back to dropping the oldest entry if the name is
                    # unknown so every leave line frees exactly one slot.
                    # (grep -v exits 1 when nothing is left; "|| true" keeps set -e from
                    # killing this monitor when the last player leaves)
                    if [ -n "$player" ] && grep -qxF "$player" "$PLAYERS_FILE"; then
                        { grep -vxF "$player" "$PLAYERS_FILE" || true; } > "$PLAYERS_FILE.tmp"; mv "$PLAYERS_FILE.tmp" "$PLAYERS_FILE"
                    else
                        sed -i '1d' "$PLAYERS_FILE"
                    fi
                    local count
                    count=$(wc -l < "$PLAYERS_FILE")
                    echo "$count" > "$PLAYER_COUNT_FILE"
                    date +%s > "$LAST_ACTIVITY_FILE"
                    log "Player disconnected: ${player:-unknown} (online: $count)"
                    send_discord "🔴 Player disconnected: ${player:-unknown}"
                fi
            done < <(tail -n "$NEW_LINES" "$LOG")
            LAST_READ=$TOTAL_LINES
        fi

        sleep "$PLAYER_CHECK_INTERVAL"
    done &
}

# --- GRACEFUL SHUTDOWN ---
# docker stop sends SIGTERM to this script (PID 1). Without a handler the game
# never sees it and is SIGKILLed mid-save once Docker's grace period expires.
shutdown() {
    trap '' TERM INT
    log "=== Container stop requested — shutting down server ==="
    send_discord "🛑 Server shutting down (container stop)."
    kill $(jobs -p) 2>/dev/null || true
    stop_server
    log "=== Shutdown complete ==="
    exit 0
}
trap shutdown TERM INT

# --- MAIN ---
echo "" >> "$LOGFILE"
echo "===== Container start $(date '+%Y-%m-%d %H:%M:%S') =====" >> "$LOGFILE"
log "=== Starting Dragonwilds Server ==="
log "Config: AUTO_UPDATE=$ENABLE_AUTO_UPDATE, UPDATE_TIME=${UPDATE_TIME}s, BACKUP_AFTER_UPDATE=$BACKUP_AFTER_UPDATE, BACKUP_DAILY=$BACKUP_DAILY, BACKUP_TIME=$BACKUP_TIME"

# Remove any stale maintenance flags left by a previously killed container
rm -f "$UPDATE_IN_PROGRESS_FILE" "$BACKUP_IN_PROGRESS_FILE" "$SERVER_PID_FILE"

# Install server files if not present (first run or missing binary)
BINARY="$SERVERDIR/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
if [ ! -f "$BINARY" ]; then
    log "Server binary not found — running initial SteamCMD install"
    install_or_verify_server
fi

prepare_dedicated_server_ini
if ! grep -qE "^[[:space:]]*OwnerId=[^[:space:]]+" "$CONFIGFILE"; then
    log "⚠️  WARNING: OwnerId is not set in DedicatedServer.ini — no player will have admin on this server."
    log "            Set OWNER_ID in your .env (your in-game \"My Player Id\") and restart the container."
fi
start_server
monitor_players

# =============================================================================
# UPDATE LOOP — separate subprocess
# Checks for updates every UPDATE_TIME seconds (no once-per-day cap).
# =============================================================================
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
    log "Auto-update enabled — checking every ${UPDATE_TIME}s"
    (
        # Container restarts (crashes, redeploys) must not push the first check
        # a full UPDATE_TIME away, or a crash-looping server never updates.
        sleep "${UPDATE_INITIAL_DELAY:-120}"
        while true; do
            log "=== Running scheduled update check ==="
            run_update
            sleep "$UPDATE_TIME"
        done
    ) &
    UPDATE_LOOP_PID=$!
fi

# =============================================================================
# BACKUP LOOP — separate subprocess
# Polls every POLL_INTERVAL seconds and fires once per day at BACKUP_TIME.
# =============================================================================
if [ "$BACKUP_DAILY" = "true" ]; then
    log "Daily backup scheduled at $BACKUP_TIME (idle required: ${IDLE_WAIT}s)"
    (
        while true; do
            today=$(date +%Y-%m-%d)
            last_backup_date=$(cat "$LAST_BACKUP_DATE_FILE" 2>/dev/null || echo "")

            if [ "$today" != "$last_backup_date" ]; then
                current_hour=$(date +%-H)
                current_minute=$(date +%-M)
                current_total=$((current_hour * 60 + current_minute))

                backup_parsed=$(parse_schedule_time "$BACKUP_TIME")
                backup_hour=$(echo "$backup_parsed" | cut -d' ' -f1)
                backup_minute=$(echo "$backup_parsed" | cut -d' ' -f2)
                backup_total=$((backup_hour * 60 + backup_minute))

                if [ "$current_total" -ge "$backup_total" ]; then
                    if is_idle; then
                        run_daily_backup
                        echo "$today" > "$LAST_BACKUP_DATE_FILE"
                    else
                        player_count=$(cat "$PLAYER_COUNT_FILE" 2>/dev/null || echo "0")
                        if [ "$player_count" -gt 0 ]; then
                            log "Backup: $player_count player(s) online — retrying in ${POLL_INTERVAL}s..."
                        else
                            now=$(date +%s)
                            last_activity=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo "$now")
                            idle=$((now - last_activity))
                            log "Backup: Waiting for idle timeout (${idle}s / ${IDLE_WAIT}s) — retrying in ${POLL_INTERVAL}s..."
                        fi
                    fi
                fi
            fi

            sleep "$POLL_INTERVAL"
        done
    ) &
    BACKUP_LOOP_PID=$!
fi

# Keep the container alive.  When the server is stopped intentionally (update
# or backup), the background subshell sets an in-progress flag before calling
# stop_server.  We detect that here, wait for the operation to finish, then
# restart the server — rather than letting the container exit and getting
# SIGKILL'd mid-steamcmd by the kernel (PID 1 death kills the whole namespace).
FAST_CRASHES=0
while true; do
    EXIT_CODE=0
    wait "$SERVER_PID" || EXIT_CODE=$?

    if [ -f "$UPDATE_IN_PROGRESS_FILE" ] || [ -f "$BACKUP_IN_PROGRESS_FILE" ]; then
        log "Server stopped for scheduled maintenance — waiting for completion..."
        MAINTENANCE_WAIT=0
        while [ -f "$UPDATE_IN_PROGRESS_FILE" ] || [ -f "$BACKUP_IN_PROGRESS_FILE" ]; do
            sleep 5
            MAINTENANCE_WAIT=$((MAINTENANCE_WAIT + 5))
            if [ "$MAINTENANCE_WAIT" -ge 3600 ]; then
                log "WARNING: Maintenance appears stuck after 1h — forcing restart"
                rm -f "$UPDATE_IN_PROGRESS_FILE" "$BACKUP_IN_PROGRESS_FILE"
                break
            fi
        done
        log "Maintenance complete — restarting server"
        touch "$SERVER_RESTART_FILE"
        start_server
        # monitor_players inode watch handles the new log automatically
    else
        # Restart in place: exiting the container resets the update/backup
        # timers and drops idle state. Give up (let docker restart us) only
        # if it crash-loops.
        if [ $(( $(date +%s) - SERVER_STARTED )) -lt 120 ]; then
            FAST_CRASHES=$((FAST_CRASHES + 1))
        else
            FAST_CRASHES=0
        fi
        if [ "$FAST_CRASHES" -ge 5 ]; then
            log "Server crash-looping (5 exits within 2 min of start) — container stopping"
            send_discord "🚨 Server is crash-looping (5 exits within 2 min of start, last code $EXIT_CODE) — giving up; Docker will restart the container."
            break
        fi
        log "Server exited unexpectedly (code $EXIT_CODE) — restarting in 15s (fast crashes: $FAST_CRASHES)"
        send_discord "⚠️ Server crashed (exit code $EXIT_CODE$([ "$EXIT_CODE" = 137 ] && echo ', killed — possibly out of memory')) — restarting in 15s."
        sleep 15
        : > "$SERVERDIR/.online_players"; echo 0 > "$PLAYER_COUNT_FILE"
        touch "$SERVER_RESTART_FILE"
        start_server
    fi
done