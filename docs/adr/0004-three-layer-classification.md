# 0004 · Three-layer on-device classification

**Status:** accepted · 2026-11-24

## Context
Running Apple's ~3B on-device model on each of 100k messages at first sync takes hours. Most mail is classifiable from headers.

## Decision
1. **Signals:** deterministic header/sender rules (List-Unsubscribe, Precedence, ESP fingerprints, transactional patterns, prior correspondence).
2. **Fast classifier:** multilingual on-device sentence embeddings → small trainable head; retrained from user corrections.
3. **Foundation Models:** only for low-confidence messages, Highlights, NL rule conditions and summaries.

Corrections stick per sender. Each decision records its layer and reason for "why is this here?".

## Consequences
- Embeddings are stored in tier 1 and reused by semantic search and NL rules.
- Danish system language must be verified for Foundation Models (M0); English prompts as fallback.

## Addendum · 2026-11-26: junk is its own classifier
Spam isn't a seventh category: it runs first (SPEC §6 pipeline), on tokens rather than embeddings (naive Bayes, SpamBayes-style), because junk is told apart by wording, senders and link hosts more than by topic, and it must learn from a handful of corrections. It trains on the server's Junk folder plus your moves in and out of it; see SPEC §8.
