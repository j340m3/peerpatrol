# Telegram history is the alarm state

Status: **superseded by [ADR 0002](0002-alarm-state-in-local-file.md)** — the ticket-05 live smoke test falsified this: a bot's own `sendMessage` output never appears in `getUpdates` in any chat variant, so chat history cannot be re-read as state.

The agent keeps no local alarm state. Alarm state lives in the Telegram chat history: a failure opens (DOWN message), a recovery closes (UP message). After restart, the agent re-derives open alarms by reading `getUpdates`, instead of persisting state to disk.

Why: persistence would add a state file, migration, and per-host divergence from the human-readable chat of record. getUpdates re-read covers restart legitimately and keeps one source of truth everyone can see. Considered and rejected: local sqlite/persistent state (diverges from chat, more v1 surface).

Consequences: needs a long-lived bot token (shared, v1); getUpdates offset tracking is ephemeral state that is deliberately lost on restart (re-read replays recent transitions; accepted that a restart immediately after an alert may redeliver it via offset loss).
