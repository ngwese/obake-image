# vendor

Pinned build inputs for an obake release, tracked with git-lfs.

- `buildroot-<release>.tar.gz` — the pinned Buildroot release.
- `dl/` — the complete Buildroot download cache: every package source and the
  pinned kernel tarball, exactly as verified by `build.sh`.

`build.sh` uses these directly when present, so a release builds with no
network access. Populate them from a verified online build and commit:

```
image/os/buildroot/vendor.sh
git add image/os/buildroot/vendor
```

`vendor.sh` verifies the Buildroot and kernel SHA-256 hashes before copying.
Bumping a pin in `../pins.json` means rebuilding, re-running `vendor.sh`, and
committing the updated inputs.
