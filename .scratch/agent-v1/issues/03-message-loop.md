# 03 — Message loop (alarm transitions via transport seam)

Status: ready-for-human

Given a probe result for (check, bucket): on fail, fetch recent bot updates (`getUpdates`); if last relevant entry for this check is not `DOWN`, send `DOWN <checkId> @bucket <n>`. On success, if last relevant entry is `DOWN`, send `UP <checkId>`. Message formatting + Telegram transport (HTTPS POST) + history parsing. A small transport seam (interface) lets tests swap the HTTP layer.

Depends on: 01, 02.
Blocks: 04.

Check: unit tests with a fake transport — sequences: ok(never signed)→silent; fail→DOWN; fail,fail→one DOWN only; DOWN history + ok→UP; UP history + ok→silent; empty history + ok→silent.

## Comments

- **Implemented** (src/alarm.zig + src/telegram.zig): `decide(last, result)` pure transitions; `handleResult(transport, check_id, bucket, result)`; `Transport` seam (ctx+2-fn vtable), tested via a fake; `stateFromText` word-boundary parsing. 17/17 `zig build test`. `Telegram` real struct (reused http.Client, GET+query sendMessage, getUpdates walking, body `ok` check) written, but a live round-trip is only verifiable with a real token → deferred to ticket 05.
- **Design risk (flagged before live test)**: Telegram bots do NOT see their own sendMessage output in getUpdates (only incoming updates; bots never see any bot's messages regardless of privacy mode). A plain group + one shared bot therefore likely cannot re-read its own DOWN/UP. Remaining untested variant: the bot's own posts in a CHANNEL (bots receive "all messages from channels where they are a member"; unclear whether own posts are included). Ticket 05 must smoke-test which chat variant round-trips before trusting ADR 0001; fallback if none work: local state file with degraded cross-host UP semantics.
- **Fallback executed — ticket 05 falsified ADR 0001**: even in a channel, the bot's own DOWN/UP never round-trips through getUpdates. Rewired per ADR 0002: `FileTransport` wraps the Telegram transport — state file (default `monitor-state.txt`, `state_path` config) stores one transition line per check (parsed via `stateFromText`, last match wins, reload = fresh FileTransport), Telegram `sendMessage` fires on every OPEN/CLOSE purely as notification. Dead getUpdates machinery deleted; `Telegram.lastStateFn` is now a `error.TelegramNoHistory` stub (unused by FileTransport wrapper). 19/19 `zig build test`.
