# What "the same application" means

Decided 2026-11-01: **same features, native feel on each platform.**

Not pixel parity. The Flutter interface should look and behave like a Windows
application on Windows and an Android application on Android — platform
conventions for navigation, file pickers, menus and controls — while offering
the same capabilities as the SwiftUI app. A user moving between a Mac and a PC
should find everything they had, not the same screenshot.

That makes parity checkable, which is the point of writing it down. The list
below is the contract. A feature added to either interface is added to this
table, or the two have started to drift.

## The guard that already exists

Neither interface contains logic. Every rule — thresholds, transcript
formatting, which model runs — lives in the engine, and both interfaces call
it. `voxscripta_engine` carries no rules for the same reason. This stops the
two from *disagreeing*; it does nothing to stop one from being *missing*
something, which is what the table is for.

## Feature contract

Legend: ✓ in the SwiftUI app · ABI column says whether the C ABI can serve it.

| Feature | SwiftUI | C ABI today |
| --- | --- | --- |
| **Library** | | |
| List projects with duration and date | ✓ | ✓ `vs_library_list` · Flutter ✓ |
| Open a project | ✓ | ✓ — `vs_job_start` opens an existing package |
| Delete a project (recoverable — Trash, or a Deleted folder) | ✓ | ✓ `vs_project_delete` · Flutter ✓ |
| Reveal in the file manager | ✓ | platform-side, not engine |
| **Getting audio in** | | |
| Import an audio file | ✓ | ✓ · Flutter ✓ (platform dialog, or a typed path) |
| Copy the original into the project, or reference it | ✓ | ✗ (always references) |
| Record in the app, with pause and resume | ✓ | ✓ `vs_recording_*` · Flutter ✓ |
| Level meter and elapsed clock while recording | ✓ | ✓ — the meter curve is the engine's · Flutter ✓ |
| Discard a recording | ✓ | ✓ · Flutter ✓ |
| Microphone permission refusal, handled | ✓ | the engine's refusal is shown verbatim · Flutter ✓ |
| **Running a job** | | |
| Progress with the stage and its detail line | ✓ | ✓ · Flutter ✓ |
| Cancel, leaving the project resumable | ✓ | ✓ · Flutter ✓ |
| Resume an interrupted job | ✓ | ✓ — `vs_job_start` with an empty audio path · Flutter ✓ |
| **Reading the result** | | |
| Three variants: verbatim, clean, polished | ✓ | ✓ · Flutter ✓ |
| Copy the transcript to the clipboard | ✓ | ✓ · Flutter ✓ |
| Save as txt, md, docx, srt, vtt | ✓ | ✓ · Flutter renders, cannot yet choose where |
| Include timestamps in an export | ✓ | ✓ via `options_json` |
| Save every variant at once | ✓ | ✓ by repeated calls |
| Polish review: which sentences were accepted or rejected, and why | ✓ | ✓ `vs_project_summary` · Flutter ✓ |
| Explanation when polish did not run | ✓ | ✓ · Flutter ✓ |
| Render silence-removed audio | ✓ (macOS) | ✗ — and AVFoundation-only |
| **Settings** | | |
| Silence: margin dB, minimum duration, lead and trail padding | ✓ | ✓ · Flutter ✓ |
| Chunking: maximum duration | ✓ | ✓ · Flutter ✓ |
| Locale, and detect-language on or off | ✓ | ✓ · Flutter ✓ |
| Available locales on this machine | ✓ | ✓ `vs_capabilities` · Flutter ✓ |
| Concurrency | ✓ | ✓ · Flutter ✓ |
| Clean: fillers, repetitions, low-confidence words | ✓ | ✓ · Flutter ✓ |
| Polish: on or off, and which backend | ✓ | ✓ · Flutter ✓, including which model would really run |
| Default variant to show | ✓ | interface-side |
| Keep intermediate files | ✓ | ✓ · Flutter ✓ |
| **Accounts** | | |
| Sign in with Apple | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| Sign in with Google | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| Email and password sign-in | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| Sign up: email, password, password again | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| Password rules: 8 characters, a capital, a number, a symbol | ✓ reads `PasswordPolicy` directly | ✓ `vs_password_rules` · Flutter ✓ |
| Reveal the password | ✓ | interface-side · Flutter ✓ |
| Forgotten password | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| Delete the account from inside the app | ✓ screen, no service | ✗ — screen ✓ Flutter, no service |
| **The paywall** | | |
| 3-day trial from first launch | ✓ | ✓ `vs_entitlement_state` · Flutter ✓ |
| A clock set backwards does not extend it | ✓ | ✓ — high-water mark in the engine |
| New transcriptions and recording refused after it | ✓ — `JobRunner` + `AppModel` | ✓ — `vs_job_start`/`vs_recording_start` return -3 |
| Reading, copying and exporting never refused | ✓ | ✓ — not in `GatedAction` |
| Trial countdown shown before the wall, not only after | ✓ | interface-side · Flutter ✓ |
| Subscription screen with price, period and required links | ✓ | interface-side · Flutter ✓ |
| Buying a subscription | StoreKit 2 written; no products, no URLs | ✗ — screen ✓ Flutter, no store |
| Restoring a purchase | StoreKit 2 written; no products, no URLs | ✗ — screen ✓ Flutter, no store |
| **Everywhere** | | |
| A tooltip on every button saying what it does | ✓ | interface-side |
| Dismissible errors carrying the engine's own words | ✓ | ✓ |

