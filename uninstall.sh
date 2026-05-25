#!/usr/bin/env bash
# uninstall.sh — remove claude-status-reporter system files.
# Run as root.
#
# Does NOT touch per-user state: ~/.config/claude-status-reporter/ and
# each user's `systemctl --user` enable-state are left alone. Users who
# want a clean removal should run, as themselves:
#
#   systemctl --user disable --now claude-status-reporter
#   rm -rf ~/.config/claude-status-reporter

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "uninstall.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

rm -f /etc/systemd/user/claude-status-reporter.service
rm -rf /opt/claude-status-reporter

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl --global daemon-reload 2>/dev/null || true
fi

echo "Removed /opt/claude-status-reporter and the systemd user unit."
echo "Per-user config under ~/.config/claude-status-reporter/ was left in place."
