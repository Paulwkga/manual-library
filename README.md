# Snap Manual

An offline iPhone app holding a personal library of industrial equipment manuals
(Allen-Bradley and similar), built to answer equipment questions faster than opening the
PDF by hand.

**The one hard requirement:** a fault-code lookup puts the relevant manual page on screen
in under one second, with no network. Everything else is subordinate to that.

## Status

Nothing is built yet. Current position: **pre-M0**.

| | |
|---|---|
| API verification | Done — see [`docs/api-verification.md`](docs/api-verification.md) |
| M0 — conversion spike | **Blocked.** Needs one real manual PDF and a Mac with Xcode. |
| M1 and later | Not started |

M0 is a spike, not a feature. Its only job is to answer whether PDF-to-markdown conversion
preserves fault-code tables. If the answer is no, the approach gets rethought before any UI
work happens.

## The three tiers

Built in order 3 → 2 → 1. Each tier is independently useful and degrades into the one below.

- **Tier 3 — no model.** Text search over the library finds the fault code, the app shows the
  manual page. Deterministic, instant, no AI. This is the core product.
- **Tier 2 — Apple's on-device model.** Resolves ambiguous phrasing, ranks candidate manuals,
  summarises the excerpt. Free, offline, no download.
- **Tier 1 — local MLX model.** Optional, built last, only if tier 2 proves the summary is
  worth having when the system model is down.

The AI layer is a convenience, never a dependency. With every model on the device unavailable,
the app must still fully answer a fault-code question.

## Hard constraints

These are not preferences. Violating one means the build is wrong.

1. **No network calls.** Not for AI, not for analytics, not for anything. The app must work in
   a plant basement with no signal.
2. **Tier 3 works with no model available**, at every point in the build. Tested by turning off
   Apple Intelligence in Settings, not by mocking.
3. **No model call is ever on the critical path to displaying a page.** The PDF page renders
   first; summaries stream in after, or never.
4. **One second, device floor.** Fault code typed to page displayed, on an iPhone 16 Pro Max.
   Measured, not estimated.
5. **Guided generation only.** `@Generable` for structured model output — never prompt for JSON
   and parse strings.
6. **Size classes, not device checks.** The app never branches on whether the device folds.
7. **Conversion streams; it does not buffer.** Peak memory during import must not scale with
   document size. Verified with a memory graph, not by reasoning.
8. **PDFKit and Vision only.** No commercial PDF SDK.
9. **No manual content ships with the app, ever.** Manuals are user-supplied, stored on-device,
   never bundled and never uploaded.

### Two traps worth naming

**Never construct `PrivateCloudComputeLanguageModel`.** It is a first-class conforming type in
the Foundation Models framework and slots into the same `LanguageModelSession` as the on-device
model — it is one line away from the correct code, and plenty of sample code uses it. It is a
network call to Apple's servers and violates constraint 1. The cloud fallback was considered
and deliberately rejected.

**No PDFs in this repository.** Manuals belong on the device, not in version control. `.pdf` is
gitignored for that reason; don't override it, even for a test fixture.

## Dependencies

None, and each new one gets justified first. Every dependency is something that has to be
maintained alone in three years. The stack is Swift, SwiftUI, SwiftData, PDFKit, Vision, and
SQLite FTS5 — all Apple system frameworks with no fee, no key, and no approval.

## Repository layout

```
docs/
  plan.md                 the specification
  prompt.md               the working agreement
  api-verification.md     Apple API surface confirmed against current docs, pre-M0
```

`plan.md` is the specification and `prompt.md` is the working agreement — read `plan.md` first.
`api-verification.md` records what was confirmed against Apple's documentation before any code
was written, which parts of the plan need correcting as a result, and what could not be
verified. It also lists the open decisions blocking M0.
