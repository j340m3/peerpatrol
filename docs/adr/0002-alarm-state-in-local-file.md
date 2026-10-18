# Alarm state is a local file; Telegram is a notification surface

Status: supersedes [ADR 0001](0001-telegram-history-is-alarm-state.md), which was falsified by the ticket-05 live smoke test.

The ticket-05 smoke test proved that a bot's own `sendMessage` output never appears back in `getUpdates` — in any chat variant (private DM, channel, and per the Bot FAQ, groups). Telegram chat history therefore cannot be re-read as alarm state. Decided instead: each agent persists one `DOWN/UP` transition line per check to a local state file (`monitor-state.txt` by default, configurable via `state_path`), and Telegram `sendMessage` carries the same text into the chat as a notification surface only. Restart recovery reads the local file; the chat stays the human-readable log of record, humans just can't be used as machine state.

Why this shape: the first DOWN/UP design (who speaks the transition lives in the election math) is untouched; only where the state lives changed. Keeping the state file local per checker host accepts a known ceiling — if the elected checker changes hosts mid-outage, the new host has no memory and re-sends one DOWN, and UP waits for the DOWN-firing host's next checker turn. A shared-state or peer-sync design was rejected as out of scope for v1 (the whole point was no central store); the file is the minimal thing that makes restart dedup work.

Consequences: the state file must be writable by the agent user (systemd: a `StateDirectory`, see deployment config), and it is per-host — never reconciled between hosts. Humans see every transition in Telegram; machines trust only the local file.
