#!/usr/bin/env bash
# claude-status-reporter — publishes the status of every Claude Code
# session's *.json via a configurable backend.
#
# Two session layouts are scanned and unioned, so this works whether you run
# one Claude login or several:
#   - the single default config dir, CLAUDE_DEFAULT_DIR/sessions/*.json
#     (CLAUDE_CONFIG_DIR if set, else ~/.claude — the common case);
#   - a multi-account tree, ~/.claudes/<account>/sessions/*.json, where each
#     account dir is its own CLAUDE_CONFIG_DIR kept side by side.
# Sessions are de-duplicated by sessionId across both.
#
# Driven by inotify on those directories: a payload is sent on every
# change, plus a keep-alive every REPORTER_KEEPALIVE seconds (default 60)
# so a subscriber that comes online late still learns the current state.
# New accounts (and the default sessions/ dir) appearing at runtime are
# picked up automatically.
#
# After an event the script waits REPORTER_SETTLE seconds (default 1) and
# only then reads state, so a burst of changes collapses into a single
# read. Very short-lived sessions that appear and vanish within the settle
# window never get reported, because the post-settle read sees the final
# (unchanged) state and the existing dedup suppresses the emit.
#
# Payload: {"slots":{"<sessionId>":"#rrggbb", ...}}.
# Keys are sorted for deterministic change detection. The value is the
# RGB color that subscribers should render for that slot — the status →
# color mapping happens here, not on the subscriber, so the same display
# hardware can be reused for non-Claude publishers with their own palettes.
#
# The stdout/file/http backends emit that aggregate blob verbatim. The mqtt
# backend does NOT: it explodes the blob into one retained topic per session
# (<root>/<node>/<sessionId>, payload "#rrggbb"), so each session is an
# independent retained message. <node> identifies this reporter and defaults
# to a non-reversible hash of the hostname so a sandbox/container name — which
# can reveal the project being worked on — never reaches the broker; see the
# MQTT identity section below. Retained only stores one message per topic, so
# a single shared topic could never hold more than one session's state for a
# late subscriber — splitting them is what makes retained correct. A session
# that ends is cleared with an empty retained message (a tombstone, instant
# off downstream), and every live publish carries an MQTT-5
# message-expiry-interval so a reporter that dies without tombstoning still has
# its sessions swept from the broker's retained store automatically. See
# publish_mqtt_slots.
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
# Seconds to wait after an inotify event before reading state, to debounce
# bursts and let very short-lived sessions disappear before they are read.
# Set to 0 to read immediately (the pre-debounce behavior).
REPORTER_SETTLE="${REPORTER_SETTLE:-1}"
# (mqtt backend only) Seconds the broker keeps a session's retained message
# without a refresh, via the MQTT-5 message-expiry-interval. Each keep-alive
# republishes live sessions and so resets this clock, so it only ever fires
# for a reporter that has gone silent — the broker then drops the stale
# retained message on its own, even for subscribers that connect afterwards.
# Must exceed REPORTER_KEEPALIVE; default 3× gives a comfortable margin.
REPORTER_STATUS_EXPIRY="${REPORTER_STATUS_EXPIRY:-$(( REPORTER_KEEPALIVE * 3 ))}"
# Parent directory holding one subdirectory per Claude account, each a
# CLAUDE_CONFIG_DIR with its own sessions/ dir. This is the multi-account
# layout used on a host that keeps several logins side by side.
CLAUDE_HOMES_DIR="${CLAUDE_HOMES_DIR:-$HOME/.claudes}"
# The single config dir Claude Code uses when run normally: $CLAUDE_CONFIG_DIR
# if set, else ~/.claude. Its sessions/ are scanned IN ADDITION to the
# multi-account layout, so the reporter works out of the box whether you keep
# one login at ~/.claude (the common case — e.g. inside a sandbox) or several
# under ~/.claudes/<account>. Sessions are de-duplicated by sessionId, so a dir
# that appears in both layouts is counted once.
CLAUDE_DEFAULT_DIR="${CLAUDE_DEFAULT_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"

# Status → color mapping. Defaults match the previous indicator firmware
# palette so an existing deployment looks identical without any config change.
REPORTER_COLOR_BUSY="${REPORTER_COLOR_BUSY:-#ff0000}"
REPORTER_COLOR_WAITING="${REPORTER_COLOR_WAITING:-#ffb400}"
REPORTER_COLOR_IDLE="${REPORTER_COLOR_IDLE:-#00dc00}"
REPORTER_COLOR_INFO="${REPORTER_COLOR_INFO:-#00dc00}"
REPORTER_COLOR_UNKNOWN="${REPORTER_COLOR_UNKNOWN:-#3c3c3c}"

