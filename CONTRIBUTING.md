# Contributing to Compass

Thanks for looking. Compass is a personal, local-first Mac app for net worth, spending, goals and life plans. Read this before opening a pull request.

## What fits

Compass is built for one person on one Mac: US dollars, local data, macOS 26 or later, no hosted service and no analytics. Changes that add multiple users, a server, other currencies or other platforms are out of scope. Bug fixes, accuracy fixes, accessibility, performance and polish are welcome. For anything larger, open an **Idea** issue first so we can agree on it before you build it.

## Set up

You need macOS 26, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen                                  # generates Compass.xcodeproj from project.yml
cd Core && xcrun swift test && cd ..      # logic tests (xcrun is required)
xcodebuild -project Compass.xcodeproj -scheme "Compass Sandbox" -derivedDataPath build/debug.noindex build
```

Builds are ad hoc signed by default, so they need no Apple account, but macOS asks again for Keychain access after each rebuild. To sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.

Format before committing (CI checks it): `xcrun swift-format format --in-place --recursive App Core Bridge DockTile scripts`.

Always test with the **Compass Sandbox** scheme. It runs with `--sandbox`, which uses its own store and Keychain entry. Add `--seed-demo` for made-up accounts, transactions, goals and habits. [docs/DEVELOPING.md](docs/DEVELOPING.md) lists every debug option.

## Rules the code follows

- Money is `Decimal` or integer cents, never `Double`. Debts are stored as negative balances, so net worth is a plain sum.
- Logic lives in the `Core` package with unit tests. SwiftUI views stay thin.
- Tests never call live SimpleFIN; they use the JSON fixtures in `Core/Tests/CoreTests/Fixtures/`.
- UI changes follow [docs/DESIGN.md](docs/DESIGN.md). Performance caps are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
- [CLAUDE.md](CLAUDE.md) has the code map and the working rules (it's written for coding agents, but it's the most complete guide to the code).

## Pull requests

- One topic per pull request, against `main`.
- CI must pass: the Core tests and the app build.
- A logic change comes with Core tests. Say in the description what the tests catch and what they miss.
- A UI change includes before and after screenshots from `--seed-demo` data, in light and dark.
- Update the docs your change makes wrong, in the same pull request.
- The maintainer reviews and merges.

## Keep real data out

Never put real balances, account names, transactions, access URLs, setup tokens, exports or store files in an issue, screenshot, fixture, log or commit. Use the sandbox and the demo data.

## Security

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).
