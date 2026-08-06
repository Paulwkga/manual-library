# Snap Manual — Pre-M0 API Verification

Date: 2026-08-06
Scope: Foundation Models, App Intents, PDFKit text extraction, Vision OCR.
Method: Apple's documentation JSON endpoints (`developer.apple.com/tutorials/data/documentation/…`)
and WWDC26 session transcripts. The rendered HTML doc pages are JavaScript-built and return
empty to a fetcher; the JSON endpoints return the real symbol graph including availability
and beta flags.

Nothing here is from memory. Where I could not confirm something, it is in §8.

---

## 1. The headline: iOS 27 is not shipped

Xcode 27 / iOS 27 are at **beta 4** as of early August 2026. Public release is presumably
September 2026, consistent with Apple's usual cycle.

This matters because most of what `plan.md` §7 is counting on from "the WWDC 2026 changes" is
**iOS 27.0+ and marked beta**:

| Capability | Symbol | Availability |
|---|---|---|
| Provider swapping | `LanguageModel` protocol | iOS 27.0+, beta |
| Custom model execution | `LanguageModelExecutor` | iOS 27.0+, beta |
| Local MLX models | `MLXLanguageModel` (separate SPM package) | iOS 27+ |
| Built-in semantic search | Spotlight search tool | iOS 27, beta |
| Image input | `Attachment`, `ImageAttachmentContent` | beta |
| Cloud model | `PrivateCloudComputeLanguageModel` | beta — **do not use, see §3.4** |

What is **stable and shipping today on iOS 26.0**: `SystemLanguageModel`,
`LanguageModelSession`, `Prompt`, `Instructions`, `Transcript`, `GenerationOptions`,
`GenerationSchema`, `GeneratedContent`, `Generable`, `Tool`.

**Consequence for the plan.** §2 sets the deployment target at iOS 26.0 and the build SDK at
"iOS 27 or newer". Those are compatible only if everything iOS 27-only is behind
`if #available(iOS 27, *)`. Concretely:

- Tiers 3 and 2 (M0–M5) are entirely buildable against stable iOS 26.0 API. No blockers.
- Tier 1 (M6, MLX) requires an iOS 27 deployment target *and* beta API. Since M6 was already
  conditional and last, this costs nothing now — but it means tier 1 cannot ship until iOS 27
  is public and out of beta. Worth knowing before you invest in it.
- Building against a beta SDK also means the app can't be distributed through normal
  TestFlight/App Store channels until the SDK is released. For a personal app installed from
  your own Mac this is mostly irrelevant, but it does mean beta-SDK API can change between now
  and September.

**Recommendation:** target iOS 26.0, build with the released Xcode 26 for M0–M5, and revisit
iOS 27 at M6. This costs nothing and removes beta churn from the critical path.

---

## 2. Foundation Models — confirmed surface

### 2.1 Availability check (§7 first bullet)

```swift
final class SystemLanguageModel                    // iOS 26.0+
static var `default`: SystemLanguageModel
var availability: SystemLanguageModel.Availability
var isAvailable: Bool                              // convenience
```

`Availability` has exactly two cases:

```swift
case available
case unavailable(SystemLanguageModel.Availability.UnavailableReason)
```

`UnavailableReason` has exactly **three** cases:

```swift
case appleIntelligenceNotEnabled   // Apple Intelligence is not enabled on the system
case deviceNotEligible             // The device does not support Apple Intelligence
case modelNotReady                 // The model(s) aren't available on the user's device
```

**Correction to §7.** The plan lists "low power mode" as an unavailability reason. It is not
one. There is no low-power case in this enum. Low power mode, if it affects anything, will
surface as a failure or delay at request time — not as `.unavailable`. Handling is the same
(fall through to tier 3), but the plan's list should be corrected so nobody writes a `switch`
against a case that doesn't exist.

`.modelNotReady` is the interesting one for you: it means Apple Intelligence is on but the
model assets haven't finished downloading. That is a *transient* state and the only one worth
re-checking between sessions. The plan's "check availability every session" is right.

### 2.2 Session and generation