# --- MQTT identity ----------------------------------------------------------
# The mqtt backend publishes under a shared root plus a per-reporter identity
# segment, as <root>/<node>/<sessionId>. REPORTER_MQTT_TOPIC is the ROOT
# (default claude_info/status, matching the claude-top viewer's ACL) and is
# always treated as a root: the reporter appends <node> itself, so never bake
# a machine/identity name into REPORTER_MQTT_TOPIC.
#
# <node> is REPORTER_NODE; left unset it defaults to a NON-REVERSIBLE hash of
# the hostname. This is the privacy boundary: a claude-sandbox container is
# named after the project it was launched from (csb-<project>-<id>), so a raw
# hostname on the broker would leak what you are working on to anyone with read
# access to claude_info/#. The hash still gives each reporter a stable, distinct
# subtree without revealing the name. Override REPORTER_NODE with a friendly,
# non-sensitive name where the identity is not secret (e.g. a desk indicator).
REPORTER_MQTT_TOPIC="${REPORTER_MQTT_TOPIC:-claude_info/status}"
REPORTER_NODE="${REPORTER_NODE:-$(hostname | sha256sum | head -c 12)}"
REPORTER_MQTT_BASE="${REPORTER_MQTT_TOPIC%/}/${REPORTER_NODE}"
# A stable client id keeps the broker's connection log free of the default
# mosquitto_pub id, which embeds the hostname. Derived from <node>, so it
# carries no more information than the topic already does.
REPORTER_MQTT_CLIENT_ID="csr-${REPORTER_NODE}-$$"

# Ensure the parent exists so inotifywait can watch it for the first
# account directory to appear, even before any account is set up.
mkdir -p "$CLAUDE_HOMES_DIR"

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

# Remember the colour last published per session topic, so the next emit can
# (a) skip sessions whose colour is unchanged and (b) tombstone the topics of
# sessions that have since vanished. Survives across loop iterations.
declare -A MQTT_PUB_LAST=()

# Publish the slots object as one retained topic per session, the layout that
# makes retained behave: REPORTER_MQTT_TOPIC/<sessionId> = "#rrggbb". $2=1
# forces a republish of every live session (the keep-alive path) to reset each
# retained message's expiry clock; otherwise only changed sessions are sent.
publish_mqtt_slots() {
    local slots="$1" force="${2:-0}"
    local host="${REPORTER_MQTT_HOST:-}"
    local port="${REPORTER_MQTT_PORT:-1883}"
    local base="${REPORTER_MQTT_BASE:-}"
    local user="${REPORTER_MQTT_USER:-}"
    local pass="${REPORTER_MQTT_PASS:-}"
    local expiry="${REPORTER_STATUS_EXPIRY:-180}"
    if [ -z "$host" ] || [ -z "$base" ]; then
        echo "reporter: REPORTER_MQTT_HOST and REPORTER_MQTT_TOPIC must be set" >&2
        return
    fi

    # -V 5: message-expiry-interval is an MQTT-5 property. Subscribers may stay
    # on 3.1.1 — expiry is purely broker-side retained-store housekeeping.
    local -a common=(-h "$host" -p "$port" -V 5 -i "$REPORTER_MQTT_CLIENT_ID")
    [ -n "$user" ] && common+=(-u "$user")
    [ -n "$pass" ] && common+=(-P "$pass")

    local -A cur=()
    local id color pairs
    pairs="$(printf '%s' "$slots" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null)"
    while IFS=$'\t' read -r id color; do
        [ -z "$id" ] && continue
        cur["$id"]="$color"
    done <<< "$pairs"

    # Live sessions: publish the colour retained, with an expiry so the broker
    # forgets it if we go silent. Skip unchanged ones unless forced.
    for id in "${!cur[@]}"; do
        if [ "$force" = 1 ] || [ "${MQTT_PUB_LAST[$id]:-}" != "${cur[$id]}" ]; then
            mosquitto_pub "${common[@]}" -t "$base/$id" -m "${cur[$id]}" -q 0 -r \
                -D publish message-expiry-interval "$expiry" 2>/dev/null || true
        fi
        MQTT_PUB_LAST["$id"]="${cur[$id]}"
    done

    # Vanished sessions: an empty retained message (-n) deletes the broker's
    # retained entry, so no subscriber — present or future — sees the ghost.
    for id in "${!MQTT_PUB_LAST[@]}"; do
        if [ -z "${cur[$id]:-}" ]; then
            mosquitto_pub "${common[@]}" -t "$base/$id" -q 0 -r -n 2>/dev/null || true
            unset 'MQTT_PUB_LAST[$id]'
        fi
    done
}

