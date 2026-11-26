# tidings-server

The always-on push server from [ADR 0007](../docs/adr/0007-push-server.md). It runs `MailEngine` on Linux and does four things:
- holds one IMAP IDLE connection per account;
- sends an APNs alert to your iPhones when new mail deserves one;
- moves snoozed mail back to the Inbox when its time comes;
- sends mail you scheduled for later.

It moves nothing else on the mail server.

```
PushServer/
  Sources/TidingsPush/   engine (PushEngine), HTTP API, APNs sender, server database, secrets
  Sources/tidings-server/ main: reads the environment, starts the engine and the HTTP server
  Tests/                 unit tests, and end-to-end tests against the local Dovecot, Mailpit and a fake APNs
  Dockerfile             built from the repository root
```

## Run it locally

You need the test servers from `MailEngine/TestServer` (see `CLAUDE.md`).

```bash
swift test --package-path PushServer
```

```bash
TIDINGS_PAIRING_SECRET=a-long-local-pairing-secret TIDINGS_MASTER_KEY=$(openssl rand -base64 32) TIDINGS_DATA_DIR=/tmp/tidings-server swift run --package-path PushServer tidings-server
```

Without `APNS_KEY_P8`, the server syncs, wakes snoozes and sends scheduled mail, but sends no pushes.

## Environment

| Variable | Required | What |
|---|---|---|
| `TIDINGS_PAIRING_SECRET` | yes | What a device enters once to pair. At least 16 characters; use `openssl rand -base64 24`. |
| `TIDINGS_MASTER_KEY` | yes | 32 bytes, base64 (`openssl rand -base64 32`). It encrypts the stored passwords. If you lose it, the stored passwords are lost too: enter them again in the app. |
| `APNS_KEY_P8` | for push | The contents of the `.p8` file. Real newlines or `\n` both work. |
| `APNS_KEY_ID` | with the key | The key's ID, from the developer portal. |
| `APNS_TEAM_ID` | no | Defaults to `493257NQK3` (Creative Oak). |
| `APNS_TOPIC` | no | Defaults to `hk.gnus.tidings`. Use `hk.gnus.tidings.dev` for the dev copy. |
| `TIDINGS_DATA_DIR` | no | Defaults to `/data`. Holds `server.sqlite`, `mail.sqlite` and a small cache. |
| `PORT` | no | Defaults to `8080`. |
| `TIDINGS_POLL_SECONDS` | no | How often Sent and Snoozed are re-synced next to INBOX's IDLE. Defaults to 300; the minimum is 30. |
| `TIDINGS_PLAINTEXT_IMAP_HOSTS` | no | Extra hosts allowed without TLS, comma-separated. Use it for tests only. |
| `LOG_LEVEL` | no | Defaults to `info`. Logs never contain addresses (only `ma…@icloud.com`), subjects or bodies. |

## Deploy on Coolify

These are notes for Magnus. Nothing has been deployed. Deploying is your call, and so is the choice of server.

1. **Make the APNs key.** At developer.apple.com, go to Certificates, Identifiers & Profiles, then Keys. Add a key with **Apple Push Notifications service (APNs)** in team 493257NQK3. Download the `.p8` file; Apple only lets you download it once. Note the Key ID.
2. **Create the app.** In Coolify, add a new resource: an application from this Git repository.
   - Build pack: **Dockerfile**.
   - Base directory: `/`.
   - Dockerfile location: `/PushServer/Dockerfile`.
3. **Add a volume.** Add persistent storage mounted at `/data`. Back it up: it holds your encrypted passwords and paired devices. Without the master key, the backup can't be read.
4. **Set the environment.** Add the variables from the table above. Mark `TIDINGS_PAIRING_SECRET`, `TIDINGS_MASTER_KEY` and `APNS_KEY_P8` as secrets, and never put them in the repository.
5. **Set the domain and port.** Give the app a domain such as `https://push.<your domain>`; Coolify's proxy terminates TLS. The exposed port is `8080`, and the health check path is `/health`.
6. **Deploy.** The log should say `push engine started`. Once the key is set, `APNS_KEY_P8 not set` should not appear.
7. **Pair your devices.** On the iPhone, go to Settings › Notifications › Push Server, enter the address and the pairing secret, then tap **Pair This Device**. Your other devices get the address and secret through iCloud Keychain and pair themselves.
8. **Give the server its passwords.**
   - At account.apple.com, make an app-specific password named "Tidings Push".
   - In the same Settings section, tap **Add Password…** next to the account and paste it.
   - The account should then say "Watching for new mail".
   - To cut the server off, revoke "Tidings Push". Your devices keep working.

Debug builds register **sandbox** push tokens, and TestFlight and App Store builds register **production** tokens. The server picks the matching endpoint for each device, so one deployment serves both.

### Connections

iCloud allows about 3 IMAP connections per account. The server uses 1 all the time, for IDLE on INBOX. It opens a second, short-lived one only when it polls Sent and Snoozed or sends mail.

## API

`MailEngine/Sources/MailEngine/Push/PushAPI.swift` documents the calls, and `PushServerClient` is the app's client for them.
- Every call except `POST /v1/devices` and `GET /health` needs `Authorization: Bearer <device token>`.
- Device tokens are stored only as SHA-256 hashes.
- After 5 wrong pairing secrets in a minute, pairing pauses for that minute.