```swift
convenience init(model: some LanguageModel, tools: …, instructions: …)
convenience init(model: some LanguageModel, tools: …, transcript: …)

func respond(to: Prompt, options: GenerationOptions) async throws -> Response<String>
func respond<Content>(to: Prompt, generating: Content.Type,
                      includeSchemaInPrompt: Bool,
                      options: GenerationOptions) async throws -> Response<Content>

func streamResponse(to: Prompt, options: GenerationOptions)
    rethrows -> sending ResponseStream<String>
func streamResponse<Content>(generating: Content.Type, includeSchemaInPrompt: Bool,
                             options: GenerationOptions,
                             prompt: () throws -> Prompt)
    rethrows -> sending ResponseStream<Content>

func prewarm(promptPrefix: Prompt?)
var isResponding: Bool
var transcript: Transcript
```

Guided generation via `@Generable` / `@Guide` is confirmed current — `respond(generating:)` and
`streamResponse(generating:)` are the typed entry points. The plan's constraint 5 (no JSON
string parsing) is directly supported. The `ManualMatch` struct in §7 is the right shape.

`prewarm(promptPrefix:)` is worth knowing about: it eagerly loads session resources. For job B
(summarization) we can prewarm while the PDF page is rendering, so the summary starts streaming
sooner without ever gating the page. That fits constraint 3 exactly.

### 2.3 Errors — one real change

`LanguageModelSession.GenerationError` is **deprecated**. The replacement is a top-level
`LanguageModelError` enum:

```swift
case contextSizeExceeded(…)        // transcript exceeded the model's context size
case rateLimited(…)
case refusal(…)
case timeout(…)
case guardrailViolation(…)
case unsupportedCapability(…)
case unsupportedTranscriptContent(…)
case unsupportedGenerationGuide(…)
case unsupportedLanguageOrLocale(…)
```

§7 asks that context-size-exceeded be handled as normal control flow — `contextSizeExceeded` is
there and that plan holds. `timeout` and `refusal` should get the same treatment: for us every
one of these means "no summary this time", never an error dialog.

I could not pin down whether `LanguageModelError` back-deploys to iOS 26.0 or is 27-only; the
framework index renders it as iOS 26.0+ beta while the related `LanguageModel` protocol renders
as iOS 27.0+ beta. **Check this in Xcode before writing the catch block.** If it is 27-only, use
the deprecated `GenerationError` on the 26.0 path — deprecated is fine, it still works.

### 2.4 Private Cloud Compute — actively avoid

`PrivateCloudComputeLanguageModel` is a first-class conforming type in the framework and slots
into the same `LanguageModelSession`. It is a network call to Apple's servers.

Hard constraint 1 forbids it, and `prompt.md` says the cloud fallback was considered and
rejected. I am flagging it because it is now *easy to reach by accident* — it is one line away
from the on-device path and it is what a lot of sample code will use. I will never construct it.
Worth an explicit note in whatever passes for the project's README so a future you doesn't add
it during a debugging session.

### 2.5 Semantic search — answers open question §14.2

WWDC26 describes a **Spotlight-backed search tool** for fully local RAG, exposed as a `Tool` you
hand to a `LanguageModelSession`. It performs semantic search over text plus structured search
over metadata, and it requires the app to donate content to Core Spotlight as
`CSSearchableItem`s first.

Two conclusions:

1. **It does not replace FTS5 and cannot serve tier 3.** It is a tool the *model* calls. No
   model, no search. Tier 3 must stay deterministic FTS5. The plan's architecture is unaffected
   and correct.
2. **It does mean you should not build a custom embedding pipeline** if you later want the
   non-code question path ("how do I set the tuning gains"). The answer to §14.2 is: yes, it
   likely covers that case, at the cost of iOS 27 + donating page content to Spotlight.

There's a happy side effect. §11 already wants `Manual` and `Component` modelled as `AppEntity`
so Spotlight can index them. If we donate *page-level* content to Spotlight too, that same
donation feeds both Spotlight search and the future semantic path. That's a seam worth leaving
open in M1 even though we build neither now — it costs one indexing call at import time.

I did not find a documentation page for the tool's exact symbol name; see §8.

### 2.6 Tier 1 is much cheaper than the plan assumes

§3 describes tier 1 as a bundled/downloaded 2–3B MLX model and treats it as significant work.
Per WWDC26, Apple open-sourced two provider implementations:

- **`MLXLanguageModel`** — "pass in a model ID and let the framework handle the rest"
- **`CoreAILanguageModel`** — runs local models on the Neural Engine

Both are distributed via Swift Package Manager and target iOS 27+. So tier 1 becomes roughly:

