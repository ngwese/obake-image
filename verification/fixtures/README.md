# Verification fixtures

`verify.sif` is a tiny Singularity image used only by `VERIFY=1` guest checks
to prove the host can run a local SIF as the `obake` user (setuid helper +
kernel SquashFS) and can use `--fakeroot`. Production images do not ship it.

Regenerate (requires Singularity CE with fakeroot or root):

```sh
singularity build --fakeroot --force verify.sif verify.def
```