## A reporting bug worth recording, 2026-11-02

The polished variant reported far fewer words than the clean one — on a real
recording, 13 against clean's 37. It looked like polish deleting a third of a
transcript, which would have been the most serious defect in the project.

It was the count. `Transcript.wordCount` summed the per-word *timing* arrays,
and POLISH empties those for every sentence it rewrites, because the timings
describe the spoken words and the rewritten text no longer matches them. So
the count counted only the sentences polish happened to leave alone. The text
was intact throughout — 38 words against clean's 37, which is what a
readability pass should look like.

Every caller of that figure is a display string: the variant picker, "Copied
13 words" after a copy, the footer of a Markdown export. It now counts the
text, so the variants are comparable, which is the only reason to show it.

## Progress, 2026-11-01

ABI 2 closed the library and the settings. Twelve symbols became seventeen,
and `vs_job_start` and `vs_export` each gained one JSON parameter rather than
a sibling function, because nothing had shipped against version 1 and a legacy
variant kept forever costs more than a break nobody can observe.

Two design notes worth keeping:

**Scalars on the hot path, JSON for anything with shape.** Polling a job is
four integer reads and no allocation. Settings are one string parameter whose
signature never changes as settings are added — the alternatives were a dozen
scalar parameters, or a C struct whose layout three languages and three
platforms would have to agree about forever.

**The engine reports its own defaults**, through `vs_job_options_defaults`.
This matters more than it looks: a settings screen with its own hardcoded
default silence margin is a rule living in an interface, and the moment the
engine changes the two disagree. The Flutter settings screen will render from
what the engine says. For the same reason the library's location moved out of
`AppModel` into `ProjectStore.defaultLibraryDirectory`, so both interfaces ask
rather than each building the path.

ABI 3 added `vs_project_summary`, which the transcript screen needed: which
transcripts exist, their word and segment counts, and what POLISH decided. One
call rather than four, because the screen needs all of it to draw one frame.

Counts and evidence are separated in it, on purpose. A clean run of a long
interview is thousands of accepted sentences, and shipping them all so an
interface could count and discard them would be a megabyte of JSON to render
one number. `flagged` carries only the retries and the fallbacks — the
sentences a reader would actually want to see.

