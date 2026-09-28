# Local patches on goku's self-hosted Twenty CRM

This branch (`goku/opencode-session-header`) is a fork branch of
[twentyhq/twenty](https://github.com/twentyhq/twenty) carrying the patches the
self-hosted deployment on `crm.goku.codes` needs. It is **rebased onto an upstream
release tag, never merged**, so one `git rebase upstream-tag` carries every patch to
a new version.

Layout on the host:

| what | path |
|---|---|
| deployment (compose, .env, data volumes) | `/home/ubuntu/twenty` |
| this fork checkout | `/home/ubuntu/twenty-upstream` |
| upstream remote | `upstream` → `https://github.com/twentyhq/twenty.git` |
| patch branch | `goku/opencode-session-header`, based on `twenty/vX.Y.Z` |
| update scripts | `scripts/update-twenty.sh`, `scripts/verify-local-patches.sh`, `scripts/post-upgrade-smoke.sh` |
| generated artifacts + state | `/home/ubuntu/twenty/.update-work`, `/home/ubuntu/twenty/.twenty-update-state.json` |
| database dumps | `/home/ubuntu/backups/twenty/` |

## Patch inventory

### 1. `opencode-session` — REQUIRED

**Why.** OpenCode Go (`https://opencode.ai/zen/go/v1`) rejects any inference request
that does not carry an `x-opencode-session` header. Twenty's AI chat goes through the
Vercel AI SDK, which never sends it, so every chat turn fails with
`Request is missing x-opencode-session and cannot be routed efficiently`.

Upstream will not add it. Verified on 2026-09-28 against `twentyhq/twenty`:

- PR [#25289](https://github.com/twentyhq/twenty/pull/25289) ("fix(ai): send
  x-opencode-session header on inference requests") — **closed, never merged**.
- Issues [#25286](https://github.com/twentyhq/twenty/issues/25286) and
  [#25588](https://github.com/twentyhq/twenty/issues/25588) — both closed.
- Tag `twenty/v2.43.0`: `git grep -il opencode -- packages/twenty-server/src packages/twenty-docker`
  returns **nothing**, and `ai-provider-config.schema.ts` has no `headers` field, so
  there is no config-only path either. The patch is still required on v2.43.0.

**What it does.** Wraps the provider factories in
`sdk-provider-factory.service.ts` with `withOpencodeSession(config, factory)`. When
(and only when) the provider `baseUrl` matches `opencode.ai`, requests get a session
id derived as `sha256(system prompt + first user turn)` formatted as a UUID: stable
across the turns of one conversation, distinct between conversations, opaque to
OpenCode. Every other vendor's request is byte-for-byte unchanged.

Deliberately *not* what PR #25289 did (one random UUID per cached provider instance),
which shared a session across unrelated conversations.

**Files touched (source, 1 file, additive):**

- `packages/twenty-server/src/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.ts`
  — adds `node:crypto` import, a self-contained helper block, and wraps 5 call sites
  (`buildStandardProvider`'s `factory`, `createXai`, `createAmazonBedrock`,
  `createOpenAICompatible`, `createAzure`).
  `buildTypeSafeAiProvider`/`createTypeSafeAi` is intentionally left alone: that
  provider is evaluation-only (it registers no `createModel`), so no chat request can
  pass through it.

**How it ships.** `patches/opencode-session/generate-dist-patch.py` applies the same
logic to the *compiled* file of the pinned official image, with every anchor asserted;
`Dockerfile.patched` builds a derived image `FROM twentycrm/twenty:vX.Y.Z@<digest>`
that overwrites only
`/app/packages/twenty-server/dist/engine/metadata-modules/ai/ai-models/services/sdk-provider-factory.service.js`.
Server and worker share that image, so one build covers both.

**Verify.**

```bash
FORK=/home/ubuntu/twenty-upstream TWENTY_DIR=/home/ubuntu/twenty \
  bash /home/ubuntu/twenty-upstream/scripts/verify-local-patches.sh
bash /home/ubuntu/twenty-upstream/scripts/post-upgrade-smoke.sh --expected-version vX.Y.Z
```

The functional proof is `patches/opencode-session/probe-opencode-session.js`: 13
assertions driving a real `doGenerate()` through a stubbed fetch (header present for
opencode.ai, stable per conversation, distinct across conversations, uuid shaped, and
*absent* for OpenRouter/OpenAI/lookalike hosts). It passes 13/13 against the
generated artifact inside `twentycrm/twenty:v2.43.0` (node 24.19.0, AI SDK 7.0.103).

Known fingerprints, for cross-checking:

| artifact | sha256 |
|---|---|
| pristine `sdk-provider-factory.service.js` in v2.43.0 | `50c18778f5dcae2451fbd141f165ca50405ea6b8617fa07d0ed89d3fef36edee` |
| generated patched file for v2.43.0 | `ee5ffff6c595b95212f0def4ec739e96f270c0b489ada7ba25c9368b8e71f08d` |
| patched file currently running (v2.40.2 dist patch) | `31b0ac0877f64b779f5818da9c023735f1b794d9422b87dea241b9aa091faa6b` |

**Retire when** either upstream passes custom provider headers through to the SDK for
openai-compatible providers (then configure `headers` and drop the patch), or OpenCode
Go stops requiring the header. Both are one `git grep` away; re-check on every upstream
bump.

### 2. `json-safe-tool-output` (Date crash) — RETIRED

**Was.** A dist patch on `ToolExecutorService.dispatch` normalizing tool results so a
JS `Date` could not break the `ModelMessage[]` schema (`Invalid prompt: The messages do
not match the ModelMessage[] schema.`).

**Retired because** upstream fixed the same class of bug itself: PR
[#25921](https://github.com/twentyhq/twenty/pull/25921), merged 2026-09-14, ships
`normalize-tool-output-to-json-values.util.ts` wired into the tool registry. It is in
every image from v2.40.2 on, which is what this deployment runs.

Verified retired on this host: the container's `tool-executor.service.js` matches the
upstream pristine file, and the `output-transforms/normalize-tool-output-to-json-values.util.js`
utility is present in both server and worker. `~/twenty/patches/apply-json-safe-tool-output.sh`
self-skips on v2.40.2+. Nothing to carry. `scripts/verify-local-patches.sh` asserts this
stays true.

## Update flow

```bash
# prepare and verify an image without touching the running stack
bash scripts/update-twenty.sh --target twenty/v2.43.0 --no-deploy

# the real thing (asks for confirmation; DB dump -> deploy -> smoke -> auto-rollback)
bash scripts/update-twenty.sh --target twenty/v2.43.0
```

What the script does, in order, and what it refuses to skip:

1. **Resolve the target** (`--target`, else the newest `twenty/v*` tag).
2. **Fetch the tag, rebase the patch branch.** A conflict aborts the run and leaves the
   branch untouched; nothing is deployed. It then asserts the source patch survived
   (5 wrapped factories + the header constant in the tree).
3. **Build** (mode `derived`, default): pull `twentycrm/twenty:vX.Y.Z`, extract the
   pristine compiled file from that image, generate the patched file, build the derived
   image `twentycrm/twenty:goku-vX.Y.Z-p<N>` pinned to the base digest.
   Re-running with the same target and patch revision skips the build when the image
   already carries the expected file hash.
   Mode `source` builds the monorepo from the fork instead; it requires
   `ALLOW_HEAVY_BUILD=1` because the frontend stage wants an 8 GB heap and this host
   has 11 GB total.
4. **Probe the built image** (13/13) before anything is deployed.
5. **No-op detection:** if the running container already runs exactly this image, the
   script stops.
6. **Deploy:** `pg_dumpall` to `/home/ubuntu/backups/twenty/` (gzip-verified and
   size-checked), retag the currently running image as `goku-prev-<stamp>` so rollback
   never depends on a movable tag, write state, set `TAG=` in `/home/ubuntu/twenty/.env`
   (`.env` is backed up first), `docker compose up -d server worker`, then wait for
   `/healthz`.
7. **Smoke test** (`post-upgrade-smoke.sh`): containers, local + public HTTP, reported
   `appVersion`, patched file sha in *both* containers, the probe inside the running
   server, and no `missing x-opencode-session` in the worker log.
8. **Rollback on any failure:** restore the previous `TAG` from state and bring the
   previous image back up (the image itself was retagged, so it cannot be garbage
   collected).

The DB/workspace upgrade is not a separate step: the image entrypoint runs
`cache:flush → command:prod upgrade → cron:register:all` on every boot, before the web
server exists. `--pre-upgrade` runs it in a one-off container first; it is off by
default because applying the new schema while the old code still serves is the riskier
order.

## Known limits

- **`latest` is not a pin.** On 2026-09-28 Docker Hub's `latest` already pointed at
  `v2.43.0` (digest `sha256:b2b662b1bef1ea9439edcbcb4f9fe648eeff1cd3fa385ac63e8a8dbd26eb46b2`),
  while this host still runs v2.40.2. Any unplanned `docker compose pull` would move
  the deployment. The script always writes an explicit `TAG=`, which removes that
  exposure.
- **No agent can confirm a real chat turn.** The probe and the log check are the
  strongest available evidence outside the browser; the end-to-end proof is one
  message in the CRM web UI.
- **Second artifact in derived mode.** The generated JS is a transform of the
  compilable source patch, verified by the probe, but it is not literally the
  compiler's output for the patched source. Mode `source` removes that gap at the cost
  of a full monorepo build (see above); a GitHub Actions build on this fork and a
  `ghcr.io` pull is the clean middle path if that gap ever matters.
- **Fork hygiene.** Keep `main` a pure mirror of `upstream/main` and keep patches on
  `goku/*` branches; `scripts/update-twenty.sh` rebases, so a merge into the patch
  branch would make every later update conflict.
