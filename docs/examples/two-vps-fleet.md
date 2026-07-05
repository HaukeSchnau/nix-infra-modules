# Two VPS Fleet Example

The example fleet is synthetic but mirrors a common production shape:

- `core-01` owns application processes and an internal Caddy ingress.
- `edge-01` owns public TLS and forwards generated routes to `core-01`.

Use reserved example domains and addresses only. Do not place real hostnames,
IP addresses, or secret names in this example.
