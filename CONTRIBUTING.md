# Contributing

Thanks for your interest in Open Agent Deck. This file covers how to build, test and send a change.

## Prerequisites

- macOS 26 or later, Xcode 26 or later (the package uses `swift-tools-version: 6.2`).
- Optional, to run the app against real sessions: Claude Code and cmux (see the [README](README.md#requirements)).

## Get the code

```
git clone https://github.com/HectorZarate/openagentdeck.git
cd openagentdeck
git config core.hooksPath .githooks
```

The second command enables the pre-push hook (below). Do it once per clone.

## Build and test

The fast loop is the Swift package on its own, which holds almost all of the code and tests (about 30 seconds):

```
swift test --package-path Packages/DeckKit
```

Building the app:

```
xcodebuild build -project OpenAgentDeck.xcodeproj -scheme OpenAgentDeck -destination 'platform=macOS'
```

Signing defaults to ad hoc, so this works without a developer account. To sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and fill it in.

### Test plans

- **OpenAgentDeck** (the scheme's default, so `⌘U` runs it): the three package test targets `DeckCoreTests`, `DeckAdaptersTests` and `DeckAppTests`.
- **UITests** (separate): launches the built app through XCUITest. It needs macOS UI-automation approval for the test runner, so the first run prompts you. The tests set `OAD_NO_FLEET_DISCOVERY=1` (so results do not depend on your real Claude sessions) and a free `OAD_HOOK_PORT` themselves. **Quit any running deck first**: a running deck holds the default hook port 8765, and a test that launches the app without its own `OAD_HOOK_PORT` collides with it; the second instance exits and `xcodebuild` reports it as the runner failing to establish a connection. New UI tests must set both variables.

Run a plan from the command line with `-testPlan`:

```
xcodebuild test -project OpenAgentDeck.xcodeproj -scheme OpenAgentDeck -destination 'platform=macOS' -testPlan OpenAgentDeck
```

### Environment variables for development and testing

- `OAD_HOOK_PORT`: hook server port instead of 8765. Also stops the crash watchdog from arming, so a scratch instance is not resurrected.
- `OAD_NO_FLEET_DISCOVERY=1`: skips discovery of your real Claude sessions.
- `OAD_WINDOW_SIZE=WIDTHxHEIGHT` (for example `1100x620`): opens the window at that size, for repeatable screenshots and automated runs.
- `CMUX_BUNDLED_CLI_PATH`: path to the `cmux` CLI. cmux exports it into its own terminals; otherwise the deck uses `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### The pre-push hook

There is no CI. `.githooks/pre-push` is the gate. On each push it runs:

1. `swift test --package-path Packages/DeckKit`: every unit test, the same targets as the OpenAgentDeck plan. SwiftPM runs them without launching the app or Xcode's test daemon, so a push never hangs on UI automation.
2. `build-for-testing` on the UITests plan, with ad hoc signing forced: compiles the app and the UI tests, but runs nothing.

The UI tests run only when you ask for them, because they launch the app and depend on macOS automation approval:

```
OAD_UI_TESTS=1 git push          # as part of the gate
xcodebuild test -project OpenAgentDeck.xcodeproj -scheme OpenAgentDeck -destination 'platform=macOS' -testPlan UITests
```

Run them before pushing a change to the UI. A failing stage refuses the push and prints how to re-run it. Please do not push past a failure with `--no-verify`. If a test passes on re-run with no change, treat it as a flaky test to fix, not a pass.

## Code layout

Start at [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): module layering, the main data flow and a glossary of the vocabulary used in the code. The product intent is in [docs/PRODUCT_BRIEF.md](docs/PRODUCT_BRIEF.md) and [docs/UX_DESIGN.md](docs/UX_DESIGN.md).

Tests lean on recorded fixtures from real Claude Code and cmux sessions. The IDs cited in code and tests (`LV30`, `S18`, ...) are keyed in [Packages/DeckKit/Tests/FIXTURES.md](Packages/DeckKit/Tests/FIXTURES.md). Fixtures must not contain personal paths, host names or real prompts.

## Pull requests

- Keep each PR small and focused on one change.
- The package tests and, if you touched UI behavior, the UI tests must pass. Add or update tests with the change.
- Put pure logic in `DeckCore`, I/O behind a `DeckPorts` protocol with the implementation in `DeckAdapters`, and views in `DeckApp`. The manifest enforces the direction of dependencies.
- Describe what changed and why, and how you verified it. Because there is no CI, maintainers run the tests locally before merging.

Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately, as described in [SECURITY.md](SECURITY.md).

By contributing you agree your work is licensed under the Apache License 2.0, like the rest of the project.
