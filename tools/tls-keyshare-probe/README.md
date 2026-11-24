# TLS key share probe

This standalone Node tool compares Node's default TLS handshake, TLS 1.3 with
`X25519`, and TLS 1.3 with `X25519MLKEM768` first and `X25519` as a fallback. It
does not import Pi, call an LLM, send an API key, or make an HTTP request.

Each set connects to the **same IP address** and uses the supplied hostname
for SNI and certificate validation. The order alternates between sets, so a
brief network change does not always favor the same group. Results show the
TCP connection state, handshake latency, protocol, and error code. A successful
`hybrid-first` connection does not by itself reveal which group the server
ultimately negotiated; packet capture is needed for that detail.

## Run on macOS

Use Node.js 26 with OpenSSL 3.5 or later for `X25519MLKEM768` support. No
`npm install` is needed.

```bash
cd tools/tls-keyshare-probe
node --version
node -p 'process.versions.openssl'
node probe.mjs --host cloudflare.com --count 20
node probe.mjs --host YOUR_RESOURCE.services.ai.azure.com --count 20
```

To keep the same Azure IP across separate runs, pass `--ip ADDRESS`. The
normal run already uses the same IP for all three settings in each set.
Use `--timeout-ms 10000` on a slow connection and `--delay-ms 1000` to space
out the sets. Save results with shell redirection when needed:

```bash
node probe.mjs --host cloudflare.com --count 20 > cloudflare-results.txt
```

IPv4 is the default because this Mac currently has no route to Cloudflare's
IPv6 addresses. Pass `--family 6` when you want to test an IPv6 route.

An `ECONNRESET` before `secureConnect` shows the TLS handshake did not finish.
This tool cannot identify which device sent the reset. Compare results from
another network or inspect a packet capture to narrow that down.

The host's model deployment has no effect on this test: TLS finishes before
an HTTP request can contain a model ID. For a full Pi provider request, use
`samples/001-helloworld/test-azure-loop.sh`.
