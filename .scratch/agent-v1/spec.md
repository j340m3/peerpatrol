# Spec: agent-v1 — peerpatrol

A Zig executable, **peerpatrol**, runs on every host. Each host checks other hosts on a schedule decided purely by hashing — no central server, no peer traffic in v1. Failures surface as Telegram messages. Vocabulary: [GLOSSARY.md](../../GLOSSARY.md).

## Runtime

- Zig, one pinned version, static binary, Linux amd64 first.
- One JSON config, identical on every host, provisioned externally (NixOS flake). The agent never distributes config.
- Agent finds itself by matching `members[] == hostname`; hard error when missing or ambiguous.
- Runs as a systemd unit; NixOS module later.

## Config (JSON)

```json
{
  "telegram": { "bot_token": "...", "chat_id": 123 },
  "state_path": "monitor-state.txt",
  "members": ["laptop", "nixos-01", "nixos-02"],
  "checks": [
    { "name": "web", "type": "http", "target": "https://example.com", "expect": 200, "interval_secs": 60 },
    { "type": "tcp",  "target": "gateway.lan:22" },
    { "type": "ping", "target": "gateway.lan" }
  ]
}
```

- `members`: plain names, sorted by the agent; inputs to election only — no addresses in v1.
- `checks[].type`: `"http"` (expects `expect`, default 200), `"tcp"` (target `host:port`), `"ping"` (target host; shells out to `ping -c1 -W timeout`, runs unprivileged).
- `checks[].name`: optional; auto-derives from `type + target` when unset. Used in messages and in the hash.
- `checks[].interval_secs`: default 60.
- `state_path`: optional; local alarm-state file, default `monitor-state.txt` relative to the agent's working directory.

## Scheduling & election (all deterministic, no communication)

For check `c` with interval `i`, members `M` (sorted):

1. `bucket = floor(now / i)` — every check has its own bucket timeline; nothing is combined into a shared slot.
2. Execution second inside the bucket: `offset = sha256(checkId) % i` → probe runs at `bucketStart + offset` (spreads same-interval checks; never at the bucket edge).
3. Checker election: `checker = M[sha256("bucket" + ":" + checkId) % len(M)]`.
4. A host that does not elect itself does nothing. Rare same-second / same-host collisions are accepted (hash luck, no correctness impact).

`checkId` = the check's `name` (explicit or derived).

## Result → state file + Telegram

- Alarm state lives in a local per-host file (`state_path`, see [ADR 0002](../../docs/adr/0002-alarm-state-in-local-file.md); supersedes the original "read Telegram history" plan, which the ticket-05 live smoke falsified — a bot's own messages never appear in `getUpdates`).
- Probe fails → last line for this check in the state file is not `DOWN` → append `DOWN <checkId> @bucket <n>` and send the same text via Bot API `sendMessage`.
- Probe succeeds → last line is `DOWN` → append `UP <checkId>` and send it.
- Telegram is a notification surface only — humans read it; the agent never reads state back from the chat.
- Failure message every failing bucket is NOT desired; direction is exactly one `DOWN` at alarm open, one `UP` at recovery.
- Shared bot token in the shared config; anyone with it can post — accepted for v1.

## Accepted ceilings (ponytail)

- `ponytail:` dead checker = one silently skipped bucket; no absence alarm. Rotation self-heals next bucket.
- `ponytail:` dedup is per local state file: checker host changes mid-outage → second DOWN re-sent, UP waits for the DOWN-firing host's next turn. Cosmetic at v1 intervals.
- `ponytail:` no result signing/auth: the trust model is "probes observe from outside, nothing claims I'm fine"; forged messages possible for anyone with the token.
- `ponytail:` no mDNS/discovery/static-addr peer transport: members list is election input only.

## Non-goals for v1 (explicit)

Heartbeat/"still ok" messages · absence alarms · peer-to-peer state sync · config distribution · mTLS · exec/NRPE/SNMP probe types · per-host telegram ids or other alert platforms · coupled scheduler preventing same-host collisions.

## Future directions

Per-host alert identity / other messaging platforms · history-dedup hardening · richer probes (exec, NRPE, SNMP) · peer channel for addr-based handshakes · multi-interval edge cases.
