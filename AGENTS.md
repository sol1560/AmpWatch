# AmpWatch

A watchOS client for Amp. Swift 6, SwiftUI, no third-party dependencies.

## Layout

| Path | What lives there |
| --- | --- |
| `Packages/AmpKit` | Models, API client, formatting. Platform-neutral — builds and tests on Linux. |
| `Apps/Watch` | The watchOS app: views, design system, screenshot harness. |
| `Apps/WatchUITests` | XCUITest checks on the accessibility tree. |
| `Plugin/amp-watch-bridge.ts` | Amp plugin providing the write path. |
| `Scripts/` | Simulator selection and screenshot capture. |
| `project.yml` | XcodeGen input. The `.xcodeproj` is generated, never committed. |

## Build and test

```bash
cd Packages/AmpKit && swift test     # works anywhere, including an orb
xcodegen generate                    # needs macOS + Xcode
xcodebuild test -scheme AmpWatch -destination "platform=watchOS Simulator,id=$UDID"
```

On Linux, install a toolchain from swift.org; only `AmpKit` builds there. The
app targets need macOS.

## Verifying UI changes

There is no Mac in the loop. To see what a change looks like, push it and read
the screenshots CI produces:

```bash
gh workflow run watchOS --ref "$(git rev-parse --abbrev-ref HEAD)"
run=$(gh run list --workflow=watchOS --limit=1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run"
gh run download "$run" --dir .artifacts
```

Then look at the PNGs. Do not claim a UI change works without doing this.

When you add a screen, add it to `ScreenshotScene` in
`Apps/Watch/AmpWatchApp.swift` and to the `screens` array in
`Scripts/capture-screens.sh`, or CI will not capture it.

## Conventions

- Put logic in `AmpKit`, not in views: `AmpKit` is testable without a simulator,
  views are not.
- Views read data through `AmpEnvironment` (`@Environment(\.amp)`), never by
  constructing a client. That is what makes fixture rendering and screenshots
  possible.
- Never call `Date()` in a view. Use `amp.now()`, so screenshots stay stable.
- Colours and fonts come from `AmpTheme`. No literal `Color(...)` in a view.
- Every screen needs an `accessibilityIdentifier`; the UI tests and the
  screenshot harness both depend on them.

## Things that are true about Amp's API and will bite you

- The External API is **read-only** for threads. There is no endpoint that
  sends a message. Writes go through the plugin webhook.
- The API exposes **no agent run state**. `ThreadActivity` is derived from
  `updatedAt` and is an approximation. Do not rename it to something that
  implies otherwise, and do not label it "running" in the UI.
- Thread **message payloads are explicitly unstable** — only `messageID`,
  `messageVersion` and `createdAt` are guaranteed. Decode into `JSONValue` and
  extract defensively. Do not add a strict `Codable` struct for messages.
- `title` and `repositories` are **absent** unless the token has the
  `amp.api:workspace.threads.contents:view` scope. Both are optional; keep them
  optional.
- The webhook capability URL is a **credential**. Never log it, never commit it,
  never put it in a thread message.

## Secrets

Nothing in this repo may contain an Amp API token, OAuth client secret, or
webhook URL. CI does not need any of them: it runs entirely against fixtures.
