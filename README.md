# claude-status-reporter

A small systemd service that watches Claude Code's
`~/.claude/sessions/*.json` and publishes the aggregated session status
to a configurable backend whenever it changes.

Designed to drive a desk indicator, a dashboard, or any other
out-of-process visibility into what your Claude Code instances are
doing right now.

## Payload

```json
{
  "sessions": {
    "c632fc39-11d4-4d63-9dda-74d14706f07b": "busy",
    "9c0dd5a5-1e3d-4af8-b4e5-d43975c9b38e": "idle"
  }
}
```

`sessions` is a map from Claude Code's `sessionId` to its status, built
from `~/.claude/sessions/*.json` (empty object when no sessions exist).
Keys are sorted so a consumer can dedup by comparing payloads
byte-for-byte.

Consumers should key off `sessionId`, not position — two hosts publishing
to the same subscriber will not collide on slot 0. Identifying info
(developer, hostname) is intentionally omitted; encode it in the MQTT
topic or HTTP URL instead.

A keep-alive is also emitted every `REPORTER_KEEPALIVE` seconds
(default 60) so a subscriber that comes online late immediately learns
the current state.

## Backends

- **`none`** — disable publishing entirely.
- **`stdout`** *(default)* — writes to the systemd journal.
  Tail: `journalctl -u claude-status-reporter -f`
- **`file`** — appends one JSON line per report to `REPORTER_FILE_PATH`.
- **`mqtt`** — publishes via `mosquitto_pub` with `-r` (retained), so
  late subscribers immediately receive the last status. Requires
  `mosquitto-clients`.
- **`http`** — POSTs `application/json` to `REPORTER_HTTP_URL`.

### Public MQTT brokers

If you point the MQTT backend at a public broker (`test.mosquitto.org`,
`broker.hivemq.com`, ...), assume your data is visible to the world.
Pick a topic that is not guessable — a UUID is a reasonable default.
For anything you would rather not broadcast, run your own broker.

## Installation

The installer targets any systemd-on-Linux environment. Three common
ways to use it:

### Standalone (any Linux host with systemd)

```sh
git clone https://github.com/MortenGuldager/claude-status-reporter.git
cd claude-status-reporter
sudo ./install.sh
```

Edit `/etc/claude-status-reporter.env` to pick a backend (default is
`stdout`), then:

```sh
sudo systemctl restart claude-status-reporter
journalctl -u claude-status-reporter -f
```

### Inside a WSL2 distro

Same two commands as above, run from inside the distro. Make sure
`/etc/wsl.conf` has systemd enabled:

```ini
[boot]
systemd=true
```

(Restart the distro with `wsl --shutdown` from PowerShell after editing.)

The default user in a standard Ubuntu WSL2 distro is `ubuntu`, which
matches the `User=` in the unit file. If your distro uses a different
default user, either edit
`/etc/systemd/system/claude-status-reporter.service` or override the
user via a systemd drop-in.

### From within claude-sandbox

[claude-sandbox][cs] is an Incus-based sandbox for running Claude Code
on Linux; it fetches and installs this reporter automatically during
`claude-sandbox create`. You do not need to install it separately when
using claude-sandbox.

[cs]: https://github.com/MortenGuldager/claude-sandbox

## Configuration

All settings live in `/etc/claude-status-reporter.env`. See
[`claude-status-reporter.env.example`](claude-status-reporter.env.example)
for the full set with comments.

After changing config:

```sh
sudo systemctl restart claude-status-reporter
```

## Dependencies

- `bash`
- `jq`
- `inotify-tools` (for `inotifywait`)
- `curl` *(only if `REPORTER_BACKEND=http`)*
- `mosquitto-clients` *(only if `REPORTER_BACKEND=mqtt`)*

The installer does not install these — drop them in via your package
manager first (e.g. `sudo apt install jq inotify-tools` on Debian /
Ubuntu).

## Uninstall

```sh
sudo ./uninstall.sh
```

Leaves `/etc/claude-status-reporter.env` in place.

## License

[Unlicense](https://unlicense.org/) — public domain. See `LICENSE`.
