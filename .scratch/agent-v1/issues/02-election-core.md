# 02 — Election core

Status: ready-for-agent

Pure functions, no I/O: `bucketOf(checkId, intervalSecs, now)` → bucket number; `offsetOf(checkId, intervalSecs)` → second inside the bucket (`sha256(checkId) % interval`); `elect(checkId, bucket, membersSorted)` → member name (`sha256(bucket + ":" + checkId) % len`). These three are the whole "whose turn" mechanism.

Depends on: none.
Blocks: 03, 04.

Check: golden hashes — known checkId/bucket/member-list inputs assert exact member + offset, pinning the formula against accidental change.

## Comments