ABI 4 added `vs_capabilities` for the settings screen: the transcription
languages on offer, which of them the text stages understand, which have
enough defence for POLISH to be permitted, and which model POLISH would
actually use. Every line of that is a rule, which is why it is answered by the
engine — a settings screen that worked any of it out for itself would be a
second copy of the engine's judgement, free to disagree with the first. The
same principle runs through the screen: no default is written in Dart, and
setting a value *back* to the engine's default removes the override rather than
pinning today's number forever.

**A gap `vs_capabilities` exposed on the real machine, since fixed.** Both
engines resolved their model by joining `build/models/<name>` onto the
*working directory* — right for a command line run from the project root, and
wrong for every packaged application. A shipped Flutter app would have
reported "no bundled model" with the GGUF sitting beside its executable, and
POLISH would have been quietly absent with no error anywhere.

`ModelSearch` in `VoxScriptaCore` now answers it once for both engines: an
environment override, then beside the executable, then an Apple bundle's
`Resources`, then the development tree found by walking up rather than
assuming a depth. On this machine the symptom went from `bundled model: none`
to `bundled model: llama.cpp, polish.gguf`.

ABI 5 added what the processing screen draws: the audio facts on
`vs_project_summary` — duration, speech regions, the speech spans, how many
waveform buckets exist and how long POLISH will take — and `vs_waveform`
beside it, which returns interleaved Float32 min/max pairs rather than JSON.

Three decisions in that worth keeping:

**Downsampling is the engine's.** `vs_waveform` takes the pixel width the view
will draw at and reduces by taking each span's extremes. Averaging — which is
what an interface reaching for a one-liner would do — flattens every transient,
and a waveform that has lost its transients no longer looks like the audio.

**The speech spans, not only the fraction.** The first version of the screen
had the fraction alone and shaded that share of the width from the left. It
looked like a finding — "the first 71% is speech" — and was not one.

**An empty audio path means resume.** A project package references its own
source, so re-running one needs no audio path. The first version had the
interface pass the project path twice to say this, which worked only because
the audio argument is ignored once a manifest exists: a call that read as a
lie.

ABI 6 added recording, which was the last surface. Two rules moved out of the
Apple-only interface and into the engine on the way: where recordings are
written and what they are called, and the level meter's curve. The curve
especially — two meters moving differently for one microphone would be
describing two different recordings.

**The capture path has now run, once.** `tool/record_check.dart` records three
seconds through the whole stack — Dart, the C ABI, miniaudio, FFmpeg — and the
result is a real file: 1 channel, 44.1 kHz AAC, 2.99 seconds, which macOS's own
`afinfo` reads. That is the first time `PortableRecorder` has executed at all.
It is still only one platform; the device layer on Windows, Linux and Android
remains unexercised, and a microphone cannot be opened in a test suite without
prompting a developer and failing a build server.

Recording also surfaced a bug worth the trip: after `finish()`, `latest.state`
still said `recording`, because cancelling the poll timer left the last reading
in place. A screen trusting it would have shown a finished recording as live.

Importing works, and without a plugin. A file-picker plugin is the right
answer eventually and is the only way to reach Android's document provider —
but it needs CocoaPods on macOS, macOS is the only platform this app can
currently be *run* on, and adding one would have traded a working feature for
an unverifiable one. So the import sheet asks the desktop for its own dialog —
`osascript`, `zenity` or `kdialog`, PowerShell — and always offers a typed
path, which is both the fallback on a machine with no dialog installed and the
only route a test can take.

**Android is deliberately not covered.** There is no shell dialog there, and
that is the point at which the plugin has to arrive.

The whole path has been walked once against a real file:
`tool/import_check.dart` imports `jfk.wav`, runs the pipeline and prints the
result — verbatim, clean and polished transcripts, and the right words.

What is still ✗: copying the original into a project instead of referencing
it, and choosing where an export is saved. Saving needs the same dialog work
as importing and will reuse `FileChooser`.

## What the first version of that table said

