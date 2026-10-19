# Decentralized Monitoring

A monitoring mesh: an agent binary on every host checks other hosts, with turn-taking decided purely by hashing — no central server.

## Language

**Agent**:
The executable that runs on every Member, acts as Checker when elected, and notifies on every configured Channel.
_Avoid_: monitor, daemon, watcher

**Target**:
The host a Check probes; a Member or any external FQDN/IP.
_Avoid_: endpoint, destination

**Interval**:
A Check's cycle length in seconds; the size of that Check's Buckets.

**Alarm**:
The failing state of a Check, opened by its first DOWN message after an UP and closed by its next UP message.
_Avoid_: alert, incident, outage

**Channel**:
A configured destination for Alarm notifications (a Telegram chat, an ntfy topic, ...). The Agent notifies on every configured Channel; at least one must be configured.
_Avoid_: transport, provider

**Check**:
A single recurring probe of one target, defined in the shared config (e.g. "is example.com:443 reachable").
_Avoid_: monitor, test, service

**Member**:
One host that runs the agent and is listed in the shared config; a member can be both checker and target.
_Avoid_: node, peer, host (use "host" only for the physical machine)

**Bucket**:
A slice of time of length equal to one Check's Interval, numbered by `floor(unixtime / interval)`; every Check has its own sequence of Buckets, and in each Bucket the probe runs at `bucketStart + hash(checkId) % interval` seconds.
_Avoid_: round, slot, window

**Checker**:
The single Member elected for one Check in one Bucket by hashing `(bucket, check)`; it runs the probe during that bucket and reports the result.
_Avoid_: monitor, turn, owner
