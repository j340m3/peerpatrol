# peerpatrol

[![ci](https://github.com/j340m3/peerpatrol/actions/workflows/ci.yml/badge.svg)](https://github.com/j340m3/peerpatrol/actions/workflows/ci.yml)

Decentralized monitoring for small fleets: every member host checks its peers
on schedules derived purely from hashing — no central server, no peer
traffic. When a check fails, exactly one `DOWN` message lands in a shared
Telegram chat; one `UP` message closes the alarm.

One static Zig binary, one JSON config shared by all members.

## How it works

Time is sliced per check into buckets of `interval_secs`. Within each bucket,
every member is doing nothing except the one member elected as checker:

1. **Schedule.** A check named `c` with interval `i` runs at second
   `floor(now / i) * i + sha256(c) % i` — the hash staggers same-interval
   checks, and the probe never fires on a bucket edge.
2. **Election.** Each bucket elects one checker:
   `sha256("<bucket>:<c>") % len(members)` over the sorted members list. The
   checker probes; everyone else idles. There is no communication — every
   host computes the same answer from the same inputs.
3. **Alarms.** The checker of a bucket reports the result. A failed probe
   opens an alarm if the last line for that check in the local state file is
   not `DOWN`: it appends `DOWN <check> @bucket <n>` and sends the same text
   via the Bot API. A passing probe after a failure sends `UP <check>`.
   Alarm state lives in a local file (`state_path`), so a restarted host
   re-derives it without reading Telegram history.
4. **Checks.** Three probe types: `http` (status must equal `expect`),
   `tcp` (connect to `host:port`), `ping` (one ICMP echo via the system
   `ping`).

Consequences of the shape: a dead checker skips at most one bucket before
the next bucket elects someone else; one DOWN/one UP per alarm, no repeat
notifications; check names are only ever inputs to the hash and surfaced in
   messages. [docs/adr](docs/adr/) records the two significant design
   decisions.

## Config

```json
{
  "telegram": { "bot_token": "123:ABC", "chat_id": 123456789 },
  "state_path": "monitor-state.txt",
  "members": ["laptop", "nixos-01", "nixos-02"],
  "checks": [
    { "name": "web", "type": "http", "target": "https://example.com", "expect": 200, "interval_secs": 60 },
    { "type": "tcp", "target": "gateway.lan:22" },
    { "type": "ping", "target": "gateway.lan" }
  ]
}
```

- `members` — plain hostnames, sorted by the agent. The host running the
  agent must appear exactly once (`members[] == hostname`), or the agent
  refuses to start.
- `checks[].name` — optional; derived from `type` + `target` when unset.
- `checks[].interval_secs` — default 60. `expect` — default 200 for http.
- `state_path` — optional; default `monitor-state.txt` in the working
  directory.

The same config file is provisioned to every member. Credentials may instead
live in files readable at startup:

```
peerpatrol config.json --token-file /run/secrets/tg-token --chat-id-file /run/secrets/tg-chat-id
```

File contents override the JSON values. Empty content fails the same way an
empty JSON value would.

## Deployment

### NixOS (flake module)

```nix
{
  imports = [ inputs.peerpatrol.nixosModules.default ];
  services.peerpatrol = {
    package = inputs.peerpatrol.packages.x86_64-linux.default;
    configFile = ./config.json;
  };
}
```

Import on every member with the same `configFile`. The unit runs as
`DynamicUser` with `cap_net_raw` (for `ping`), holds its working dir in
`/var/lib/peerpatrol` for the state file, and restarts on failure.

Secret files integrate with sops-nix (or similar) via `tokenFile` and
`chatIdFile` on `services.peerpatrol`: they are passed into the unit through
`LoadCredential` and forwarded as the flags above, keeping the files
unreadable to anyone but the service.

### Plain systemd

`systemd/peerpatrol.service` is a standalone template for hosts outside the
flake — adjust the binary and config paths.

### Running from source

```
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl --prefix out install
out/bin/peerpatrol config.json
```

Outbound HTTPS to the Bot API is the only network requirement; `ping`
additionally needs `CAP_NET_RAW` when unprivileged.

## Development

```
zig build test          # unit tests (scheduler, election, config, alarms)
nix build -L            # release build (static musl)
nix flake check -L      # also evaluates the NixOS module and VM config
```

`nix build .#nixosConfigurations.agent-vm-check.config.system.build.vm` boots
systemd wiring (see commits with `agent-v1:` prefixes).

## Design ceilings (accepted, v1)

- No absence alarms: a dead checker only skips its buckets, notifying no one.
- Dedup is per local state file: if the elected checker changes hosts
  mid-alarm, the new host may re-send one DOWN.
- No message authentication: anyone with the bot token can post anything.
- Members are names only, no addresses: v1 trusts hash scheduling over
  coordination.

## License

MIT