**The C ABI covered about a fifth of the application.** It can run a job and
read the result, which was enough to prove the boundary works and is nowhere
near enough to build an interface on. Twelve symbols became the right number
for "does Dart reach Swift at all"; it is the wrong number for this contract.

So the next engineering step is not screens. It is growing the ABI to cover
the rows marked ✗, and the honest order is the order a user meets them:

1. **The library** — list, open, delete. Nothing can be built without it.
2. **Job options** — every setting above, passed into `vs_job_start`. This is
   the largest single gap and the one most likely to shape the ABI's design,
   because a dozen scalars as parameters is not a signature anyone should
   write. A JSON blob in and out is the likely answer, since the engine
   already encodes these types with `Codable`.
3. **Export options** — timestamps, and whatever else `ExportOptions` grows.
4. **Polish review** — the report is already written to disk as JSON; it needs
   reading out.
5. **Recording** — the largest piece, and the one with a real platform
   question underneath it: `PortableRecorder` exists and is tested, but it has
   never run on a machine that is not a Mac.

Two rows will not reach parity by growing the ABI, and should be said plainly
rather than left to be discovered:

- **Silence-removed audio** is AVFoundation-only. Off Apple the time map is
  produced but the audio is not, and `render-audio` throws `notImplemented` by
  name. Closing it means teaching FFmpeg to write the file.
- **Polish is weaker off Apple, and now measured.** Semantic distance abstains
  without `NLEmbedding`. `EnglishRejectionCorpus` measured what that costs by
  running the gauntlet on a Mac with the embedding forced absent: seven of
  twenty-nine corruptions escaped, all of them negation spelled without a
  negative word. The English lexicon was extended until all twenty-nine were
  refused and no legitimate rewrite was blocked. Spanish was re-measured in the
  same configuration: twenty of twenty refused, and the embedding changed no
  verdict — confirming it was never doing the work there.


## Accounts, 2026-11-03

Accounts arrived as a request for "a login with apple google and a native with
password", on every platform. What exists now, and what deliberately does not:

**In the engine**, so that both interfaces agree:
`VoxScriptaCore/Identity/PasswordPolicy.swift` holds the four rules — eight
characters, one capital, one number, one symbol — and `EmailAddress` holds the
shape check. They are exposed over the C ABI as `vs_password_rules` and
`vs_email_looks_valid` (ABI 7). A password accepted on Android is accepted on
the Mac because there is one definition of "accepted", not two.

**In Flutter**: sign in, sign up, forgotten password, an account screen with
sign-out and deletion, a launch gate, and the account rows in Settings. Each
password field has its own reveal toggle, the checklist shows all four rules
from the start rather than revealing them one failure at a time, and the two
sign-up fields are compared untrimmed — a trailing space is a different
password, and silently trimming it would lock someone out of an account they
typed correctly twice.

**Not in Flutter, by decision**: an account service.
`lib/src/auth/auth_backend.dart` returns null, so the gate never appears and
Settings shows no account rows in this build. `UnconfiguredAuthService` exists
for tests and throws on every route. A stub that returned a fake user would let
the whole flow look finished all the way to the library, and nobody would find
out the accounts were imaginary until a second device failed to see them.

**Not in SwiftUI at all yet.** The ✗ column above is honest: Mac and iPhone
have the shared rules and none of the screens.

Three things the account work changes outside the account screens, and all
three are still outstanding:

1. **The App Privacy declaration.** "Data Not Collected" stops being true the
   moment an email address is stored. It becomes Contact Info → Email Address,
   collected, linked to identity, used for app functionality. The transcription
   side is unchanged and still local; the declaration has to say both.
2. **The Android manifest** needs `INTERNET`, which it does not have, because
   until now nothing in the app talked to anything.
3. **The landing page's privacy policy** says there is no account. It will be
   wrong as soon as a service is wired, and the store listings point at it.

Guideline 5.1.1(i) is why the gate has "Not now" and why it takes no for an
answer: the app transcribes with no account and no network, so it may not
demand personal information for that. Guideline 5.1.1(v) is why deletion is a
button on the account screen and not a page on a website. Guideline 4.8 is why
Apple appears wherever Google does.


