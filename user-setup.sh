#!/usr/bin/env bash
# user-setup.sh — one-shot setup for a single user. Run as that user (no sudo).
#
#   /opt/claude-status-reporter/bin/user-setup.sh
#
# Steps performed:
#   1. loginctl enable-linger     (so the service runs without an active login)
#   2. Drop a default config at ~/.config/claude-status-reporter/config.env
#      if one isn't already there.
#   3. systemctl --user enable --now claude-status-reporter
#
# Idempotent. Safe to re-run; existing config is never overwritten.

set -euo pipefail

PREFIX=/opt/claude-status-reporter
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-status-reporter"
CONFIG_FILE="$CONFIG_DIR/config.env"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "user-setup.sh: run as your own user, not root." >&2
    exit 1
fi

if [ ! -f /etc/systemd/user/claude-status-reporter.service ]; then
    echo "user-setup.sh: claude-status-reporter is not installed system-wide." >&2
    echo "Ask the administrator to run install.sh first." >&2
    exit 1
fi

if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
    echo "Enabling linger so the service survives logout..."
    # On systemd >= 249 this is allowed for self without sudo via polkit.
    loginctl enable-linger
fi

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    install -m 0600 "$PREFIX/config.env.example" "$CONFIG_FILE"
    echo "Wrote default config to $CONFIG_FILE (backend=stdout)."
else
    echo "Config already exists at $CONFIG_FILE — left untouched."
fi

systemctl --user daemon-reload
systemctl --user enable --now claude-status-reporter.service

cat <<EOF

Done.
  Tail logs:      journalctl --user -u claude-status-reporter -f
  Edit config:    \$EDITOR $CONFIG_FILE
  After editing:  systemctl --user restart claude-status-reporter
EOF
