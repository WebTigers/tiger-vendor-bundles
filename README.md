# tiger-vendor-bundles

The **Vendor Library Registry** for [Tiger](https://github.com/WebTigers/Tiger) — pre-resolved
bundles of third-party PHP libraries (AWS SDK, Stripe SDK, Guzzle, …) so a **no-Composer shared
host** (GoDaddy, BlueHost, cPanel) can install a library and *all its dependencies* by downloading
one tarball. Dependency resolution happens **here**, once, off the customer's box.

See tiger-core [`DEPENDENCIES.md`](https://github.com/WebTigers/tiger-core/blob/main/DEPENDENCIES.md)
for the full model.

## How it works

A nightly GitHub Actions workflow (`.github/workflows/build-bundles.yml`) runs entirely inside
GitHub — no Lambda, no servers:

1. Reads **`packages.json`** — the tracked packages + which major versions to keep fresh.
2. For each `(package, major)`, `composer require`s the newest version, **skips if already
   published** (so nightly runs are near-free no-ops until upstream actually releases).
3. On a new version: builds a self-contained bundle (the lib + every dependency + an optimized
   Composer autoloader), `sha256`-checksums it, and publishes it as a **GitHub release asset**.
4. Records it in **`bundles.json`** — the index the Tiger provisioner reads to turn a module's
   `{name, constraint}` into a bundle URL + checksum.

## Files

| File | Role |
|---|---|
| `packages.json` | **input** — tracked packages + majors. Add a package here to have it bundled. |
| `bundles.json` | **output** (generated) — the index Tiger's `Tiger_Vendor` resolves against. Don't hand-edit. |
| `build-bundles.sh` | the bot: resolve → skip-if-published → build → checksum → publish → update index. Runs in the workflow or locally (`DRY_RUN=1` to build without publishing). |
| `.github/workflows/build-bundles.yml` | the nightly `cron` (+ manual `workflow_dispatch`) trigger. |

## Adding a library

Add it to `packages.json`:

```json
"stripe/stripe-php": { "tracks": ["^16"] }
```

Track multiple majors when consumers straddle versions (`"tracks": ["^2", "^3"]`) — each major gets
its own bundle line, so a module pinned to the old major keeps getting updates.

## One-time repo setup

The workflow needs the default `GITHUB_TOKEN` to be able to create releases and push the index
commit: **Settings → Actions → General → Workflow permissions → "Read and write permissions"**
(the workflow also declares `permissions: contents: write`). Then `workflow_dispatch` a first run,
or wait for the nightly cron.

## Trust boundary

Bundles are the supply-chain boundary: curated (only what's in `packages.json`), built from
Packagist-resolved sources, and **`sha256`-verified** by the host before use. A Tiger install never
fetches an unvetted, unpinned dependency.
