# Tidings (my-mail-client)

Native macOS (iOS later) IMAP/SMTP mail client. **Read `docs/SPEC.md` first**; big decisions are in `docs/adr/`, iCloud protocol facts in `docs/research/icloud-imap.md`.

## Layout
- `MailEngine/` — headless Swift package (no AppKit/UIKit/SwiftUI). Sync, IMAP, storage, search, classification, rules.
  - `Sources/MailEngine` library · `Sources/tidings-probe` CLI for live checks · `Tests/`.
- `App/` — macOS app (XcodeGen `project.yml`; run `xcodegen generate` in `App/` after adding files).

## Conventions
- Swift 6, strict concurrency. Engine types are `Sendable`; IO is async.
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
  `open -n App/build-dev/Build/Products/Debug/Tidings.app --args -TidingsDevServer`. With Stage Manager on, `osascript -e 'tell application id "hk.gnus.tidings.dev" to activate'` before screenshots.

## Commands
- `swift build --package-path MailEngine`
- `swift test --package-path MailEngine`
- `MailEngine/TestServer/make-certs.sh && docker compose -f MailEngine/TestServer/compose.yml up -d` — local Dovecot (IMAP, :31143) and Mailpit (SMTP with STARTTLS, :31587; UI/API at http://127.0.0.1:38025) for integration tests. Mailpit catches everything; nothing is delivered.
- `swift run --package-path MailEngine tidings-probe --help`
