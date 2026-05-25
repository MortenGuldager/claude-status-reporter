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
  "slots": {
    "c632fc39-11d4-4d63-9dda-74d14706f07b": "#ff0000",
    "9c0dd5a5-1e3d-4af8-b4e5-d43975c9b38e": "#00dc00"
  }
}
```

`slots` is a map from Claude Code's `sessionId` to the RGB color (hex
`#rrggbb`) that the subscriber should render for that slot, built from
`~/.claude/sessions/*.json` (empty object when no sessions exist).
Keys are sorted so a consumer can dedup by comparing payloads
byte-for-byte.

The status → color mapping lives in this reporter, configurable via
`REPORTER_COLOR_*` env vars (see [`config.env.example`](config.env.example)).
This keeps the display hardware status-agnostic — the same indicator can
be driven by any other publisher emitting the same payload shape with
whatever colors that publisher likes.

Consumers should key off the slot id, not position — two hosts publishing
to the same subscriber will not collide on slot 0. Identifying info
(developer, hostname) is intentionally omitted; encode it in the MQTT
topic or HTTP URL instead.

A keep-alive is also emitted every `REPORTER_KEEPALIVE` seconds
(default 60) so a subscriber that comes online late immediately learns
the current state.

## Backends

- **`none`** — disable publishing entirely.
- **`stdout`** *(default)* — writes to the systemd journal.
  Tail: `journalctl --user -u claude-status-reporter -f`
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

The reporter runs as a **systemd user service**, one instance per user,
with config in each user's `~/.config/`. Installation is a two-stage
process: root stages the files once; each user then enables the service
for themselves without further sudo.

Targets any systemd-on-Linux environment. Self-linger requires
systemd ≥ 249 (Ubuntu 22.04 and newer); for older systems see
[Older systems](#older-systems) below.

### Stage 1 — root installs once

```sh
git clone https://github.com/MortenGuldager/claude-status-reporter.git
cd claude-status-reporter
sudo ./install.sh
```

This drops the script and example config under
`/opt/claude-status-reporter/` and registers the systemd user unit at
`/etc/systemd/user/claude-status-reporter.service`. Nothing is started.

### Stage 2 — each user enables for themselves

```sh
/opt/claude-status-reporter/bin/user-setup.sh
```

That script (run as the user, no sudo) enables linger so the service
survives logout, copies the example config to
`~/.config/claude-status-reporter/config.env`, and starts the service.

Then edit the config to pick a backend (default is `stdout`):

```sh
$EDITOR ~/.config/claude-status-reporter/config.env
systemctl --user restart claude-status-reporter
journalctl --user -u claude-status-reporter -f
```

New users added to the system later run the same one-liner — no
sysadmin involvement.

### Inside a WSL2 distro

Make sure `/etc/wsl.conf` has systemd enabled:

```ini
[boot]
systemd=true
```

(Restart the distro with `wsl --shutdown` from PowerShell after editing.)

Then follow the two stages above as the relevant user. Unlike the old
system-unit setup, no `User=` is hard-coded — whoever runs
`user-setup.sh` gets their own instance.

### From within claude-sandbox

[claude-sandbox][cs] is an Incus-based sandbox for running Claude Code
on Linux; it fetches and installs this reporter automatically during
`claude-sandbox create`. You do not need to install it separately when
using claude-sandbox.

[cs]: https://github.com/MortenGuldager/claude-sandbox

### Older systems

On systemd < 249, `loginctl enable-linger` requires root because the
`set-self-linger` polkit action does not exist yet. Either have the
admin run `sudo loginctl enable-linger <user>` once per user, or drop
in a polkit rule that grants self-linger; the rest of the user flow
works unchanged.

## Configuration

Each user has their own config at
`~/.config/claude-status-reporter/config.env`. See
[`config.env.example`](config.env.example) for the full set with
comments.

After changing config:

```sh
systemctl --user restart claude-status-reporter
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

Removes `/opt/claude-status-reporter/` and the system-wide user unit.
Per-user state (`~/.config/claude-status-reporter/` and each user's
`systemctl --user` enable-state) is left in place. Users who want a
clean removal should run, as themselves:

```sh
systemctl --user disable --now claude-status-reporter
rm -rf ~/.config/claude-status-reporter
```

## License

[Unlicense](https://unlicense.org/) — public domain. See `LICENSE`.
