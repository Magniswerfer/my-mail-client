# 0003 · MailEngine is a headless Swift package

**Status:** accepted · 2026-11-24

## Context
Snoozes must wake, rules must run and send-later must fire even when the window is closed. iOS can't hold IMAP connections in the background. A future always-on server (e.g. on Coolify) would fix iOS push and 24/7 rules.

## Decision
- All sync, storage, search, classification and rules live in `MailEngine`, a Swift package with **no AppKit/UIKit/SwiftUI imports**. Platform services (Keychain, Foundation Models, CloudKit) sit behind protocols.
- v1 runs the engine in a login-item background helper on the Mac.
- Keep the engine Linux-buildable where practical so a headless server is a later option.

## Consequences
- UI talks to the engine through an observable store / XPC boundary, never directly to SQLite.
- Foundation Models is unavailable on Linux; a server would skip the LLM layer or delegate it.
