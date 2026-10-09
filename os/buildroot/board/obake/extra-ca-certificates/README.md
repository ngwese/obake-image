# Extra CA certificates

Drop additional root CA certificates here as PEM files named `*.crt`.
They are merged into the system trust store
(`/etc/ssl/certs/ca-certificates.crt`) at image build time so host TLS
clients (curl, Singularity, OpenSSL) trust servers signed by those roots.

Rules:

- PEM-encoded root certificates only (`*.crt`).
- Do not place private keys or intermediate-only chains here.
- An empty directory (no `*.crt` files) is the default and is fine.

After adding or removing certificates, rebuild the image for the change
to take effect.
