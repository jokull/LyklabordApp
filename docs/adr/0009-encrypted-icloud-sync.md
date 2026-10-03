# Encrypted iCloud sync via CloudKit private database

Status: Accepted
Date: 2026-07-15

## Context

The personal dictionary and learned model (ADR-0007) are only useful across
a user's devices if they sync — SwiftKey does this, but through a
Microsoft-account-and-server model this project has already ruled out
(ADR-0001: extension ships zero networking code; no project-run server,
ever). `research/foundation-options.md` confirmed the feasible alternative:
CloudKit's private database, with the containing app doing all networking
(never the extension), and payloads client-side encrypted before upload so
the sync layer only ever sees ciphertext — CloudKit's own `encryptedValues`
API was considered but the project layers its own CryptoKit AES-GCM
envelope on top for a "we don't even trust our own use of Apple's API"
posture, matching precedent from other privacy tools (e.g. TurboClipboard).

Two hard design problems had to be solved for this to be safe and
zero-server:

1. **Key distribution with no server and no passphrase UX.** The
   encryption key must roam to every device the user's iCloud account
   touches, without a server ever seeing it and without asking the user to
   remember a passphrase.
2. **Merge semantics with no server-side conflict resolution and no stored
   "common ancestor" state.** Two devices can both mutate the personal
   model offline and sync later; without a server-authoritative merge or a
   three-way-diff ancestor, the merge function itself must be safe to run
   repeatedly, in any order, on any pair of states.

## Decision

- **Key**: a per-user AES-256-GCM key lives in **iCloud Keychain**
  (`SyncKeyStore`/`ICloudKeychainStore`), which is the fork-proof bootstrap
  mechanism — Apple's own keychain sync roams the key to every device on
  the account with no server code and no user-visible secret to type in.
  Key bootstrap order matters and is enforced in `SyncEngine.sync`: the
  **remote snapshot is always fetched first**; if a remote snapshot exists
  but this device has no key yet, sync fails with `.keyUnavailable` and
  retries later — the engine deliberately never mints a second key in that
  state, since that would permanently fork the two devices onto
  mutually-undecipherable snapshots. A fresh key is generated only when
  **both** remote and local key are absent, using add-if-absent semantics
  (re-reading after a save in case another device raced to create one
  first).
- **Merge**: `PersonalModelMerge` (`Packages/Sync/Sources/Sync/Merge.swift`)
  is deliberately designed as a **join semilattice** — every per-field
  merge operation is associative, commutative, and idempotent
  (`merge(a,a) == a`, `merge(merge(a,b),b) == merge(a,b)`), so repeated or
  out-of-order syncing between any two devices can never inflate state or
  require a stored ancestor:
  - **Counts** (word stats, bigram frequencies, touch-model sample counts):
    field-wise **max**, not sum. Summing would require exactly the ancestor
    bookkeeping this design avoids — re-merging the same remote snapshot
    twice would double-count. The accepted cost: cross-device totals
    undercount (a word typed 10× on each of two devices merges to 10, not
    20) — acceptable because counts only drive *relative* ranking, and both
    devices keep re-inflating their own counts organically anyway.
  - **Tombstones and explicit re-adds**: decided per word by a
    **tombstone epoch** — a per-word counter (`tombstoneEpochs`, absent =
    0) that `PersonalModel` bumps on every *explicit* editor action that
    flips the word's tombstone state (delete, re-add via `addUserWord`,
    clear tombstone) and on nothing else. Epochs merge by max; the word's
    tombstone, user-added flag, counts and bigrams are taken only from the
    side(s) at that word's maximum epoch. Consequences:
    - a device strictly ahead wins outright, so an explicit re-add
      (epoch+1, tombstone cleared) beats the synced deletion it undoes and
      propagates to every device, and a *later* explicit delete (epoch+1
      again) beats that re-add;
    - at equal epochs the tombstone wins, so a delete and a re-add that
      never saw each other resolve to deletion — the deliberately safer
      default for a privacy product;
    - implicit relearning (typing the word again, even a verbatim tap)
      never touches the epoch, so "deletions stick" against organic
      relearning (ADR-0007) exactly as before; a stale device's old counts
      for a word deleted-then-re-added elsewhere are discarded, not revived
      (required for associativity — the result must not depend on merge
      order);
    - with no epochs on either side (documents from builds that predate
      the field) every word ties at 0 and the merge is the original
      tombstone union, byte for byte.
    The field is additive to schema 1 and omitted when empty: old readers
    ignore it and new readers treat its absence as "all 0". Mixed-version
    fleets have one known limitation: a build without epochs still merges
    by union and re-encodes without the field, so it re-tombstones a word
    another device re-added until it updates; the re-adding device keeps
    its re-add locally throughout (its epoch is higher than the stripped
    remote's 0) and everything converges once all devices carry epochs.
    Nothing is lost that the old build could represent.
  - **User-added words**: union minus tombstones (among the sides at the
    word's maximum epoch).
  - **`explicitlyAccepted`**: **OR** across devices.
  - **Touch-model stats**: kept whole from whichever side has the higher
    effective sample count (never averaged — per-device Welford
    aggregates aren't linearly combinable without corrupting the decay
    bookkeeping), with a deterministic tiebreak so the choice is
    order-independent.
  - **`consumedLogMarker`** (the device-local bookmark into its own event
    log) is explicitly **excluded from the synced payload** — it is
    re-attached locally after merge and never leaves the device, since it
    has no meaning on any other device.
- **Statelessness**: `SyncEngine` keeps no state between calls; debouncing/
  coalescing multiple triggers (post-compaction, dictionary edits) into one
  sync round is the caller's (`SyncCoordinator`) job. Calling `sync` twice
  in a row is always safe (the second short-circuits at `.upToDate`), and a
  server-side conflict is retried exactly once with a re-merge before
  giving up for that round.
- **Opt-out and deletion**: sync short-circuits to `.disabled` when the
  user's opt-out flag is set; `deleteRemote` deliberately **ignores** that
  flag, since deleting already-synced remote data after opting out is the
  expected next step, not a contradiction.

## Consequences

- No server the project runs or controls ever exists in this data path —
  CloudKit private database plus the user's own iCloud Keychain is the
  entire infrastructure, consistent with ADR-0001's zero-network-code
  posture applied at the containing-app level (the extension itself never
  touches any of this; sync is exclusively app-side, per ADR-0007's
  process boundary).
- The merge design intentionally sacrifices exact cross-device count
  totals for unconditional safety against re-merge inflation — a
  correctness trade the codebase documents explicitly as "harmless" since
  ranking only needs relative order, not exact sums.
- A remote snapshot that fails to decrypt, or that carries a newer schema
  version than this build supports, is treated as untouchable — local
  state is never clobbered and the bad remote is never overwritten,
  erring toward data preservation over automatic recovery.
- Related: ADR-0007 (this ADR syncs the state that ADR-0007 defines and
  locally enforces — tombstones, learned thresholds); ADR-0001 (the
  zero-network-code posture this design is built to satisfy without a
  project-run server).
