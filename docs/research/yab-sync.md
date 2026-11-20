# Yab's sync: where the data lives

Japanese translation: `yab-sync.ja.md`.

Subject: Yab's own source at commit `5a9b57a94cdfbc9bb181b8bab26c1f0611ddf245` (read only, `~/workspace/github.com/yetanotherbrowser/yab`). Citations are `path:line` in that tree; each is also at `https://github.com/yetanotherbrowser/yab/blob/5a9b57a94cdfbc9bb181b8bab26c1f0611ddf245/<path>`. Prices were read on 2026-11-20 from the pages cited, and every cost below is our own arithmetic on those prices, marked as an estimate.

The short answer: sync data is not in iCloud. Records are sealed on the device and stored by a Cloudflare Worker on the Yab owner's Cloudflare account. iCloud Keychain carries the account key and nothing else, so a second Mac on the same Apple ID joins without a code.

`docs/sync.md` describes this design in full; this note covers only the questions Ararat's E-Sync decision asks. Every number here is taken from that file or from the code it describes, except the prices in section 7, which come from the pages cited there.

## 1. What syncs

One record per item, `{collection, id, fields, stamps, deleted, schema}`, each field carrying the stamp of its last change, each record a removal stamp where the collection allows one (`Record.swift`, described at `docs/sync.md:13-17`). A device keeps every record it has in `sync.sqlite` with a dirty flag, the server's version and a cursor (`docs/sync.md:21-22`). Merge is per field, newest stamp wins, on a hybrid logical clock; tabs and pairs let a removal beat everything (`docs/sync.md:14-17`, `docs/sync.md:861-864`).

The collections (`docs/sync.md:262-367`) fall into five groups:

| Group | What travels |
|---|---|
| The workspace | `space`, `tab`, `folder`, `pair`, `bookmark` (`docs/sync.md:274-278`) |
| Settings and small files | `setting`, `file`, `icon`, `answer` (`docs/sync.md:279-281`, `docs/sync.md:286`) |
| Secrets | `login`, `code`, `card`, `address` — the keychain mirrored, each secret sealed a second time (`docs/sync.md:282-285`, `docs/sync.md:368-376`) |
| Add-ons | `extension`, `plugin`, `pluginpart`, with a ledger of what this Mac last agreed to (`docs/sync.md:298-300`, `docs/sync.md:403-430`) |
| Between devices | `routine`, `memory`, `visit`, `chat`, `chatitem`, `project`, `send`, `sendpart`, `commandcap`, `taskcommand`, `task`, `now`, the five `assistant*` collections (`docs/sync.md:287-297`, `docs/sync.md:301-306`) |

What is deliberately not sent:

- Windows other than the main one, private tabs, an agent's tabs; history older than 14 days; chats untouched for 14 days and not pinned (`docs/sync.md:578-583`).
- Anything Gmail: a chat that mail went into, memory mail wrote, mail lists and snippets, a mail sign-in's history steps (`docs/sync.md:599-604`).
- Each device's own "today" rows: a tab of today carries the id of the device that opened it and other devices draw only their own (`docs/sync.md:606-648`).

## 2. The server

A single Cloudflare Worker, `yab-sync`, whose Durable Objects hold the data (`sync-server/wrangler.jsonc:1-23`, `sync-server/README.md:1-8`). Six object classes are bound: `Account`, `Pairing`, `PushBox`, `Directory`, `Host`, `Counts` (`sync-server/wrangler.jsonc:7-16`), all on the SQLite storage backend (`sync-server/wrangler.jsonc:17-22`). Only `Account` and `Pairing` matter for sync; `Directory` and `Host` belong to assistants in the cloud, `PushBox` to Web Push for sites, and `Counts` to the site's admin census (`sync-server/src/index.ts:20-45`, `sync-server/README.md:15-24`).

The address:

- `YAB_SYNC_URL` in the environment, then `Info.plist`'s `YabSync`, then `https://yab-sync.21st.workers.dev` (`Sources/Fast/SyncCenter.swift:267-274`, `docs/sync.md:177-181`). That default is the owner's own Cloudflare account, deployed with `npx wrangler deploy` from `sync-server/`.
- Every account's requests go to the `Account` object named after the account id; pairing goes to one `Pairing` object for everyone (`sync-server/src/index.ts:27-43`).

Per account the object holds one row per record — the sealed name, a version, a sequence number, the sealed blob, its size and the time it changed — plus the device list with a hashed token, a last-seen time, presence and push registration (`sync-server/src/account.ts:64-96`).

