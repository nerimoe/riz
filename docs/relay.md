# Riz Relay

Riz Relay removes the need to expose `rizd` with a per-machine tunnel. The
daemon opens outbound WebSocket channels to a Cloudflare Worker. A client that
has the pairing code connects to the same Durable Object room, which assigns a
dedicated daemon channel to that client.

The public relay for this repository is:

```text
https://riz-relay.zzx2022766809.workers.dev
```

Configure an existing daemon and print a new pairing code:

```sh
rizd relay configure --url https://riz-relay.zzx2022766809.workers.dev
```

Restart the `rizd` user service after changing relay configuration. A fresh
installation does this automatically.

Paste the resulting `riz1...` value into the Riz add-connection dialog. The
pairing code contains both a relay-room credential and a separately revocable
daemon bearer token. Treat it like a password. Neither credential is placed in
the WebSocket URL. The relay credential is carried as a versioned WebSocket
subprotocol because browser WebSocket APIs cannot set an Authorization header.

The relay validates a SHA-256 hash of the room credential and forwards text and
binary frames without interpreting the Riz protocol. The daemon still performs
its normal first-frame bearer authentication. Several clients can connect at
once; each is assigned a separate outbound daemon channel.

Cloudflare terminates TLS at its edge, so this is encrypted in transit but is
not application-level end-to-end encryption. Deploy the Worker under an account
you trust. Application-level encryption can be added later without changing the
daemon/project/session model.

## Self-hosting

```sh
cd relay
npm install
npm run check
npm test
npm run deploy
```

Then pass the resulting Worker origin to `rizd relay configure`. The Worker uses
one SQLite-backed Durable Object class named `RelayRoom`; no account database,
HTTP bearer endpoint, or URL token is required.
