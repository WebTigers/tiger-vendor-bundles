#!/usr/bin/env bash
# build-bundles.sh — the nightly bundle bot.
#
# For each tracked (package, major) in packages.json: resolve the newest version with Composer and,
# WHEN A NEW VERSION HAS DROPPED, build a self-contained pre-resolved bundle (the lib + all its
# dependencies + Composer's optimized autoloader), checksum it, publish it as a GitHub release asset,
# and record it in bundles.json.
#
# The whole point: dependency resolution runs HERE (Composer + a shell), once — so a no-Composer
# shared host only ever downloads one pre-resolved tarball. See tiger-core/DEPENDENCIES.md.
#
# Idempotent: a (package, version) already published is skipped, so nightly runs are cheap no-ops
# until upstream actually releases. Requires: composer, jq, gh (authed via GH_TOKEN), tar.
# Set DRY_RUN=1 to build + checksum locally without touching GitHub releases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="$ROOT/packages.json"
INDEX="$ROOT/bundles.json"
BUILD="$ROOT/.build"
REPO="${GITHUB_REPOSITORY:-WebTigers/tiger-vendor-bundles}"
DRY_RUN="${DRY_RUN:-}"
export COMPOSER_MEMORY_LIMIT=-1
export COMPOSER_NO_INTERACTION=1

for tool in composer jq tar; do
  command -v "$tool" >/dev/null || { echo "!! '$tool' is required"; exit 1; }
done

[ -f "$INDEX" ] || echo '{"schema":"tiger.vendor-bundles/index/v1","bundles":{}}' > "$INDEX"

slugify() { printf '%s' "$1" | tr '[:upper:]/' '[:lower:]-' | sed 's/[^a-z0-9._-]/-/g'; }
sha256()  { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
            else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

built=0
while IFS=$'\t' read -r pkg track; do
  [ -n "$pkg" ] || continue
  echo "::group::$pkg ($track)"
  work="$BUILD/$(slugify "$pkg")__$(slugify "$track")"
  rm -rf "$work"; mkdir -p "$work"

  # Resolve + install without dev deps or install-time plugins (our curated libs need neither),
  # then regenerate an optimized classmap autoloader.
  ( cd "$work"
    composer init -n --name="webtigers/bundle-$(slugify "$pkg")" >/dev/null 2>&1
    # A dependency's own dev-deps are never installed (only the root's), and our root has none — so
    # the tree is runtime-only already. --no-dev applies at dump-autoload time.
    composer require "$pkg:$track" --prefer-dist --no-plugins --quiet
    composer dump-autoload --optimize --no-dev --no-plugins --quiet )

  version="$(jq -r --arg p "$pkg" '.packages[]? | select(.name==$p) | .version' "$work/composer.lock")"
  if [ -z "$version" ] || [ "$version" = "null" ]; then
    echo "  !! could not resolve $pkg:$track — skipping"; echo "::endgroup::"; continue
  fi

  tag="$(slugify "$pkg")-$version"
  if [ -z "$DRY_RUN" ] && gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
    echo "  == $tag already published — skip"; echo "::endgroup::"; continue
  fi

  # Assemble: autoload.php (entry) + vendor/ (the pre-resolved tree) + bundle.json (metadata).
  stage="$BUILD/stage-$tag"; rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$work/vendor" "$stage/vendor"
  printf '<?php\n// Pre-resolved bundle (tiger-vendor-bundles). Loads the flattened Composer autoloader.\nrequire __DIR__ . "/vendor/autoload.php";\n' > "$stage/autoload.php"
  jq -n --arg n "$pkg" --arg v "$version" \
        '{schema:"tiger.vendor-bundles/bundle/v1", name:$n, version:$v}' > "$stage/bundle.json"

  # The asset filename is stable (bundle.tar.gz) so the URL is predictable per release tag.
  tarball="$BUILD/bundle.tar.gz"
  tar -czf "$tarball" -C "$stage" .
  sha="$(sha256 "$tarball")"
  url="https://github.com/$REPO/releases/download/$tag/bundle.tar.gz"
  echo "  ++ $pkg $version  ($(du -h "$tarball" | cut -f1))  sha256=$sha"

  if [ -z "$DRY_RUN" ]; then
    gh release create "$tag" "$tarball" -R "$REPO" \
       --title "$pkg $version" \
       --notes "Pre-resolved bundle of \`$pkg $version\` (+ dependencies, optimized autoloader). sha256 \`$sha\`." >/dev/null
  fi

  # Record the newest build for this track in the index.
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  jq --arg p "$pkg" --arg t "$track" --arg v "$version" --arg u "$url" --arg s "$sha" --arg b "$ts" \
     '.bundles[$p][$t] = {version:$v, url:$u, sha256:$s, built:$b}' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"

  built=$((built + 1))
  echo "::endgroup::"
done < <(jq -r '.packages | to_entries[] | .key as $p | .value.tracks[] | [$p, .] | @tsv' "$PACKAGES")

echo "Done. New bundles this run: $built"