## The paywall, 2026-11-03

Three days from first launch, then a monthly or yearly subscription. Three
decisions shaped it, and all three were the user's:

**What the wall blocks: new work only.** Starting a transcription and starting
a recording. Nothing else — reading any variant, copying it, exporting txt, md,
docx, srt or vtt, reviewing which polish edits were accepted, deleting a
project, and every setting all keep working forever. `GatedAction` has exactly
two cases and a test asserts that it has exactly two, so widening the wall is a
deliberate act with a failing test attached. The reason is partly trust and
partly the brief: §5 says the original audio is never touched, and a wall that
held somebody's finished transcripts would be holding the only copy of work
they did during the trial.

**What they buy: a subscription**, monthly or yearly. Prices come from the
store as formatted strings, never as numbers formatted here, because Apple and
Google already localize them per territory and a hardcoded price is wrong for
most of the world.

**How the trial is measured: our own clock, no card.** `EntitlementStore` keeps
a JSON record beside the library. It is leaky and the leak is documented rather
than papered over: deleting the file, reinstalling, or a new user account on
the same machine all start a fresh trial. What it does stop is the easy abuse —
a clock set backwards — because `Entitlement` measures against the latest
instant the machine ever reported and that mark only ever rises. Winding the
clock *forward* spends the trial permanently, which is the safe direction to be
wrong in. A trial that genuinely could not be reset would need either the
store's own introductory offer, which demands a payment method on day zero, or
a server of ours, whose absence is the whole premise of the application.

### Where it is enforced

In the engine, at `vs_job_start` and `vs_recording_start`, which both return
`-3` with the engine's own sentence. Not in the interfaces. A paywall checked
only by the Flutter app is one the SwiftUI app, the CLI and the next platform
each have to remember separately, and one of them will not. Both entry points
take their gate as a parameter so a test can prove the wall without a
process-global one — otherwise every job test would depend on how many days ago
the test machine first ran the app.

### What this does not need

A server. StoreKit 2 transactions are signed by Apple and verifiable on the
device, offline; Play Billing purchases likewise. So unlike the account work,
the paywall drags no network dependency into an application whose premise is
that it needs none. Verification happens on the platform side and the outcome
is recorded through `vs_entitlement_record_subscription` — which means the wall
is exactly as strong as that platform code, and the ABI documents it that way.

### Outstanding, and one of them is urgent

1. **No store is wired, and the engine walls anyway.** A release build shipped
   in this state stops transcribing on day four with no way to pay.
   `configuredSubscriptionService()` returns null and the paywall screen says
   so in as many words. This is the consequence of putting the wall in the
   engine where no interface can forget it, and it must be closed before any
   build ships. `VOXSCRIPTA_ENTITLEMENT` forces a state in debug builds.
2. **Four purchase implementations**, not one: StoreKit 2 for iOS and macOS
   (Guideline 3.1.1 forbids anything else), Play Billing for Android (Play's
   Payments policy, same), your own for direct Windows and Linux downloads, and
   Microsoft Store IAP if it ships there.
3. **App Review has to get past the wall** (Guideline 2.1). A reviewer who
   installs on day one is inside the trial, so this is survivable, but a
   re-review of an update on a device that already has a spent record is not.
   Apple's sandbox accounts plus a reviewer note are the usual answer.
4. **Products to configure** in App Store Connect and the Play Console, with
   price tiers per territory, plus the Terms of Use URL — Apple requires an
   EULA link on the paywall itself, and it is a required field on
   `SubscriptionService` for that reason, not an optional one.
5. **The landing page** says nothing about a price. It claims a free local app.
6. **SwiftUI has none of it.** Mac and iPhone get the engine's wall — jobs will
   be refused with the engine's own message — but no banner, no paywall and no
   way to buy. That is the next thing to build.