The protocol, in outline (`docs/sync.md:153-261`):

- HTTP for device registration, the device list, revocation, pairing boxes and account deletion (`docs/sync.md:183-228`).
- One WebSocket per device: `hello` with a cursor, batched catch-up up to 500 records and 4 MB, then live changes, a per-device `presence` blob relayed to the other devices, and a `pushed` acknowledgement carrying conflicts (`docs/sync.md:229-261`, `sync-server/src/account.ts:24-27`).
- A write carries the version the device last had; if it is no longer the server's version, the server returns the current blob as a conflict and refuses the write (`docs/sync.md:236-239`, `sync-server/src/account.ts:444-465`). The server is therefore a dumb but authoritative version counter, not a merge point.

Limits: a blob of at most 96 KB of base64, an account of at most 250 MB, a presence blob of 8 KB, 500 changes per push, 500 records and 4 MB per catch-up batch (`sync-server/src/account.ts:19-27`, `docs/sync.md:255-260`). A client sends at most 768 KB of records in one push (`docs/sync.md:463-466`).

## 3. End-to-end encryption

One random 32-byte key `K` per account, made on the first device and never sent anywhere (`Sources/SyncKit/Seal.swift:5-8`, `docs/sync.md:50-51`). Everything else is HKDF-SHA256 from it, under four info strings (`Sources/SyncKit/Seal.swift:12-18`, `Sources/SyncKit/Seal.swift:56-58`, `docs/sync.md:53-58`):

| Derived | Becomes |
|---|---|
| record key (`yab sync records v1`) | AES-GCM over each record, with the record's server name as associated data (`Sources/SyncKit/Seal.swift:40-46`) |
| name key (`yab sync names v1`) | HMAC-SHA256 of `collection` NUL `id`, base64url — the record's name on the server (`Sources/SyncKit/Seal.swift:33-37`) |
| account id (`yab sync account v1`, 16 bytes) | the account's address on the server (`Sources/SyncKit/Seal.swift:88-92`) |
| auth secret (`yab sync auth v1`) | proves a device holds `K`; the server stores only its SHA-256 (`Sources/SyncKit/Seal.swift:94-98`, `sync-server/src/account.ts:186-190`) |

A password, a card number or an address inside a record is sealed a second time under a key derived with `yab sync secrets v1`, with the record's own key as associated data, so the journal on disk holds nothing that opens without `K` (`Sources/SyncKit/Seal.swift:60-76`, `docs/sync.md:368-376`).

**What the server can see.** The number of records per account, their sizes, their versions and when they changed; the device list with each device's name, model, last-seen time, push token and whether it was revoked; presence blobs, themselves sealed (`sync-server/src/account.ts:68-80`, `docs/sync.md:844-846`); and the traffic itself. Yab states the same in its privacy page: the server sees how many records there are, their sizes and when they change (`docs/privacy.md:19`). It cannot read a record's contents, its collection, its id, or a tab's address; it does not know who the person is, because the account id is a hash of a key (`Sources/SyncKit/Seal.swift:88-92`).

**What the encryption does not cover.** Records carry no signature a server cannot forge. A server that keeps old sealed records could serve one again — a plugin record from before its removal, say — and a device joining fresh with nothing newer to compare against would take it (`docs/sync.md:544-549`). The design relies on the version counter and on devices having seen newer records, not on authorship.

Removing a device revokes its token at once, but the device still knows `K`; the way to be sure is Remove and Change Key, which makes a new `K`, a new account, and moves the other devices over with a sealed note under the old account (`docs/sync.md:148-151`).

## 4. What iCloud is used for

Only the key. A Mac keeps two copies: one local keychain item saying this Mac is in sync, and one synchronizable generic-password item in the iCloud Keychain, which a new Mac on the same Apple ID finds by itself (`Sources/Fast/SyncKey.swift:6-11`, `Sources/Fast/SyncKey.swift:18-32`, `Sources/Fast/SyncKey.swift:51-66`). Without that second copy — a build not signed for it, or another Apple ID — the code or the Recovery Key does the same job (`docs/sync.md:92-111`).

Consequences worth naming:

- Turning sync on looks for the shared key for six seconds before offering "Is This Your First Device?", because iCloud Keychain can lag by minutes and a key made in that gap would be a second account for the same person (`docs/sync.md:60-66`).
- A build not entitled to iCloud Keychain simply has no second copy; this is a normal state, not an error (`Sources/Fast/SyncKey.swift:10-11`).
- No tab, bookmark, password or chat is stored in iCloud Drive or CloudKit. If iCloud is unavailable, sync continues; only joining a new Mac by itself stops working.

