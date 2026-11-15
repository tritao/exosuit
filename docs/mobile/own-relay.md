# Your own relay

The relay is a small Cloudflare Worker (`relay/worker`). The editor and the phone both talk to it. The Worker that
Exosuit shipped with belongs to someone else's Cloudflare account, so you run your own. The free plan is enough.

Nothing in the Worker is tied to an account. The account comes from your login.

## What you do once

Log in to Cloudflare. This opens a browser, so only you can do it:

```
node C:\Users\corbi\projects\exosuit-wt\mobile\mobile-relay\relay\worker\node_modules\wrangler\bin\wrangler.js login
```

If you have never used Workers, also open https://dash.cloudflare.com, go to Workers and Pages, and pick a
`workers.dev` subdomain once. The deploy needs one.

## What the coordinator then runs

Deploy (checks the login, uploads, probes the Worker, prints the URL):

```
pwsh -NoProfile -File relay\worker\scripts\deploy-own.ps1
```

Use `-Name` for another Worker name, `-AccountId` if your login has several accounts, `-DryRun` to build without
uploading. The script prints two lines: `https: https://exosuit-relay.<you>.workers.dev` and the same as `wss:`.

Point the editor at it. Either type the https URL in the Remote Access panel (the Relay URL field), or set it in
Settings under Remote access, "Relay URL" (`remote/access/relay_url` in `settings.json`). It is saved and survives
restarts. Empty means the old default.

If remote access was already enabled with another relay, press "Use a different relay" in the panel first. Devices
paired through the old relay stop working and must pair again.

The phone needs no setting. The pairing invitation carries the relay address, so paste or share a new invitation.
The phone trusts the public certificate of `workers.dev` through Android's own roots. The desktop uses WinHTTP with
the Windows store. No local CA is needed.

Real-relay end to end (the emulator has internet; use the Android environment from `docs/mobile/android.md`):

```
pwsh -NoProfile -File scripts\e2e-local.ps1 run -RelayUrl https://exosuit-relay.<you>.workers.dev
```

(`-RelayUrl` skips the local Worker, the local CA and the TLS front, and writes that URL into the isolated editor's
settings.) Until that switch is used, `e2e-local.ps1 run` still starts the local Worker.

## What local development hides

- TLS. `wrangler dev` is plain http behind a test proxy and a local CA. The real Worker uses a public certificate. The
  phone's CA export (`TlsTrust.kt`) has only been exercised against the local CA.
- Durable Object migrations. `wrangler.jsonc` declares migration `v1` (`new_sqlite_classes: MachineRelay`). The first
  deploy creates the class. On the free plan only SQLite-backed Durable Objects are allowed, which this is. Never edit
  `v1`; add `v2` for a change.
- Frame size. The Worker closes a socket that sends a frame over 64 KiB. The apps cap a stream message at 65487 bytes,
  so a large file read or terminal burst must be split by the service. Cloudflare itself allows 1 MiB messages.
- Limits of the free plan. About 100,000 Worker requests a day and 100,000 Durable Object requests a day. An incoming
  WebSocket message counts as a fraction of a request (20 messages to 1). Duration is billed in GB-seconds; hibernation
  (`acceptWebSocket`) keeps an idle machine socket cheap. A busy terminal stream sends many small messages, so watch
  the dashboard after a day of real use.
- CPU time. A Worker invocation gets 10 ms of CPU on the free plan. The Worker only routes frames and hashes tokens,
  well under that, but it is only measured locally in milliseconds of wall time.
- Hibernation. Eviction while sockets are open is not exercised by the local test runtime (see the Worker README). The
  real relay does it. If a phone stays connected but stops receiving after a quiet period, that is the first place
  to look.
- Origins. Native clients send no `Origin` header and are accepted. A page from an origin not in `ALLOWED_ORIGINS` is
  refused. Pass `-AllowedOrigins` to the script if a browser client is hosted.
- First claim. The first machine to register an id owns it. suit derives each relay's id from a Noise key made for that
  relay, and proves the key when someone else registered the id first (`docs/mobile/relay-identity.md`); a relay set
  up before that keeps the catalog id, which every old invitation shows. The Worker has no account system or abuse
  control. Do not publish the URL.
