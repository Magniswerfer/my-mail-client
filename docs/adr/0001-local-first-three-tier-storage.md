# 0001 · Local-first, three-tier storage

**Status:** accepted · 2026-11-24

## Context
Search must feel as instant as mcmaster.com (< 30 ms per keystroke). Server-side IMAP search is 100s of ms to seconds and weak on iCloud. But a full mirror of a 100k-message mailbox is ~8 GB, mostly attachments and HTML markup, and Magnus doesn't want it eating disk.

## Decision
Three tiers:
1. **Always local (SQLite/GRDB):** headers, thread graph, app state, *compressed plain-text body*, FTS5 index, embeddings, Highlights. ≈ 0.4–0.7 GB per 100k messages.
2. **Cache:** raw MIME/HTML + attachments that were opened, plus the last 30 days. Size-capped LRU, default 2 GB.
3. **Remote:** IMAP server.

Storage location is user-selectable (external drive OK via security-scoped bookmark). Never iCloud Drive (SQLite + iCloud Drive = corruption/eviction).

## Why keep plain text instead of index-only
An FTS index without its text is roughly the same size but can't produce result snippets and can't be re-classified or re-embedded without re-downloading the mailbox.

## Consequences
- Opening an uncached old message costs one IMAP round-trip (~200–500 ms) and needs network.
- Search, sorting and AI work fully offline.
