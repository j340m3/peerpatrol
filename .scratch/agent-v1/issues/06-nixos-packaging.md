# 06 — NixOS flake + systemd packaging

Status: ready-for-human

## Implemented

- `flake.nix`: `packages.x86_64-linux.default` builds the static musl binary with the nixpkgs Zig 0.16.0 (exact version pin matches runtime); `nixosModules.default` (`services.monitorAgent.enable/configFile/package`, systemd unit `Restart=on-failure`, DynamicUser, AmbientCapabilities=cap_net_raw for `ping`); `nixosConfigurations.agent-vm-check` = boot-check VM wiring the example config.
- `config.example.json` (spec example), `systemd/agent.service` (standalone template for non-NixOS hosts).
- Verified: `nix build` → statically linked `result/bin/agent`; VM check boots (`result/bin/run-example-host-vm -nographic`) and prints `VMCHECK: monitor-agent is active` + agent journal line (`agent up: self=example-host members=2 checks=3`), then powers off.
- Note: flake files must be `git add`ed before `nix build` (Nix reads tracked files only); zig needs `XDG_CACHE_HOME=$TMPDIR` in derivations; serial-console verification uses an in-VM oneshot reporter writing to `/dev/ttyS0`.

## Comments

- **Post-smoke addition**: ticket 05 showed the agent now writes a local state file; both units gained `StateDirectory=monitor-agent` (with DynamicUser and no WorkingDirectory, systemd sets cwd to the state dir → default relative `state_path` is writable). `nix build` + VM check re-run: VMCHECK pass. (Where/when touched: flake.nix serviceConfig, systemd/agent.service.)

## Depends on: 04. Done.