## 5. Pairing, and two Apple IDs

The account is the key: no email, no password, and whoever holds `K` is the account (`docs/sync.md:92-93`).

- **Same Apple ID:** the second Mac reads the key from iCloud Keychain and joins with nothing typed (`docs/sync.md:95-96`).
- **Different Apple ID:** Settings › Sync › Add a Device shows eight characters (31 letters and digits, no 0/O/1/I/L) and a QR of `yab://join/ABCD-EFGH`; the other device types or scans it (`Sources/SyncKit/Seal.swift:196-203`, `docs/sync.md:101-108`).
- **The code never reaches the server.** It is stretched by PBKDF2-SHA256 at 300,000 rounds with the salt `yab sync pairing v2`, and HKDF of that gives the box name, the key that tags the posted X25519 key and the salt of the envelope's key (`Sources/SyncKit/Seal.swift:213-229`, `Sources/SyncKit/Seal.swift:141-168`). A device already in the account seals `K` to the new device's one-time key; both screens show four digits derived from the key and the code, and the person confirms them before anything is sealed (`docs/sync.md:109-115`).
- A box lives ten minutes, and its envelope can be read at most 20 times (`docs/sync.md:223-224`).
- **Two accounts on one Apple ID:** a Mac already syncing compares its key with iCloud's and says so if they differ; joining needs no digits, and where two accounts meet the one with more devices stays while every device moves over through a sealed `accountmove` record (`docs/sync.md:68-92`).

This is why the pairing question does not limit sync to one person: two people on different Apple IDs share an account exactly as two Macs on one Apple ID do.

## 6. Push

While a device has no socket open, a change accepted from another device sends it a silent APNs push (`content-available`, priority 5, collapsed), at most one a minute (`docs/sync.md:206-214`). A question for the person has its own path, at most once per question and recipient with a two-day deduplication window (`docs/sync.md:902-913`). This needs the team's APNs key in the Worker's secrets; without it nothing is sent (`docs/sync.md:209-211`, `sync-server/src/env.d.ts:11-16`).

At this commit the owner has no APNs key, so nothing wakes an iPhone in the background; a page or a request reaches it when its line opens (`docs/sync.md:785-789`). Macs do not need push: a Mac's socket is open while Yab runs, and catch-up by cursor covers the rest.

## 7. Could a third party run it?

**Licence.** Yes. Yab's source, `sync-server/` included, is Apache-2.0 (`LICENSE:1-2`), so it may be copied, modified and deployed, provided the licence and NOTICE travel with it and changes are stated. The names and marks are not licensed: "Yab", the logo and the app icons stay Yab's (`TRADEMARKS.md:1-10`), so a deployment would need its own name.

**Configuration.** A Cloudflare account and node are the whole setup; there is no external database, object store or message queue. `npx wrangler deploy` publishes it, and the Durable Object classes and their SQLite migrations are declared in `wrangler.jsonc` (`sync-server/README.md:57-62`, `sync-server/wrangler.jsonc:17-22`). Secrets are optional: `APNS_KEY`, `APNS_KEY_ID` and `APNS_TEAM` for iPhone push (`sync-server/README.md:64-77`), and `CENSUS_TOKEN`, which only gates the census route and answers 404 without it (`sync-server/src/index.ts:22-25`).

**Client side.** The server address is not baked into the protocol: `YAB_SYNC_URL` or `Info.plist`'s `YabSync` points a build at another deployment (`Sources/Fast/SyncCenter.swift:267-274`). This matters only for Yab's own clients; a third party with its own browser would write its own client against the documented protocol (`docs/sync.md:153-261`).

**Cost — an estimate.** Read on 2026-11-20 from Cloudflare's Workers pricing page (last modified 2026-11-18) and Durable Objects pricing page (last modified 2026-11-13):

| Item | Free | Paid |
|---|---|---|
| Workers requests | 100,000/day | $5/month minimum, 10 M included, +$0.30/M |
| Durable Object requests | 100,000/day | 1 M/month included, +$0.15/M |
| Durable Object duration | 13,000 GB-s/day | 400,000 GB-s/month included, +$12.50/M GB-s |
| SQLite rows read / written | 5 M / 100,000 per day | 25 billion / 50 M per month included, then $0.001/M and $1.00/M |
| SQLite storage | 5 GB total | 5 GB-month, +$0.20/GB-month |

Our arithmetic for a household-scale deployment — five people, fifteen devices, one line open eight hours a day:

