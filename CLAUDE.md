# Tidings (my-mail-client)

Native macOS (iOS later) IMAP/SMTP mail client. **Read `docs/SPEC.md` first**; big decisions are in `docs/adr/`, iCloud protocol facts in `docs/research/icloud-imap.md`.

## Layout
- `MailEngine/` — headless Swift package (no AppKit/UIKit/SwiftUI). Sync, IMAP, storage, search, classification, rules.
  - `Sources/MailEngine` library · `Sources/tidings-probe` CLI for live checks · `Tests/`.
- `App/` — macOS app (XcodeGen `project.yml`), arrives in M1.

## Conventions
- Swift 6, strict concurrency. Engine types are `Sendable`; IO is async.
- UI: pure Apple Liquid Glass + SF Pro + system colors. Do **not** use Magnus's personal web design system here.
- All user-facing strings via String Catalogs (English + Danish).
- Every new action must be keyboard-reachable and appear in the ⌘K palette.
- Performance budgets in SPEC §15 are requirements, not goals.

## Safety rules for live mail
- Never mutate anything in the real iCloud account outside the `Tidings-Test` mailbox; mutations only on messages carrying our `X-Tidings-Test` header (enforced by `TestFence`).
- Agents never log in to the real iCloud account. Live probes are run by Magnus: the password comes from Keychain (`security add-generic-password -s Tidings -a <address> -w`).
- Automated tests use the local Dovecot container (`MailEngine/TestServer/`).

## Commands
- `swift build --package-path MailEngine`
- `swift test --package-path MailEngine`
- `docker compose -f MailEngine/TestServer/compose.yml up -d` — local IMAP for integration tests
- `swift run --package-path MailEngine tidings-probe --help`
