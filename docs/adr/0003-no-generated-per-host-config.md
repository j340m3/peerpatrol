# ADR 0003: no generated per-host config (`settings` option)

Status: accepted

The shared config (members, checks, hash inputs) must be identical on every member host: election and bucket scheduling hash the config's check identities, so hosts with differing configs check different things in different buckets — a silent monitoring split-brain. A per-host JSON generation option (`settings = { … }` in the NixOS module, the usual service-module goodie) invites exactly that drift: each host generates its own file, and nothing compares them.

Decided: `services.peerpatrol.configFile` only — a pre-provisioned, shared file (flakes point every member at the same expression; plain systemd mounts the same file). Telegram secrets are the sanctioned per-host delta, delivered via `tokenFile` / `chatIdFile` overrides, which never participate in the hash.

Consequences: changing members or checks is a one-file rollout on every host (any config-management system that already deploys shared files can do this); the module stays 40 lines instead of growing a formats.json converter and a drift warning. If per-host variance in checks is ever wanted, it is a v2 protocol change, not a packaging knob.
