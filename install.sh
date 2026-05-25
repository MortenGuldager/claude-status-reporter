#!/usr/bin/env bash
# install.sh — install claude-status-reporter under /opt and drop the
# systemd user unit into /etc/systemd/user/. Run as root.
#
# This only stages the files. Each user enables the service for themselves
# with /opt/claude-status-reporter/bin/user-setup.sh — no further root
# involvement required.
#
# Idempotent: re-running overwrites the installed files. Per-user config
# under ~/.config/claude-status-reporter/ is never touched.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX=/opt/claude-status-reporter

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "install.sh must be run as root (try: sudo $0)" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "install.sh: systemctl not found; this installer targets systemd-on-Linux." >&2
    exit 1
fi

install -d -m 0755 "$PREFIX/bin"
install -m 0755 "$HERE/claude-status-reporter.sh" "$PREFIX/bin/claude-status-reporter.sh"
install -m 0755 "$HERE/user-setup.sh"             "$PREFIX/bin/user-setup.sh"
install -m 0644 "$HERE/config.env.example"        "$PREFIX/config.env.example"
install -m 0644 "$HERE/README.md"                 "$PREFIX/README.md"

install -d -m 0755 /etc/systemd/user
install -m 0644 "$HERE/claude-status-reporter.service" \
    /etc/systemd/user/claude-status-reporter.service

# Tell already-running user managers about the new unit. Safe no-op when
# systemd isn't live (e.g. during an offline image build).
if [ -d /run/systemd/system ]; then
    systemctl --global daemon-reload 2>/dev/null || true
fi

cat <<EOF
Installed:
  $PREFIX/
  /etc/systemd/user/claude-status-reporter.service

Each user can now enable the reporter for themselves, without sudo:

    $PREFIX/bin/user-setup.sh

That script enables linger, drops a default config into
~/.config/claude-status-reporter/config.env, and starts the service.
EOF
