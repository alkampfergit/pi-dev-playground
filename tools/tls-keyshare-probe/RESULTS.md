# Results from 2026-11-22

Runtime: Node.js 26.11.1, OpenSSL 3.5.9, macOS arm64. The probe used TLS
connections only; it sent no model name, HTTP request, or API key.

## Azure endpoint

Command:

```bash
node probe.mjs --host alkampferaiok-resource.services.ai.azure.com --count 20
```

All attempts used `51.12.73.214`; the three settings in each set used that
same IP.

| Client setting | Successful handshakes | Failures |
| --- | ---: | --- |
| Node default | 9/20 | 11 `ECONNRESET` |
| `X25519`, TLS 1.3 | 0/20 | 20 `ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION` |
| `X25519MLKEM768:X25519`, TLS 1.3 | 0/20 | 20 `ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION` |

The intermittent `ECONNRESET` is reproducible with Node's TLS client and no
Pi process. This excludes Pi's skills, extensions, prompts, and model routing
as necessary causes of that reset. The two forced group settings both fail in
the same way, so these runs do **not** isolate ML-KEM as the cause. A separate
unforced Node connection successfully negotiated TLS 1.3 with this endpoint;
the forced group alerts therefore do not show that Azure lacks TLS 1.3.

The IP address identifies the front door reached by the client. It does not
identify a particular backend or the device that sent a reset. Packet capture
or tests from another network would be needed to narrow that down.

## Cloudflare control

```bash
node probe.mjs --host cloudflare.com --count 3
```

IPv4 only: Node default, X25519, and hybrid-first each succeeded **3/3**.
An earlier two-group run with `--count 20` succeeded **20/20** for both
X25519 and hybrid-first. This shows the local Node/OpenSSL build can complete
both explicit-group handshakes with a different host.

Full per-attempt logs were written locally under `results/`, which is ignored
by Git. Re-run the commands to collect fresh evidence because network behavior
can change.
