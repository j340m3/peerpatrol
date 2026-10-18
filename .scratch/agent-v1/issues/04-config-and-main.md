# 04 — Config, self-identification, main loop

Status: ready-for-human

Parse the shared JSON config (std.json), derive `checkId`s (explicit `name` or `type+target`), apply `interval_secs` default 60, sort members, match `members[] == hostname` (hard error when missing/ambiguous), then the agent loop: per check, sleep until its next `{bucketStart + offset}` moment, `elect`, if self → probe → message loop. Single binary entry point, graceful shutdown.

Depends on: 01, 02, 03.
Blocks: 05, 06.

Check: run the built binary with a member list of exactly one host and two checks (`ping 127.0.0.1`, `tcp 127.0.0.1:1`) against a fake/mocked telegram endpoint; assert timing spread (probes fire at offset seconds, not the edge) and one DOWN per failing check.

## Comments

Implemented (2026-10-18):

- `src/config.zig`: `Config{telegram, members, checks}`, `Check{?, name, @"type", target, expect, interval_secs}`; `load(gpa, text, hostname) !Loaded` derives ids (`name` or `"<type>:<target>"`), http `expect` default 200, tcp `host:port` split at last `:` (errors TcpTargetNoPort/BadPort), rejects unknown types, sorts members, locates self (`MemberSelfMismatch` on missing OR ambiguous — spec's hard error). `Loaded{parsed, self_index}` with `cnf()` accessor — the config pointer must be taken from the caller's own Loaded struct; returning a pointer into a returned-by-copy struct dangles (segfault caught in initial e2e).
- `src/probe.zig`: `httpProbe(io, url, expect)` now strict code compare (ticket 01 wording "compare status code"); test adds 5xx-with-expect-500 ok case.
- `src/telegram.zig`: added `api_base` (config-overridable; test mocks/self-hosted bridges) used by `apiUrl`.
- `src/main.zig`: single-threaded event loop — per-check `Slot{check, interval, offset, next}`; sleep via `Clock.real` deadline (`min_next` unix secs → `Timestamp.wait`); on wake fire every due slot: `bump` (next fire = (bucket+1)*interval + offset when past), `fire` = elect → probe dispatch (http/tcp/ping) → `alarm.handleResult`, log DOWN/UP sends + telegram errors via `std.debug.print` (stderr → journal). Skipped buckets log nothing. Bad/missing config → one terse stderr line + exit 1 (no stack trace in journal). No signal handling: v1 keeps no local state, default SIGTERM behavior suffices.
- Test support: mock endpoint override `telegram.api_base: "http://127.0.0.1:PORT/bot"`.

Check per ticket (2026-10-18, binary run vs Python mock on 18099, config `members:["$(hostname)"]`, `tcp 127.0.0.1:1` interval 2, `ping 127.0.0.1` interval 3, 12 s window):

- All probes fired at offset seconds inside their buckets, never at bucket edges: tcp at odd seconds (offset=1 mod 2), ping at +1 mod 3 — timing spread between the two checks verified.
- Exactly ONE `DOWN tcp:127.0.0.1:1` message sent; every later failing attempt stayed silent because the mock's getUpdates then returns that DOWN in chat 1 (history-as-state dedup round-trips through the mock).
- ok check (ping) sent nothing.
- `zig build test`: 19/19 pass (config cases: derive, defaults, sort, self-match, missing/ambiguous/bad-tcp/unknown-type errors).

Ops notes learned while e2e'ing:

- `http.responses` in the probe test server raised 3→4 (the added expect-500 request would otherwise hang the client: fetch has no timeout).
- Bash `$!` after `a && b &` captures the subshell, not the process — orphaned agent runs confused a round of e2e; use `(exec cmd) & pid=$!` and kill both pids.

Post-smoke hardening (2026-10-18): ticket 05's channel history showed the pre-fallback stale binary re-posting `DOWN` every elected bucket while its state file was unwritable — with no local dedup, a misconfigured state path turns every failing probe into chat spam, forever. Added a startup gate: `alarm.FileTransport.ensureWritable()` (read-or-empty + rewrite-with-same-bytes; creates the file when missing) called from `main` right before the loop — exit 1 with `agent: state path <p> not writable: <err>` before any probe or Telegram send can happen. Verified: 20/20 `zig build test` (new test: creates missing file in tmpdir, errors FileNotFound on an impossible path); e2e with `state_path: /tmp/opencode/nodir/state.txt` → one journal line + exit 1, no sends.

