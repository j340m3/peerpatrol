# 01 — Probe primitives

Status: ready-for-agent

Three small functions: `httpProbe(url, expect)` (GET, compare status code), `tcpProbe(host:port)` (connect, report open/closed), `pingProbe(host)` (run system `ping -c1 -W timeout`, exit code 0 → ok). Each returns an ok/fail + detail string for the message loop. No scheduler knowledge, no config.

Depends on: none.
Blocks: 03, 04.

Check: `zig build test` — probes against `127.0.0.1` (loopback listener for tcp/http ok-case, closed port fail-case; `ping 127.0.0.1` works unprivileged on Linux).

## Comments
