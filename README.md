# tiger-vendor-bundles

The **Vendor Library Registry** for [Tiger](https://github.com/WebTigers/Tiger) — pre-resolved
bundles of third-party PHP libraries (AWS SDK, Stripe SDK, Guzzle, …) so a **no-Composer shared
host** (GoDaddy, BlueHost, cPanel) can install a library **and all of its dependencies** by
downloading **one tarball**.

> **The one idea:** dependency resolution is hard, so we do it **here, once, off the customer's
> box** — never on a shared host that has no Composer. This repo's nightly bot resolves each library
> with Composer, freezes the result (lib + every dependency + an autoloader) into a checksummed
> tarball, and publishes it. A Tiger install just downloads and unpacks it.

Full model: tiger-core [`DEPENDENCIES.md`](https://github.com/WebTigers/tiger-core/blob/main/DEPENDENCIES.md).

---

## The lifecycle of a bundle (follow it end to end)

```
  packages.json                 ← YOU declare a tracked lib + its majors (e.g. aws/aws-sdk-php: ^3)
        │
        ▼   nightly GitHub Actions (build-bundles.sh)
  composer require aws/aws-sdk-php:^3     ← resolve the newest 3.x + ALL its deps, HERE
        │   (skip if that exact version is already published — delta-gated)
        ▼
  a self-contained bundle:  autoload.php + vendor/ (lib + guzzle + psr7 + …)
        │   tar + sha256
        ▼
  GitHub Release asset  +  bundles.json   ← the INDEX: name+major → {version, url, sha256}
        │
        ▼   ── the boundary: everything above is us, everything below is a customer's host ──
        │
  Tiger_Vendor::ensure({name:'aws/aws-sdk-php', constraint:'^3'})   ← a module DECLARED this dep
        │   reads bundles.json, picks the newest bundle satisfying ^3, verifies sha256
        ▼
  vendor-libs/aws-aws-sdk-php/   ← the ONE shared copy on the host (unpacked, checksum-verified)
        │
        ▼   at bootstrap: Tiger_Vendor::registerAutoloaders()
  every module can now use  Aws\S3\S3Client  — with zero resolution done on the host
```

The host never runs Composer, never sees the dependency graph, and never fetches an unpinned blob —
it downloads one vetted, checksummed, pre-resolved tarball and unpacks it.

---

## The collision guardrail — why you can't get "two Stripe bundles"

This is the rule that keeps the system safe, and it's worth understanding before you add anything.

**One shared copy per library. One version per install. Modules *declare*, they never *bundle*.**

- **Shared store, keyed by name.** A provisioned PHP lib lives once, in the host's
  `vendor-libs/<package>/` — *not* inside any module. Two modules that both need Stripe resolve to
  the **same** store directory, so the second install **reuses** the first. There is physically only
  one `stripe/stripe-php` on the host, autoloaded for everyone. No duplicates.
- **The one-version rule, enforced in code.** `Tiger_Vendor::ensure()` reuses the installed copy
  **only if its version satisfies the new module's constraint**. If module A installed Stripe `^16`
  and module B demands `^17`, Tiger does **not** silently double-install or silently downgrade — it
  returns a **`conflict`** the operator must resolve. You can't load two majors of `Stripe\` in one
  PHP process anyway (Composer forbids it too); we make that honest instead of a mystery breakage.
- **Declare, don't bundle.** A module's `module.json` **declares** `dependencies.php` (name +
  constraint). It must **never** commit a copy of Stripe/AWS into its own tree or vendor it
  privately — that's exactly what creates the colliding, un-deduped, un-versioned second copy. Let
  the shared store own it.

**So: a library belongs *either* to the shared registry (this repo) *or* nowhere — never in two
places.** If a lib is here, modules point at it; they don't carry their own.

---

## When a package belongs here — and when it doesn't

**Add it here** when it's a **shared PHP library** that one or more modules need at runtime and that
has real dependencies a no-Composer host couldn't resolve:

- ✅ `aws/aws-sdk-php`, `stripe/stripe-php`, `guzzlehttp/guzzle`, `phpmailer/phpmailer`, `monolog/monolog`.

**Do *not* add it here** when:

- ❌ **It's a front-end asset, not a PHP library.** Swagger UI, a JS charting lib — those are an
  **`asset` dependency inside the module** (fetched into the module's `assets/`), *not* a PHP bundle.
  (Bundling Swagger UI here would be the classic mistake — it has no PHP to autoload.)
- ❌ **A specific module already owns it privately** for a good reason, or it's trivially pure-PHP the
  module can ship inline. If it's not meant to be *shared*, it doesn't belong in a *shared* registry.
- ❌ **Nothing in Tiger actually declares it.** The registry is demand-driven — a bundle exists
  because a module (or the platform) declares the dependency, not speculatively.

Rule of thumb: **one home per library.** A lib is a shared PHP bundle here, *or* a module's private
asset, *or* Composer-managed in `vendor/` — never two of those at once.

---

## Files

| File | Role |
|---|---|
| **`packages.json`** | **input** you edit — tracked packages + which majors to keep fresh. |
| **`bundles.json`** | **generated output** — the index `Tiger_Vendor` resolves `{name, constraint}` against. Never hand-edit. |
| **`build-bundles.sh`** | the bot: resolve → skip-if-published → build → checksum → publish → update index. `DRY_RUN=1` builds locally without publishing. |
| **`.github/workflows/build-bundles.yml`** | nightly `cron` (+ manual `workflow_dispatch`), all inside GitHub — no Lambda, no servers. |

### `packages.json` (what you edit)

```json
{
  "packages": {
    "aws/aws-sdk-php":   { "tracks": ["^3"] },
    "stripe/stripe-php": { "tracks": ["^16", "^17"] }
  }
}
```

`tracks` lists the **major constraints** to keep fresh. Track two majors when consumers straddle
versions — each gets its own bundle line in the index, so a module pinned to the old major still
receives updates. That's the *supported* way to have two Stripe majors: two index lines, one
installed per host (whichever the host's modules resolve to), never two on the same box.

### `bundles.json` (generated — what Tiger reads)

```json
{
  "bundles": {
    "aws/aws-sdk-php": {
      "^3": { "version": "3.301.5", "url": "https://github.com/.../bundle.tar.gz",
              "sha256": "…", "built": "2026-07-11T06:00:00Z" }
    }
  }
}
```

`Tiger_Vendor` fetches this, finds the package, and picks the **newest** entry whose `version`
satisfies the module's constraint — then verifies the `sha256` before trusting the download.

---

## Adding a library

1. Add it to `packages.json` (name + majors).
2. Commit. The nightly run builds + publishes it (or trigger it now: **Actions → Build vendor
   bundles → Run workflow**).
3. A module then declares it in `module.json`:
   ```json
   "dependencies": { "php": [ { "name": "aws/aws-sdk-php", "constraint": "^3" } ] }
   ```
   On install, `Tiger_Vendor` resolves it through the index and drops the one shared copy into the
   host's `vendor-libs/`.

That's the whole contract — you never touch `bundles.json`, never hand-place a tarball, and never
copy a library into a module.

---

## Why this repo is public (and why that's safe)

It has to be: a no-Composer host fetches `bundles.json` and the release tarballs over plain HTTPS with
no credentials — public means the provisioner needs no auth on the customer's box. That's safe
because the registry is the **trust boundary**:

- **Curated** — only what's in `packages.json` is ever built; nothing arbitrary.
- **Pinned** — bundles are built from Packagist-resolved, exact versions.
- **Checksummed** — every bundle carries a `sha256` that the host **verifies before use**, so a
  tampered download is rejected.

A Tiger install therefore never runs unvetted code — public artifacts, private trust via checksums.

---

*One home per library, one version per install, resolution done off-box. Follow the lifecycle above
and there's no way to end up with two colliding Stripe bundles.*
