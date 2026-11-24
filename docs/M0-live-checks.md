# M0 live checks (run by you)

These are the only steps that log in to your real iCloud account. An agent never runs them. Everything else is tested automatically against the local Dovecot server.

## 1. Create an app-specific password
1. Go to account.apple.com → Sign-In and Security → App-Specific Passwords → **+**.
2. Name it `Tidings` and copy the password.

## 2. Store it in your Keychain
```bash
security add-generic-password -s Tidings -a you@icloud.com -w
```
You'll be prompted for the password. It never appears on screen or in shell history.

## 3. Read-only capability check
Logs in, lists folders and runs EXAMINE on INBOX (read-only). Nothing is changed.
```bash
swift run --package-path MailEngine tidings-probe capabilities --address you@icloud.com
```

## 4. Fenced keyword test
Creates `Tidings-Test` and `Tidings-Test/Moved`, uploads one synthetic message from `probe@tidings.invalid`, flags it, moves it, tries up to 40 extra keywords on it, and then deletes **only messages carrying this run's `X-Tidings-Test` header**. Nothing else in your mailbox can be touched: the fence refuses any other mailbox or message.
```bash
swift run --package-path MailEngine tidings-probe keyword-test --address you@icloud.com --json
```
Paste the output back into the session. The result decides whether `$Pinned`-style keywords get used next to CloudKit (ADR 0002).

You can delete the empty `Tidings-Test` folders afterwards in Mail or on iCloud.com.