- Presence is the steady load: every 55 seconds while a line is up (`docs/sync.md:793-795`), about 1,600 messages a device a day. At the 20:1 ratio Cloudflare applies to incoming WebSocket messages for billing, fifteen devices come to roughly 36,000 billed requests a month, against 1 M included on the paid plan and 100,000 a day free.
- Duration is near zero because the socket uses the Hibernation API, which stops the clock once handlers finish (`sync-server/README.md:7-8`, `sync-server/src/account.ts:310`). Without hibernation the same fifteen devices would hold five account objects open for eight hours a day, about 550,000 GB-s a month — over the 400,000 included, roughly $2 more.
- Storage: an account is capped at 250 MB (`sync-server/src/account.ts:22`), so five full accounts stay inside the 5 GB included.
- Writes: one row per accepted change, far below 50 M a month.

So a household deployment should cost nothing on the free plan, and $5 a month on the paid one with no overage at this scale. Two costs sit outside Cloudflare:

- iPhone silent push needs an Apple Developer Program membership, $99 a year (read 2026-11-20 from `developer.apple.com/programs/`); Mac-only sync needs none, as Yab shows today.
- `workers.dev` needs no domain; a custom domain was not priced here and is not needed for a deployment of this size.

Two things the tree disagrees with itself about, for anyone reading it later: `docs/sync.md:255-256` and `sync-server/src/account.ts:22` cap an account at 250 MB, while `sync-server/README.md:83` says 50 MB; and `docs/sync.md:5-6` points at `PLAN-sync.md` for the plan, which is not in the tree at this commit.

## 8. For Ararat's E-Sync decision

The mock decision leaves the pane as planned with sync in phase 8 and the server hosting undecided (`mock-decisions.md:100` in the design session's `reports/design-u20`). Ararat's own design is already stricter than Yab's in two places: signed blobs with per-device keys, and an epoch started on removal, both under a recovery phrase (`docs/architecture.md:393-412`), stored by a Rust relay on SQLite or an S3-compatible store (`docs/architecture.md:426-428`). It also carries fewer collections: the workspace, routing rules, key bindings, settings, passwords and extensions (`docs/architecture.md:422-424`), where Yab carries chats and the commands that steer a Mac from a phone (`docs/sync.md:290-306`). The three options, with what each buys and what it costs, and no recommendation.

**A. Yab's design on our own Worker.** Sealed records under blind names, one shared symmetric key per account, the relay holding only a version counter, joins by a stretched code or a phrase, iCloud Keychain or a code carrying the key.

- Buys: a working, documented protocol and the clients Yab ships against it (Mac and iPhone); no account system at all; a server that costs $0–5 a month at household scale and has no database to operate; nothing for us to invent in the merge rules, which are already spelled out per collection.
- Costs and limits: it is Cloudflare-specific (Durable Objects, WebSockets, SQLite in the object) unless rewritten; there is no per-device signature, so the relay could replay or roll back old records (`docs/sync.md:544-549`), which Ararat's §8.2 requires and Yab's design explicitly does not do; removal moves every device to a new account rather than starting an epoch (`docs/sync.md:148-151`); the key's default carrier, iCloud Keychain, exists only on Apple platforms, which leaves Windows and Linux on the code-and-phrase path (`Sources/Fast/SyncKey.swift:6-11`).
- Licence is compatible: Apache-2.0 code can be taken into this GPL-3.0 repository with Yab's notices kept (`LICENSE:1-2`, `TRADEMARKS.md:1-10`).

**B. iCloud / CloudKit.** Apple's own store, the person's Apple ID as the account.

- Buys: no server of ours to run, and the same sign-in the rest of the app already uses.
- Limits: Apple platforms only, and every user needs an iCloud account; the store sits outside our protocol, so the workspace model, the merge rules and the passwords' second sealing would have to be mapped onto CloudKit's own record and conflict model, and whether CloudKit's encrypted fields cover that was not checked here. The CloudKit container is also tied to an Apple Developer membership (not checked). It contradicts the design's own premise of reaching Windows and the iPhone the same way (`docs/architecture.md:430-435`).

**C. None.** No sync in phase 8.

- Buys: the phase's cost and the server hosting decision disappear; the sidebar, the iPhone app and the engine work stand alone.
- Costs: no cross-device tabs, bookmarks, passwords, extensions or chats, and the iPhone app has no way to see a Mac's spaces; the Sync pane in the mock (`mock-decisions.md:100`) would be withdrawn.

The owner decides.
