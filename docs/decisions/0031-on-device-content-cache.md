# 0031 — On-device content cache

Date: 2026-09-25

## Context

MatterMac was built session-only: after every launch it downloaded all images,
profiles, channel lists and messages again. The user rejected that rule on
2026-09-25. They asked for images, profiles, recent chats "and anything that is
good to be loaded fast" to be cached on the device.

## Decision

`ContentCache` (MatterMacCore) is the app's only content persistence besides
Keychain sign-ins.

- **What:**
  - Compressed image bytes for resources that are immutable under their key.
    Proxied external images are never cached.
  - One directory snapshot per account, including the last open team and
    channel.
  - The newest 60 posts, plus their thread roots, of the 40 most recently written
    channels per account.
  - Nothing that is unsent work, search, presence, typing, or a local
    presentation setting. Drafts stay in memory; persisting them was not requested
    and would need its own decision.
- **Where:** `Library/Caches/org.mattermac.MatterMac/Content` in the sandbox
  container, excluded from backups. Development runs
  (`-MatterMacAllowInsecureLoopback`) use `Content-development` and their own
  keys. `-MatterMacUITesting` and package tests without a cache persist nothing.
- **Protection:**
  - Each file is `MMC1` followed by an AES-GCM sealed box under a random 256-bit
    per-account key stored in the login Keychain (`KeychainCacheKeys`, not
    synchronized).
  - The kind and name are authenticated data, so a file cannot be moved to
    another entry. Unreadable files are deleted.
  - Directory names are SHA-256 digests of server and user; file names are
    digests of entry names.
  - Encryption is cheap and makes Sign Out a crypto-shred even if a file deletion
    fails. The Caches directory is readable by other processes of the same user
    unless the container is protected.
- **Bounds:** `ResourceBudget.diskCache`:
  - media 512 MiB and 20,000 entries;
  - content 96 MiB and 200 entries;
  - 16 MiB per object;
  - 40 channels and 60 posts per channel.

  Two `CostLRU`s index the files. Recency survives relaunch through modification
  dates, touched at most every ten minutes per file. The index is rebuilt from the
  directory on first use; unknown files and older format versions are removed.
- **Correctness:**
  - The cache is a head start, not truth. The directory is restored before the
    first request, but no team counts as loaded, so every channel list is still
    fetched and vanished channels are purged (including their cached posts).
  - A window seeded from the cache is `isCached`. It is shown at once, marked for
    reload on the next open, never written back, and never satisfies the
    read-mark conditions.
  - The unread-line scroll waits for the server page. Replacing a cached window
    re-evaluates read state, because the visible rows may not change.
- **Writing:** coalesced every 4 s after sidebar or active-timeline publishes,
  encoded off the session actor, and written in full at quit (`persistCache()`
  from `AppModel.shutdownAll`).
- **Erasing:** removal unregisters the account first, so late writes are no-ops.
  It happens on:
  - Sign Out;
  - a server-ended session or identity change;
  - a saved sign-in rejected at restore;
  - a shutdown that does not preserve sign-ins;
  - Settings ▸ Accounts ▸ Clear Cache, which removes everything and gives running
    sessions new keys.

## Consequences

The privacy text on the connect screen and in Settings describes the cache. The
invariant "ordinary use persists only Keychain sign-ins" no longer holds; SPEC §2,
§7 and the proof gates were updated. Other macOS processes of the same user
cannot read the cache without the Keychain key. The Mac's own backups skip it.