## Accounts on Apple, 2026-11-03

The SwiftUI half of the account work, written against the same contract the
Flutter half already satisfies. Method for method, `AuthService` in
`VoxScriptaUI/Auth` matches the Dart `AuthService`: same routes, same
`AuthUser`, same required `deleteAccount()`.

What makes this parity rather than a coincidence: **the password rules are not
reimplemented here.** `AuthModel.passwordRules(for:)` returns
`PasswordPolicy.evaluate(_:)` straight from `VoxScriptaCore`, and a test
asserts the two are identical objects rather than merely similar ones. The
Flutter app reads the same four rules over `vs_password_rules`. One
definition, so a password accepted on a phone is accepted on a Mac — which is
the whole reason `PasswordPolicy` went into the engine rather than into an
interface.

Three Apple-specific things the Flutter side did not have to deal with:

1. **`SignInWithAppleButton`, not a drawn imitation.** Apple's guidelines
   govern that button's appearance, and Review Guideline 4.8 is why it appears
   wherever Google does. The real control also means the authorization sheet
   is real: a missing Sign in with Apple entitlement surfaces as an error the
   user can see rather than as a button that silently does nothing.
2. **A cancelled authorization is not a failure.** `ASAuthorizationError.canceled`
   is swallowed; everything else is reported. Someone who changed their mind
   has not hit a problem.
3. **`PasswordField` owns its own `isRevealed`.** SwiftUI swaps `SecureField`
   for `TextField` when the toggle flips, and hoisting that state to the form
   rebuilds the whole subtree and drops the caret back to the start of the
   text. Found the same way in Flutter, fixed the same way.

No gate at launch, on either platform. The account rows live in Settings and
nowhere else, and `configuredAuthService()` returns nil, so in this build they
do not appear at all. Review Guideline 5.1.1(i) refuses apps that demand
personal information for features that do not need it, and transcription needs
neither an account nor a network.

The privacy footer in Settings now has two forms. "No accounts" stops being
true the moment one can be made, and the fact that transcription stays local
does not excuse saying the other half wrongly.

### A hole in the paywall, found while writing this

The wall was put in `vs_job_start` and `vs_recording_start` on the grounds
that an interface cannot be trusted to remember it. That reasoning was right
and the placement was wrong: **the SwiftUI app does not use the C ABI at
all.** It calls `JobRunner().run(…)` from `VoxScriptaPipeline` directly, as do
the CLI and the FFI. So the paywall applied to Android, Windows and Linux and
left Mac and iPhone — the only platforms that can ship today — completely
open.

Fixed by moving the gate to `JobRunner.run`, which is the one place all three
callers pass through. `JobRunner` takes the record as a parameter, defaulting
to the machine's real one, for the same reason the two FFI entry points do:
otherwise every pipeline test starts failing three days after the machine
running it first ran the app.

The recording path is still open on Apple and is listed below. `AppModel` has
its own recorder and does not go through `vs_recording_start`.

### The paywall on Apple, closed

A trial banner above the window from the first day, a paywall sheet carrying
the price, the billing period and both links Guideline 3.1.2 requires, and a
**real StoreKit 2 implementation** — not another placeholder.

It can be real because StoreKit 2 hands back transactions signed by Apple and
`VerificationResult` checks that signature on the device. No server. That
matters more here than in most apps: an application whose premise is that it
needs no network should not acquire one in order to take money. An unverified
result is refused outright rather than trusted-and-logged, which is the one
thing standing between this and a forged receipt.

`Transaction.updates` runs for the life of the app, because a renewal that
arrives while the app is open, or a refund Apple grants, shows up there and
nowhere else — without it a refunded subscription keeps working until the next
launch. Apple's billing-retry grace is honoured: a subscriber whose card was
declined once should not lose the app mid-interview.

The "Save 37%" badge is computed from the two real prices, with a 5% floor. A
hardcoded percentage becomes a false advertisement the first time either price
moves, and in a currency whose tiers round differently it can be false on the
day it ships.