publish() {
    case "$REPORTER_BACKEND" in
        none)   publish_none   "$1" ;;
        stdout) publish_stdout "$1" ;;
        file)   publish_file   "$1" ;;
        http)   publish_http   "$1" ;;
        *)      echo "reporter: unknown backend '$REPORTER_BACKEND'" >&2 ;;
    esac
}

# --- Status computation -----------------------------------------------------

compute_status() {
    local slots='{}'
    shopt -s nullglob
    # Two layouts, unioned: one sessions dir per account under CLAUDE_HOMES_DIR
    # (~/.claudes/<account>/sessions/), plus the single default config dir
    # (CLAUDE_DEFAULT_DIR/sessions/, normally ~/.claude/sessions/). jq's `add`
    # below de-dups by sessionId, so a session seen in both layouts counts once.
    local files=("$CLAUDE_HOMES_DIR"/*/sessions/*.json "$CLAUDE_DEFAULT_DIR"/sessions/*.json)
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

# $1 = slots object (compute_status output). $2 = force flag, passed through to
# the mqtt backend so the keep-alive path republishes every live session and
# refreshes its retained expiry. The blob backends ignore force — they always
# emit the full current state anyway.
emit() {
    if [ "$REPORTER_BACKEND" = mqtt ]; then
        publish_mqtt_slots "$1" "${2:-0}"
    else
        publish "$(jq -nc --argjson s "$1" '{slots:$s}')"
    fi
}

# Directories inotifywait should watch, printed one per line:
#   - the parent itself, to notice a brand-new account dir being created;
#   - each existing account dir, to notice its sessions/ subdir appearing;
#   - each existing sessions dir, where the actual *.json files change;
#   - the default config dir + its sessions/ (the single-account layout).
# The list is recomputed each loop iteration, so accounts (and their
# sessions dirs) that appear at runtime are picked up on the next wake.
# Only existing dirs are emitted — inotifywait errors on a missing path.
watch_dirs() {
    printf '%s\n' "$CLAUDE_HOMES_DIR"
    shopt -s nullglob
    local d
    for d in "$CLAUDE_HOMES_DIR"/*/; do
        printf '%s\n' "$d"
    done
    for d in "$CLAUDE_HOMES_DIR"/*/sessions/; do
        printf '%s\n' "$d"
    done
    shopt -u nullglob
    # Default single-account layout: watch the config dir (to catch sessions/
    # being created) and its sessions/ dir (where the *.json files change).
    [ -d "$CLAUDE_DEFAULT_DIR" ] && printf '%s\n' "$CLAUDE_DEFAULT_DIR"
    [ -d "$CLAUDE_DEFAULT_DIR/sessions" ] && printf '%s\n' "$CLAUDE_DEFAULT_DIR/sessions"
}

# --- Main loop --------------------------------------------------------------

last=""
current="$(compute_status)"
emit "$current" 1
last="$current"

while true; do
    # Recompute the watch set each iteration so new accounts and their
    # sessions/ dirs are picked up without a restart.
    mapfile -t dirs < <(watch_dirs)
    # inotifywait exits 0 on event, 2 on timeout. Watch the directories so we
    # also catch creates/deletes of session files, not just modifications.
    if inotifywait -qq -t "$REPORTER_KEEPALIVE" \
            -e close_write,create,delete,move \
            "${dirs[@]}" 2>/dev/null; then
        # Settle: absorb a burst of changes (and let a flash-in-the-pan
        # session vanish) before taking a single reading.
        [ "$REPORTER_SETTLE" != 0 ] && sleep "$REPORTER_SETTLE"
        current="$(compute_status)"
        if [ "$current" != "$last" ]; then
            emit "$current"
            last="$current"
        fi
    else
        # Keep-alive: re-publish current state to refresh retained expiry
        # (force=1 so unchanged live sessions are re-sent, not skipped).
        current="$(compute_status)"
        emit "$current" 1
        last="$current"
    fi
done
