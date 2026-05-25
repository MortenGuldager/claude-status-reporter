#!/usr/bin/env bash
# claude-status-reporter — publishes the status of ~/.claude/sessions/*.json
# via a configurable backend.
#
# Driven by inotify on the sessions directory: a payload is sent on every
# change, plus a keep-alive every REPORTER_KEEPALIVE seconds (default 60)
# so a subscriber that comes online late still learns the current state.
#
# Payload: {"slots":{"<sessionId>":"#rrggbb", ...}}.
# Keys are sorted for deterministic change detection. The value is the
# RGB color that subscribers should render for that slot — the status →
# color mapping happens here, not on the subscriber, so the same display
# hardware can be reused for non-Claude publishers with their own palettes.
#
# Settings come from ~/.config/claude-status-reporter/config.env
# (or $REPORTER_CONFIG_FILE).

set -u

CONFIG_FILE="${REPORTER_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-status-reporter/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

REPORTER_BACKEND="${REPORTER_BACKEND:-stdout}"
REPORTER_KEEPALIVE="${REPORTER_KEEPALIVE:-60}"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

# Status → color mapping. Defaults match the previous indicator firmware
# palette so an existing deployment looks identical without any config change.
REPORTER_COLOR_BUSY="${REPORTER_COLOR_BUSY:-#ff0000}"
REPORTER_COLOR_WAITING="${REPORTER_COLOR_WAITING:-#ffb400}"
REPORTER_COLOR_IDLE="${REPORTER_COLOR_IDLE:-#00dc00}"
REPORTER_COLOR_INFO="${REPORTER_COLOR_INFO:-#00dc00}"
REPORTER_COLOR_UNKNOWN="${REPORTER_COLOR_UNKNOWN:-#3c3c3c}"

mkdir -p "$SESSIONS_DIR"

# --- Backends ---------------------------------------------------------------

publish_none() { :; }

publish_stdout() {
    printf '%s\n' "$1"
}

publish_file() {
    local path="${REPORTER_FILE_PATH:-/var/log/claude-status.jsonl}"
    printf '%s\n' "$1" >> "$path"
}

publish_http() {
    local url="${REPORTER_HTTP_URL:-}"
    if [ -z "$url" ]; then
        echo "reporter: REPORTER_HTTP_URL is empty" >&2
        return
    fi
    curl -sf --max-time 10 \
        -H "Content-Type: application/json" \
        -X POST -d "$1" "$url" > /dev/null || true
}

publish_mqtt() {
    local host="${REPORTER_MQTT_HOST:-}"
    local port="${REPORTER_MQTT_PORT:-1883}"
    local topic="${REPORTER_MQTT_TOPIC:-}"
    local user="${REPORTER_MQTT_USER:-}"
    local pass="${REPORTER_MQTT_PASS:-}"
    if [ -z "$host" ] || [ -z "$topic" ]; then
        echo "reporter: REPORTER_MQTT_HOST and REPORTER_MQTT_TOPIC must be set" >&2
        return
    fi
    # -r: retained, so late subscribers get the last payload immediately.
    local args=(-h "$host" -p "$port" -t "$topic" -m "$1" -q 0 -r)
    [ -n "$user" ] && args+=(-u "$user")
    [ -n "$pass" ] && args+=(-P "$pass")
    mosquitto_pub "${args[@]}" 2>/dev/null || true
}

publish() {
    case "$REPORTER_BACKEND" in
        none)   publish_none   "$1" ;;
        stdout) publish_stdout "$1" ;;
        file)   publish_file   "$1" ;;
        http)   publish_http   "$1" ;;
        mqtt)   publish_mqtt   "$1" ;;
        *)      echo "reporter: unknown backend '$REPORTER_BACKEND'" >&2 ;;
    esac
}

# --- Status computation -----------------------------------------------------

compute_status() {
    local slots='{}'
    shopt -s nullglob
    local files=("$SESSIONS_DIR"/*.json)
    shopt -u nullglob
    if [ "${#files[@]}" -gt 0 ]; then
        # -S sorts object keys so dedup compares are stable.
        slots="$(jq -sSc \
            --arg busy    "$REPORTER_COLOR_BUSY" \
            --arg waiting "$REPORTER_COLOR_WAITING" \
            --arg idle    "$REPORTER_COLOR_IDLE" \
            --arg info    "$REPORTER_COLOR_INFO" \
            --arg unknown "$REPORTER_COLOR_UNKNOWN" \
            'def color(s): {busy:$busy, waiting:$waiting, idle:$idle, info:$info}[s] // $unknown;
             map({(.sessionId // "unknown"): color(.status // "unknown")}) | add // {}' \
            "${files[@]}" 2>/dev/null || echo '{}')"
    fi
    printf '%s' "$slots"
}

emit() {
    local payload
    payload="$(jq -nc --argjson s "$1" '{slots:$s}')"
    publish "$payload"
}

# --- Main loop --------------------------------------------------------------

last=""
current="$(compute_status)"
emit "$current"
last="$current"

while true; do
    # inotifywait exits 0 on event, 2 on timeout. Watch the directory so we
    # also catch creates/deletes of session files, not just modifications.
    if inotifywait -qq -t "$REPORTER_KEEPALIVE" \
            -e close_write,create,delete,move \
            "$SESSIONS_DIR" 2>/dev/null; then
        current="$(compute_status)"
        if [ "$current" != "$last" ]; then
            emit "$current"
            last="$current"
        fi
    else
        # Keep-alive: re-publish current state with a fresh timestamp.
        current="$(compute_status)"
        emit "$current"
        last="$current"
    fi
done
