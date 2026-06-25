# claude-status-reporter

A small systemd service that watches every Claude account's
`~/.claudes/<account>/sessions/*.json` and publishes the aggregated
session status to a configurable backend whenever it changes.

Session discovery scans two layouts and unions them (de-duplicated by
`sessionId`), so it works whether you run one Claude login or several:

- **`~/.claude/sessions/*.json`** — the single config dir Claude Code uses
  normally (`CLAUDE_CONFIG_DIR` if set, else `~/.claude`). The common case,
  including inside a sandbox. Override with `CLAUDE_DEFAULT_DIR`.
- **`~/.claudes/<account>/sessions/*.json`** — a multi-account tree where
  each subdirectory is its own `CLAUDE_CONFIG_DIR` kept side by side. New
  accounts are picked up automatically. Override the parent with
  `CLAUDE_HOMES_DIR`.

Designed to drive a desk indicator, a dashboard, or any other
out-of-process visibility into what your Claude Code instances are
doing right now.

## Payload

The `stdout`, `file`, and `http` backends emit one aggregate object per
report:

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
`~/.claudes/*/sessions/*.json` across all accounts (empty object when no
sessions exist).
Keys are sorted so a consumer can dedup by comparing payloads
byte-for-byte.

The **mqtt** backend does not send this blob. Retained messages are stored
one-per-topic, so a single shared topic could never hold more than one
session's state for a late subscriber. Instead the reporter explodes the map
into one retained message per session:

```
<root>/<node>/<sessionId>   payload: "#rrggbb"   (retained)
```

`<root>` is `REPORTER_MQTT_TOPIC` (default `claude_info/status`). `<node>`
identifies this reporter and defaults to a **non-reversible hash of the
hostname**, so a `claude-sandbox` container — named `csb-<project>-<id>` after
the project it was launched from — does not leak that project name to anyone
reading `claude_info/#`. Override `REPORTER_NODE` with a friendly name only
where the identity is not sensitive. So with the defaults a session lands at
`claude_info/status/<hash>/<sessionId>`.

A late subscriber to `claude_info/status/#` therefore receives the exact set
of live sessions, one retained message each. When a session ends the reporter
publishes an **empty retained message** to that topic, which deletes the
broker's retained entry — so subscribers should treat an empty payload on a
status topic as "this session is gone" and clear the slot immediately. As a
safety net for a reporter that dies without sending tombstones, every live
publish carries an MQTT-5 `message-expiry-interval` (`REPORTER_STATUS_EXPIRY`,
refreshed on each keep-alive) so the broker sweeps stale sessions on its own.

The status → color mapping lives in this reporter, configurable via
`REPORTER_COLOR_*` env vars (see [`config.env.example`](config.env.example)).
This keeps the display hardware status-agnostic — the same indicator can
be driven by any other publisher emitting the same payload shape with
whatever colors that publisher likes.

Consumers should key off the slot id, not position — two hosts publishing
to the same subscriber will not collide on slot 0. Identifying info
(developer, hostname) is intentionally kept out of the payload; the only
identity on the wire is the `<node>` topic segment, which defaults to a
hostname hash precisely so it carries no readable name (see above).

A keep-alive is also emitted every `REPORTER_KEEPALIVE` seconds
(default 60) so a subscriber that comes online late immediately learns
the current state.

## Backends

- **`none`** — disable publishing entirely.
- **`stdout`** *(default)* — writes to the systemd journal.
  Tail: `journalctl --user -u claude-status-reporter -f`
- **`file`** — appends one JSON line per report to `REPORTER_FILE_PATH`.
- **`mqtt`** — publishes one retained message per session (see
  [Payload](#payload)), so late subscribers immediately receive the live
  set and ended sessions clear themselves. Connects with MQTT 5 (`-V 5`)
  for the expiry safety net; subscribers may stay on 3.1.1. Requires
  `mosquitto-clients` and an MQTT-5-capable broker.
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