```swift
let model = MLXLanguageModel(/* model id */)
let session = LanguageModelSession(model: model)
```

That is genuinely the "config change rather than a second implementation" §7 hoped for. It also
means tier 1 is an SPM dependency — which under your rules I ask about rather than add. Not now;
this is an M6 conversation. Noting it because it changes the cost/benefit of M6 substantially,
and §14.4 asks exactly that question.

Also worth flagging: third-party provider packages from Anthropic and Google exist for this
protocol. Those are cloud models. Same answer as §2.4 — not for this app.

---

## 3. App Intents — plan confirmed

- `protocol AppShortcutsProvider: Sendable` with `static var appShortcuts: [AppShortcut]`.
- **Every phrase must contain the `\(.applicationName)` token.** Confirmed. §11 is correct.
- **A phrase may contain at most one intent parameter.** Confirmed. §11's decision to use a
  single free-text `query` parameter and parse it in-app is the correct workaround, not a
  compromise.
- **Maximum 10 App Shortcuts per app.** This is a limit §11 doesn't mention. Not a problem — we
  need one or two — but don't plan on generating a shortcut per machine.
- `AppShortcut` has an initializer taking `parameterPresentation:`, which is how you control how
  a parameterised shortcut is presented. Relevant if the disambiguation picker ever needs to
  appear in the Siri flow.

SiriKit being deprecated is consistent with everything current; App Intents is the path.

---

## 4. PDFKit — plan confirmed, with a plan B for tables

```swift
var string: String?                                 // iOS 11.0+
var attributedString: NSAttributedString?
var numberOfCharacters: Int
func characterBounds(at: Int) -> CGRect
func characterIndex(at: CGPoint) -> Int
func selection(from: CGPoint, to: CGPoint) -> PDFSelection?
func selection(for: CGRect) -> PDFSelection?        // rect-scoped extraction
func selection(for: NSRange) -> PDFSelection?
func selectionForWord(at: CGPoint) -> PDFSelection?
func selectionForLine(at: CGPoint) -> PDFSelection?
```

`page.string` exists and is stable since iOS 11. The §10 streaming strategy — open the
`PDFDocument`, pull one `page.string` at a time, write straight to a `FileHandle` — is sound
against this API.

The known risk stands: `string` returns text in the PDF's internal content order, which for a
multi-column fault-code table is often *not* reading order. This is precisely what M0 exists to
find out, and I won't pre-judge it.

**If M0 shows mangled tables, there is a plan B that stays within PDFKit** and does not require a
commercial SDK or a desktop step: `selection(for: CGRect)` extracts text within a rectangle, and
`characterBounds(at:)` gives per-character geometry. Together they allow reconstructing column
structure geometrically — cluster characters by x-position to recover columns, by y to recover
rows. That is real work and I'd want your go-ahead before building it, but it means a bad M0
result is a "harder" outcome rather than a dead end. I'd still report it as a no-go on the simple
approach, per your brief.

---

## 5. Vision OCR — plan needs an update

§10 specifies `VNRecognizeTextRequest`. That is the old API. The current one is:

```swift
struct RecognizeTextRequest                          // iOS 18.0+
var recognitionLevel: RecognizeTextRequest.RecognitionLevel
var recognitionLanguages: [Locale.Language]
var customWords: [String]
var minimumTextHeightFraction: Float
var automaticallyDetectsLanguage: Bool
var usesLanguageCorrection: Bool

func perform(on: CGImage, orientation: CGImagePropertyOrientation?) async throws -> Self.Result
// also: URL, Data, CIImage, CVPixelBuffer, CMSampleBuffer
```

Returns `RecognizedTextObservation`. Native async/await, no completion handlers, no
`VNImageRequestHandler` ceremony. Since we deploy to iOS 26.0, use this one.

Two settings matter a great deal for our specific content, and I'd have got them wrong from
memory:

- **`usesLanguageCorrection` must be `false`** for manual pages. Language correction is a
  natural-language speller. On a fault-code table it will happily "correct" `F0007` into
  something wordlike, or merge `2198-D032-ERS3` into nonsense. This single flag is probably the
  difference between usable and useless OCR for our content.
- **`customWords`** accepts a supplementary vocabulary. Seeding it with the catalog numbers and
  fault-code prefixes already in the library would measurably improve recognition on scanned
  pages. Cheap and high-leverage.

