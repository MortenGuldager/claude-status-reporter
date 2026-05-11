#!/usr/bin/env bash
# install.sh — install claude-status-reporter into the current
# systemd-on-Linux environment. Run as root.
#
# Idempotent: re-running overwrites the script and unit file but leaves
# /etc/claude-status-reporter.env in place if you have already customised it.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "install.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "install.sh: systemctl not found; this installer targets systemd-on-Linux." >&2
    exit 1
fi

install -m 0755 "$HERE/claude-status-reporter.sh" \
    /usr/local/bin/claude-status-reporter.sh
install -m 0644 "$HERE/claude-status-reporter.service" \
    /etc/systemd/system/claude-status-reporter.service

if [ ! -f /etc/claude-status-reporter.env ]; then
    install -m 0644 "$HERE/claude-status-reporter.env.example" \
        /etc/claude-status-reporter.env
    echo "Wrote default config to /etc/claude-status-reporter.env (backend=stdout)."
fi

systemctl daemon-reload

# systemd isn't always running when the installer is invoked — e.g. during
# an offline image build. Enable unconditionally; only start when systemd
# is actually live.
if [ -d /run/systemd/system ]; then
    systemctl enable --now claude-status-reporter.service
    echo "Service enabled and started."
    echo "Tail logs: journalctl -u claude-status-reporter -f"
else
    systemctl enable claude-status-reporter.service
    echo "Service enabled. systemd is not running here, so it was not started."
    echo "It will start on next boot."
fi
