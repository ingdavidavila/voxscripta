# What to declare, and what is actually true

Written 2026-11-04. Publisher: **Working Robots**.

Two audiences need a privacy statement and they are not the same document.
The store declarations are structured forms with fixed vocabulary; the privacy
policy is prose at a public URL. Both have to match the binary, and the binary
is what this file describes.

## What the app does with data

Everything below is verifiable in the repository rather than asserted.

| | |
| --- | --- |
| Audio | Read, never written to. Never uploaded. §5 forbids deleting, modifying, overwriting or trimming the original, and `AtomicFile` never opens it for writing. |
| Transcripts | Written to a project package on the user's own disk. Never uploaded. |
| Transcription | Entirely on the device. Apple's `SpeechAnalyzer` on Apple platforms, whisper.cpp everywhere else. No cloud recognizer of any kind — §26. |
| Polish | Entirely on the device. Apple's `FoundationModels` or a bundled MLX model on Apple, llama.cpp with a bundled GGUF elsewhere. No external LLM API — §26. |
| Silence removal | Deterministic DSP. No model is consulted — §6. |
| Telemetry | None. There is no analytics SDK in the dependency graph; the only external package is `mlx-swift-lm` and its tokenizer. |
| Crash reporting | None. |
| Advertising | None. No identifiers, no tracking, no third-party ad SDK. |
| Account | Optional, and **not wired in any current build**. When wired it stores an email address and nothing else. |
| Payment | Handled by the App Store or Google Play. Card details never reach this app or any server of ours. |

## The network

This is the part that changed, and the part to get right.

The app used to make a flat claim — it shipped with no network access at all,
and `Tools/make-app-bundle.sh` enforced it by refusing to produce a bundle
that carried a network entitlement. Selling a subscription ends that, because
StoreKit has to fetch products, take a payment and hear about a refund.

So there are two macOS flavours, and the build checks each for the thing it
claims:

| Flavour | Network entitlement | The claim it can keep |
| --- | --- | --- |
| Direct download (default) | none — build **fails** if one appears | Cannot connect out. §26 enforced by the platform. |
| App Store (`VOXSCRIPTA_STORE_BUILD=1`) | `network.client` only — build fails without it, and fails if a `network.server` entitlement appears | No recording and no transcript is ever uploaded. The only network use is the store. |

The user-facing strings follow the same split, chosen from what is actually
wired rather than from a build flag, so the wording cannot drift from the
binary. See `SettingsView.privacyFooter`.

**Android** has no `INTERNET` permission in the manifest today. Play Billing
needs one, and so would an account service. Adding it is the same honesty
problem in a different file.

## App Store Connect — App Privacy

For a build with **no account service**, which is every build today:

- **Data Not Collected.**

That is the correct answer and it survives the paywall, because Apple's own
purchase data is collected by Apple, not by the developer, and is declared by
Apple.

The moment an account service is wired, it becomes:

- **Contact Info → Email Address**
  - Collected: yes
  - Linked to the user's identity: yes
  - Used for tracking: **no**
  - Purpose: App Functionality (signing in)

Nothing else changes. Audio and transcripts stay undeclared because they are
never collected.

## Google Play — Data safety

With no account service:

- Does your app collect or share any of the required user data types? **No.**
- Is all of the user data encrypted in transit? Not applicable — none is sent.
- Do you provide a way for users to request that their data is deleted? Not
  applicable — none is held.

With an account service:

- **Personal info → Email address.** Collected, not shared. Purpose: Account
  management. Optional: yes.
- Data deletion: **required**, and the app must offer it in-app. `AccountView`
  and the Flutter `AccountScreen` both do, which is also App Store Review
  Guideline 5.1.1(v).

## The privacy policy itself

Still **unwritten and unhosted**, and it is the single item blocking the most:
the iOS submission, the Play submission, and the paywall — Guideline 3.1.2
requires a Privacy Policy link on the subscription screen itself, which is why
`StoreKitSubscriptionService` takes the URL as a required argument rather than
an optional one.

To write it, three facts are still needed and none of them can be inferred:

1. A **contact email** for the policy. The developer's personal address is on
   file in this project but has deliberately not been used, because putting it
   on a public page is a decision rather than a detail.
2. The **country** whose law governs, for the governing-law clause.
3. The **URL** it will live at. GitHub Pages on the existing repository would
   serve it at no cost.

The text itself is short, because the app does so little: it collects nothing
in current builds, and an email address if accounts are ever wired.

## Claims that must never be made again

Three sentences were in the app and are now wrong. They are recorded here so
nobody reinstates them from memory:

- *"Vox Scripta ships without network access."* True of the direct download
  only. False of any store build.
- *"It has no telemetry and no accounts."* The telemetry half stays true
  forever. The accounts half stops being true the moment one can be created.
- *"Nothing is uploaded, nothing is sent to a service."* The second clause is
  false once a store or an account service is reached. The first clause, about
  recordings and transcripts, is the one worth keeping and is what the strings
  now say.