`recognitionLevel` = `.accurate` for the OCR path; speed is not the constraint since §10 already
budgets minutes.

I found no statement that `VNRecognizeTextRequest` is formally deprecated — it appears to still
exist. But `RecognizeTextRequest` is the current API and there's no reason to use the old one.

---

## 6. Answers to §14's open questions, so far

| # | Question | Status |
|---|---|---|
| 1 | PDFKit table fidelity | **Open — this is M0.** API confirmed present; plan B identified (§4). |
| 2 | Semantic search built in? | **Answered.** Yes, Spotlight-backed, iOS 27, model-driven — doesn't serve tier 3, but does mean don't write an embedding pipeline. |
| 3 | FTS5 latency on device | Open. Requires device measurement. |
| 4 | Tier 1 worth it? | **Materially cheaper than assumed** (§2.6) — `MLXLanguageModel` via SPM. Still an M6 decision. |
| 5 | Peak memory / wall clock | Open. Requires device measurement. |
| 6 | How many manuals lack a text layer | Open. Needs your library. |

---

## 7. Plan changes I'd propose

Listed, not made. Nothing gets built off these until you say so.

1. **§7 — remove low power mode** from the unavailability list; there are three cases and that
   isn't one.
2. **§7/§10 — swap `VNRecognizeTextRequest` for `RecognizeTextRequest`**, and pin
   `usesLanguageCorrection = false`.
3. **§2 — build with released Xcode 26 through M5**, not the iOS 27 beta SDK. Revisit at M6.
4. **§7 — add an explicit "never construct `PrivateCloudComputeLanguageModel`" note**, since it
   is now trivially reachable from the same session type.
5. **§6 — corpus-side normalization is missing.** The plan normalizes the query but not the
   indexed text. If the manual prints `F-0007` and the user types `F0007`, query variants alone
   won't hit. This needs a decision (normalized shadow column vs. custom FTS5 tokenizer) and
   it's a design question, not an implementation detail.
6. **§12 — M1 implicitly needs part of M2.** M1's done-condition is "typing a fault code puts
   the correct page on screen," which requires some normalization. I'd do minimal exact-match in
   M1 and keep M2 as the full extraction + test-suite milestone.
7. **§10 — consider donating page content to Core Spotlight at import time.** One extra call
   during ingestion; leaves the door open to both Spotlight search (§11) and the iOS 27 semantic
   path (§2.5) without committing to either now.

---

## 8. What I could not verify

Stated plainly rather than guessed at.

- **The Spotlight search tool's exact symbol name and module.** WWDC26 describes it and one
  secondary source calls it `SpotlightSearchTool`, but the documentation URL I tried 404s and I
  could not confirm the spelling, the module it lives in, or its initializer from Apple's symbol
  graph. Do not write code against that name on my say-so.
- **Whether `LanguageModelError` is available on iOS 26.0 or 27.0 only.** The docs render
  inconsistently (§2.3). One look at Xcode's autocomplete settles it.
- **The full parameter list of `@Guide`.** `description:` is confirmed and in wide use;
  WWDC25 describes additional programmatic constraints on generated values, but the macro's
  documentation page 404s and I could not enumerate them.
- **Whether `VNRecognizeTextRequest` is formally deprecated.** No deprecation notice found; it
  appears to still exist alongside the new API.
- **Anything requiring a compiler or a device.** No Swift toolchain, Xcode, simulator, or iPhone
  in this environment. Every performance and memory claim in `plan.md` remains unmeasured, and I
  will not report constraint 4 (one second) or constraint 7 (peak memory) as met on the basis of
  reasoning.

---

## 9. Decisions needed before M0

1. **FTS5 access: GRDB or the C API?** My recommendation is the **direct SQLite C API**. GRDB is
   an excellent library, but `prompt.md` is explicit that every dependency is something you
   maintain alone in three years, and our SQLite use is narrow: create an FTS5 table, insert a
   row per page in batched transactions, run one MATCH query. That's a few hundred lines against
   a C API that has been stable for a decade and ships with the OS. GRDB would buy ergonomics we
   don't need and add a dependency to the one component that must never break. Your call.
2. **Corpus-side normalization** (§7 item 5 above) — needs a decision before the FTS5 schema is
   fixed, because it determines the schema.
3. The three items from `prompt.md`'s "what to ask about up front", above all **one real manual
   PDF**. M0 cannot start without it.
