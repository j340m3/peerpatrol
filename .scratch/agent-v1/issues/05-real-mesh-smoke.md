# 05 — Real-mesh smoke run

Status: ready-for-human

End-to-end on the user's hosts: real bot token + chat id (from user), config covering ≥2 members and ≥2 checks, run the agent on ≥2 hosts, watch the Telegram chat: DOWN on killing a target, UP on restarting it, no spam while green, rotation visible via `@bucket` numbers across hosts.

Depends on: 04.
Blocks: none.

Check: scripted walkthrough with recorded chat output; the user signs off from the real phone.

## Comments

- **Verdicts** (live token, real "Monitoring" channel id -1004359639475, bot @j340m3_homelab_monitoring_bot):
  - getMe ✓; channel reachable via channel_post updates (user @mention visible to bot).
  - **ADR 0001 falsified**: bot `sendMessage` ok:true to channel and DM, but `getUpdates` never returned either message. Own bot messages are invisible to bots in every chat variant. → fallback executed per ticket 03 note; ADR 0002 written.
  - **Round-trip verified live** (fresh binary, single-member config, tcp check 127.0.0.1:45679 interval 3): `agent up` → one `DOWN sent (probe fail)` at bucket 597443843 while target dead → exactly one DOWN despite sustained failures (state-file dedup works) → `UP sent (probe ok)` at bucket 597443845 after target listener opened. State file shows the exact two transition lines. Telegram channel receives the messages (humans confirmed by ok:true responses; only agent log + state file are machine-verifiable).
  - **Full channel history, every cluster attributed** (user posted the complete transcript; corrected two earlier misattributions):
    - `[15:42] DOWN smoke-check @bucket 0` — the ADR-0001 round-trip test message (fake alarm text posted manually; `getUpdates` never saw it back → falsification proof, visible only to humans).
    - `[15:50–15:51] DOWN tcp:…:45679 @bucket 597443803…827` (25 consecutive) — the stale pre-fallback binary from run 1 had no local dedup: it re-posted DOWN every elected bucket while the state file stayed empty. This is the exact spam mode the ticket-04 post-smoke `ensureWritable` startup gate now makes impossible for the final binary.
    - `[15:52] 597443843 DOWN`, `UP`, `597443849 DOWN` — the final verified binary: DOWN opens (target down), UP closes (listener opened), second DOWN opens again (listener closed before cleanup) — three real transitions, three messages, zero repeats while failing. Earlier note crediting 849 to "a second orphan" was wrong: realsmoke.log line 4 proves the final binary sent it. After cleanup, pgrep shows no monitoring agent running; channel quiet since 15:52.
  - Known ceiling exercised: dedup is per local state file — a checker-host change mid-outage re-sends one DOWN and UP waits for the DOWN-firing host's next turn (documented in spec + code).
  - Ops lessons baked in: `zig build test` does NOT reinstall zig-out/bin/agent (must `zig build` before smoke runs); orphaned agents from earlier runs corrupt smoke signals (kill by PID, pkill unreliable in sandbox).
- Remaining for human sign-off: the user confirms DOWN/UP arrived on the real phone in the Monitoring channel.