Recording on Apple is gated too, in `AppModel.startRecording`, since that path
uses `AudioRecorder` and never reaches `JobRunner`. Asking before the
microphone opens rather than after: audio the app will not then transcribe is
worse than a clear refusal.

### Still outstanding on Apple — and none of it is code

`configuredSubscriptionService()` returns nil, so nothing is for sale, while
the engine walls on day four regardless. Two things are missing and both sit
outside the repository:

1. **The two products in App Store Connect** — `voxscripta.monthly` and
   `voxscripta.yearly`, with a price tier per territory. Until they exist,
   `Product.products(for:)` returns an empty array and the paywall says so.
2. **A public Terms of Use URL and Privacy Policy URL.** Guideline 3.1.2
   requires both on the paywall itself, which is why they are required
   arguments to `StoreKitSubscriptionService` rather than optional ones.
   Shipping with placeholder links would put two dead URLs in front of a
   buyer on the one screen where they are load-bearing.

That privacy-policy URL now blocks three separate things: the iOS submission,
the Play submission, and the paywall.


## Swift ↔ C++ parity, 2026-11-04

The C++ port arrived from the Windows machine covering the whole
deterministic spine — canonical audio, frame analysis, noise floor, silence
detection, chunk planning, scheduling, transcript merging, exporters — plus a
whisper.cpp wrapper and a Media Foundation decoder. Roughly 5,250 lines.

It brought a risk with it. The cross-implementation suite covered `MediaTime`
and `TimeRange` and stopped there, so nine modules had two implementations of
the same rules, each tested only against its own expectations. That is exactly
the drift this document exists to prevent: a port's own tests encode whatever
the port does, so they cannot catch it disagreeing with the original.

### What is now held to parity

**Silence detection** — the stage that most needed it, because §6 pins it to
deterministic DSP and "reproducible" is only a virtue if both sides reproduce
the same thing. Six hand-written signals across four parameter sets, plus two
hundred seeded random ones: region and gap boundaries compared **exactly**
(they are integer nanoseconds and are what chunking consumes), energies and
the noise-floor profile within 1e-3 dB, which is far below anything that could
change a classification.

**Refusal** is compared too, and deserved its own mechanism. Swift throws
`noSpeechDetected`, C++ throws `NoSpeechDetected`, and a port that returned an
empty map where the original threw would pass every boundary comparison while
being wrong in the way that reaches a user — a recording the Mac rejects and
Android silently accepts, yielding an empty transcript instead of an
explanation.

**Chunk planning** — boundaries, sample ranges, overlap leads, boundary kinds
and hard-cut counts, all exact, over signals long enough to reach thresholds
measured in minutes. Fed each side's *own* silence map rather than one side's
map twice, so the two stages compose the way they do in the application.

Both suites assert they are **not vacuous**: two empty lists agree perfectly
and prove nothing, so the fixtures are checked to actually produce regions and
to produce more than one chunk.

### The bridge, and why it needed a shim

Swift's C++ interop cannot instantiate a class template, so `std::vector<float>`
cannot be written from Swift at all — only a specialization named on the C++
side can be used. Swift also cannot catch a C++ exception; it traps, which
would take the test process down rather than fail a test.

`Sources/VoxScriptaCxxShim` holds the named specializations, element
accessors and two exception-to-status functions. It sits outside `core/`
deliberately: these are properties of the bridge, not of the port, and the
C++ core should not grow declarations whose only reader is a test in another
language. No product exposes it and nothing but the test target depends on it.

### Still unheld

Four modules have a C++ implementation and no cross-check:

| Module | Why it matters |
| --- | --- |
| `transcript_merger` | Partly held — see the defect below. `merge` itself still needs chunk transcripts built across the boundary. |
| `exporters` | txt, md, docx, srt, vtt. A timestamp format or a line-wrap that differs makes the same recording export differently per platform. |
| `chunk_scheduler` | Ordering and concurrency. Needs a deterministic harness before it can be compared at all. |
| `canonical_audio` | Reads samples from disk, so parity needs fixture files rather than synthetic arrays. |

