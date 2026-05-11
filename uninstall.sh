#!/usr/bin/env bash
# uninstall.sh — remove claude-status-reporter from the current system.
# Leaves /etc/claude-status-reporter.env in place.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "uninstall.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
    if [ -d /run/systemd/system ]; then
        systemctl disable --now claude-status-reporter.service 2>/dev/null || true
    else
        systemctl disable claude-status-reporter.service 2>/dev/null || true
    fi
    systemctl daemon-reload 2>/dev/null || true
fi

rm -f /usr/local/bin/claude-status-reporter.sh
rm -f /etc/systemd/system/claude-status-reporter.service

echo "Removed. /etc/claude-status-reporter.env was left in place."
