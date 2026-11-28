# Tidings (tidings-mail)

Native macOS (iOS later) IMAP/SMTP mail client. **Read `docs/SPEC.md` first**; big decisions are in `docs/adr/`, iCloud protocol facts in `docs/research/icloud-imap.md`.

## Layout
- `MailEngine/` — headless Swift package (no AppKit/UIKit/SwiftUI). Sync, IMAP, storage, search, classification, rules.
  - `Sources/MailEngine` library · `Sources/tidings-probe` CLI for live checks · `Tests/`.
- `PushServer/` — `tidings-server`, the always-on push server (ADR 0007): MailEngine on Linux, IDLE per account, APNs, server-side snooze wake and send-later. Its own package (Hummingbird, APNSwift), so the apps never pull in server libraries. Deploy notes in `PushServer/README.md`.
- `App/` — macOS app (`Tidings`) and iPhone/iPad app (`TidingsMobile`) from one XcodeGen `project.yml`; run `xcodegen generate` in `App/` after adding files.
  - `App/Tidings/` is shared; `Mac/` and `iOS/` hold platform-only code (everything else uses `#if os(...)` sparingly, via `Support/Platform.swift`).

## Conventions
- Swift 6, strict concurrency. Engine types are `Sendable`; IO is async.
- `MailEngine` must keep building on Linux (CI job `Engine and push server on Linux`). Apple-only APIs go behind `#if canImport(...)` with a Linux fallback (see `Support/VectorMath.swift`, `DataDetection.swift`, `Iconv.swift`). Linux's regex engine misreads `\u{…}` in patterns: use the literal character.
- UI: pure Apple Liquid Glass + SF Pro + system colors. Do **not** use Magnus's personal web design system here.
- All user-facing strings via String Catalogs (English + Danish).
- Every new action must be keyboard-reachable and appear in the ⌘K palette.
- Performance budgets in SPEC §15 are requirements, not goals.

## Safety rules for live mail
- Never mutate anything in the real iCloud account outside the `Tidings-Test` mailbox; mutations only on messages carrying our `X-Tidings-Test` header (enforced by `TestFence`).
- Agents never send through a real SMTP server; send tests go to Mailpit only.
- Agents never log in to the real iCloud account. Live probes are run by Magnus: the password comes from Keychain (`security add-generic-password -s Tidings -a <address> -w`).
- Automated tests use the local Dovecot container (`MailEngine/TestServer/`).
- Magnus runs the real app from `App/build` (bundle id `hk.gnus.tidings`). Agents test UI only with the **dev copy** (`hk.gnus.tidings.dev`, own data, local Dovecot), never by clicking in the real instance:
  `xcodebuild -project App/Tidings.xcodeproj -scheme Tidings -derivedDataPath App/build-dev PRODUCT_BUNDLE_IDENTIFIER=hk.gnus.tidings.dev build`, then
  `open -n App/build-dev/Build/Products/Debug/Tidings.app --args -TidingsDevServer -TidingsNoCloud`.
- Agents never deploy the push server, never pair a real device with a deployed one, and never send through real APNs. Server tests use the local Dovecot, Mailpit and APNSwift's fake APNs (`APNSTestServer`). Deploying to Coolify and creating the APNs key are Magnus's.
- Agents never let an app talk to CloudKit (it's Magnus's iCloud, even in the dev container): always launch with `-TidingsNoCloud`. Sync logic is tested in the engine (`CloudStateTests`); the live round trip is run by Magnus (ADR 0006).
- Apps are signed with the Creative Oak team (493257NQK3); if a build asks for provisioning, add `-allowProvisioningUpdates`. With Stage Manager on, `osascript -e 'tell application id "hk.gnus.tidings.dev" to activate'` before screenshots.

- iPhone dev copy: run the `TidingsMobile` scheme in the Simulator with `-TidingsDevServer` ticked (Edit Scheme → Arguments); the Simulator reaches the local Dovecot/Mailpit on 127.0.0.1.
- CI (`.github/workflows/build.yml`) builds both apps and runs the engine tests on every push.

## Commands
- `swift build --package-path MailEngine`
- `swift test --package-path MailEngine`
- `MailEngine/TestServer/make-certs.sh && docker compose -f MailEngine/TestServer/compose.yml up -d` — local Dovecot (IMAP, :31143) and Mailpit (SMTP with STARTTLS, :31587; UI/API at http://127.0.0.1:38025) for integration tests. Mailpit catches everything; nothing is delivered.
- `swift run --package-path MailEngine tidings-probe --help`
- Performance budgets (SPEC §15, CI job `Performance budgets`): `swift build -c release --package-path MailEngine --product tidings-bench`, then `tidings-bench seed --dir /tmp/bench` (~4 min, once), `tidings-bench run --dir /tmp/bench --out perf.json`, `tidings-bench compare --current perf.json [--baseline old.json]`. See `docs/performance.md`.
- `swift test --package-path PushServer` — the push server; its end-to-end tests need the local Dovecot and Mailpit.
- Linux check without CI: `docker run --rm --network host -v "$PWD":/src -w /src swift:6.2-noble bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --package-path MailEngine"` (copy the tree first if you don't want a Linux `.build` in it).
- `docker build -f PushServer/Dockerfile -t tidings-server .` — the server image (from the repository root).
- `scripts/release.sh [--publish]` — Mac release: Developer ID export, notarized .dmg, Sparkle appcast, GitHub release (bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml` first). Publishing is Magnus's call.