`transcript_merger` and `exporters` are the two worth doing next, in that
order. Both compare values rather than requiring I/O, so both are the same
shape of work as the two already done.


### A defect the suite found on its first run — since fixed

`TranscriptMerger::normalize` does not agree with the Swift original on
non-ASCII text, and `normalize` is how the merger decides two chunks overlap.

Swift normalizes with full Unicode — `lowercased()`, then keep anything
`isLetter || isNumber`. The C++ port works on bytes: ASCII lower-case, drop
ASCII punctuation, keep every byte ≥ 0x80 exactly as found. Six confirmed
disagreements:

| Input | Swift | C++ |
| --- | --- | --- |
| `it’s` (U+2019) | `its` | `it’s` |
| `don’t` (U+2019) | `dont` | `don’t` |
| `CAFÉ` | `café` | `cafÉ` |
| `NIÑO` | `niño` | `niÑo` |
| `¿Qué?` | `qué` | `¿qué` |
| `a—b` (U+2014) | `ab` | `a—b` |

The consequence is not cosmetic. Within one platform the comparison is at
least self-consistent, but the byte rule **fails to match a word carrying
punctuation against the same word without it**. A seam where one chunk ends
"hola" and the next begins "¡hola" deduplicates on Apple and does not off it.
What a user sees is a duplicated word at a chunk boundary — on Windows and
Android, in Spanish, and in any English transcript using typographic
apostrophes, which is most of them, because recognisers emit U+2019 rather
than U+0027.

Not fixed here. Exact parity with Swift's Unicode semantics is not reachable
in plain C++ without a Unicode table, which makes it a design decision rather
than a typo, and `core/` is being worked on from the Windows machine. It has
been reported there with a suggested approach: decode UTF-8 and handle
Latin-1 Supplement (U+00C0–U+00FF) and General Punctuation (U+2000–U+206F)
explicitly, which is bounded, needs no dependency, and closes every case
above.

**Fixed on the Windows machine, 2026-11-04** (`8f69be1`). `core/unicode_lite`
decodes UTF-8 and keeps a code point when it is a letter or a number, with any
combining marks that follow, dropping everything else — a category test rather
than the punctuation blocklist that would have aged badly. Malformed UTF-8
becomes U+FFFD and is dropped, which is what Swift does after repair. All six
cases now agree and the `withKnownIssue` wrapper is gone.

### What 25 probes then found

Having a working comparison, it was worth asking where the port's tables
actually end. Twenty-five probes across Greek (including the final-sigma
context), Cyrillic, Turkish dotted capital İ, Vietnamese, Hebrew, Arabic,
Thai, katakana, hiragana, Hangul, CJK, fullwidth Latin, Devanagari, Georgian,
decomposed combining marks, superscript and circled and Roman numerals,
Arabic-Indic digits and an emoji.

**Twenty-three agree.** Including the ones most likely to catch a hand-built
table out: Swift's `isNumber` is true for `²`, `①` and `Ⅷ` — three different
Unicode number categories — and the port matches on all of them.

Two diverge, both Latin Extended-B case pairs the port's own notes predicted:

| Input | Swift | C++ |
| --- | --- | --- |
| `Ǆ` U+01C4 | `ǆ` U+01C6 | unchanged |
| `Ʒ` U+01B7 | `ʒ` U+0292 | unchanged |

Ǆ is a Croatian and Serbian digraph; Ʒ is IPA and Skolt Sami.

**Won't fix.** `ShippingLanguages` now narrows the app to English and Spanish,
so neither character is reachable in a locale this version offers. The two
cases stay in the suite inside `withKnownIssue` rather than being deleted,
because if the language list is ever widened far enough to reach them, a
failing test is a cheaper reminder than a duplicated word at a chunk seam.
