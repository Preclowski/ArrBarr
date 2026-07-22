# Contributing to ArrBarr

Thanks for looking. This is a small project with one maintainer, so a quick
issue before a large PR saves everyone time.

## Getting set up

Requires **Xcode 26.4.1** (the version CI pins) on macOS 14+.

```bash
git clone https://github.com/Preclowski/ArrBarr.git
cd ArrBarr
open ArrBarr.xcodeproj
```

Command-line build and run:

```bash
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr -configuration Debug \
  -derivedDataPath build build

pkill -x ArrBarr 2>/dev/null; open build/Build/Products/Debug/ArrBarr.app
```

Other schemes: `ArrBarriOS`, `ArrBarrWidgets`, `ArrCore`, `ArrMCPServer`.

### Signing

The project deliberately ships with an **empty** development team so forks build
ad-hoc out of the box. Don't hardcode your team into `project.pbxproj` — pass it
in instead:

```bash
xcodebuild ... ARRBARR_DEVELOPMENT_TEAM=YOURTEAMID
```

`CURRENT_PROJECT_VERSION` works the same way: it reads `ARRBARR_BUILD_NUMBER`,
which defaults to `1` locally and to the CI run number in the release workflow.

### No real servers needed

Demo mode runs the whole UI against fixtures, in an isolated preferences suite,
without touching your real configuration:

```bash
open build/Build/Products/Debug/ArrBarr.app --args --demo
```

## Tests

The `ArrBarr` scheme has **no test action** — the suites live in the two
packages and run much faster through SwiftPM:

```bash
swift test --package-path Packages/ArrCore
swift test --package-path Packages/ArrMCPServer
```

CI runs exactly these two commands, and a failure blocks the release job.

Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest.
New tests should follow suit.

## Architecture

Read [CLAUDE.md](CLAUDE.md) first — it is the real architecture document. The
short version: the app targets are thin shells, and everything (models,
services, view-models, SwiftUI views) lives in the `ArrCore` package, with the
MCP server in `ArrMCPServer`.

## House rules

These are the ones that trip people up:

- **Localization.** Never inline a user-facing literal. Views use
  `Text("Key", bundle: .module)`; models and services use
  `String(localized: "Key", bundle: .module)`. The single catalog is
  `Packages/ArrCore/Sources/ArrCore/Resources/Localizable.xcstrings`, covering
  en, de, es, fr, nl and pl. Strings whose key is built at runtime never reach
  the catalog — avoid that pattern.
- **Naming.** The paid tier is **"Control"**, never "Pro". The swipe-to-discover
  feature is **"Quiz"** — the obvious dating-app name must not appear anywhere,
  including identifiers and comments.
- **No dead code.** If a change makes something unused, delete it in the same
  change.
- **Comments explain *why*.** This codebase has an unusually high standard for
  comments that record the reasoning behind a non-obvious choice. Match it; skip
  the ones that just restate the code.
- **Swift 6 tools, language mode v5.**

## Dependencies

Adding a third-party dependency is a discussion, not a PR. Everything currently
linked is pinned to an exact released version in the three tracked
`Package.resolved` files, because a release DMG has to be reproducible from its
tag. If you do change a pin:

1. Run `swift package resolve` in both packages so all resolved files agree.
2. Commit the resolved files — they are deliberately **not** git-ignored.
3. Update [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) from the actual
   `LICENSE`/`NOTICE`/`COPYING` files in the new checkout. Do not write license
   text from memory.

## Commits and pull requests

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
`feat(chat): …`, `fix(queue): …`, `refactor(mcp): …`, `docs: …`. The `ux(...)`
scope is used for pure presentation changes.

Before opening a PR:

- both test suites pass
- the app builds and launches
- no new user-facing literal bypasses the string catalog
- `CHANGELOG.md` has an entry under the unreleased version heading if the change
  is user-visible

## Releasing

For maintainers:

1. Bump `MARKETING_VERSION` in `ArrBarr.xcodeproj` — **all nine build
   configurations**, they must agree.
2. Move the `CHANGELOG.md` entries under the new version heading.
3. Publish a GitHub release with tag `vMAJOR.MINOR.PATCH`.

CI then builds, tests, verifies that the tag matches the app's
`CFBundleShortVersionString`, creates the DMG, uploads it, and updates the
Homebrew cask. The version check exists because Homebrew derives the cask
version from the tag but compares it against the app's bundle version to decide
whether an install is outdated — a mismatch ships a cask that never upgrades
cleanly.

## Security

Do not report vulnerabilities in a public issue or PR. See
[SECURITY.md](SECURITY.md).
