# Verification fixtures

`verify-x86_64.sif` and `verify-arm64.sif` are tiny Singularity images used
only by `VERIFY=1` guest checks to prove the host can run a local SIF as the
`obake` user (setuid helper + kernel SquashFS) and can use `--fakeroot`.
Production images do not ship them.

`install-verify.sh` embeds the fixture that matches the guest architecture
(`x86_64` → `verify-x86_64.sif`, `aarch64` → `verify-arm64.sif`) as
`/opt/obake/verify.sif`.

Both SIFs are built from `verify.def`. Regenerate with Singularity CE or
Apptainer (fakeroot or root). Prefer a native builder for each arch. When
cross-building, load distinctly tagged Alpine images so the daemon cannot
serve the wrong platform for `alpine:3.20`:

```sh
docker buildx build --platform linux/amd64 \
  -t obake-verify-alpine:amd64 --load - <<'EOF'
FROM alpine:3.20
EOF
docker buildx build --platform linux/arm64 \
  -t obake-verify-alpine:arm64 --load - <<'EOF'
FROM alpine:3.20
EOF
```

Then build each SIF from `docker-daemon://obake-verify-alpine:<arch>` (same
`%runscript` as `verify.def`), or on a native host:

```sh
singularity build --fakeroot --force verify-arm64.sif verify.def
singularity build --fakeroot --force verify-x86_64.sif verify.def
```

Confirm architecture after a rebuild:

```sh
singularity sif header verify-x86_64.sif   # Primary Architecture: amd64
singularity sif header verify-arm64.sif   # Primary Architecture: arm64
```
