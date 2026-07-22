# What this changes

<!-- One or two sentences. Link the issue it closes, if there is one. -->

## Why

<!-- The reasoning. If the change is non-obvious, this is the part that matters. -->

## How it was verified

<!-- What you ran, and what you saw. "It builds" is not verification. -->

## Checklist

- [ ] `swift test --package-path Packages/ArrCore` passes
- [ ] `swift test --package-path Packages/ArrMCPServer` passes
- [ ] The app builds and launches
- [ ] No user-facing literal bypasses the string catalog (views use
      `Text("Key", bundle: .module)`, services use `String(localized:bundle:)`)
- [ ] Nothing was left unused — dead code deleted, not commented out
- [ ] `CHANGELOG.md` updated, if the change is user-visible
- [ ] Dependency pins unchanged, or all three `Package.resolved` files and
      `THIRD-PARTY-LICENSES.md` were updated together
- [ ] `DEVELOPMENT_TEAM` was not hardcoded back into `project.pbxproj`

<!--
Security-sensitive changes (secret storage, the MCP server's auth or bind
address, anything that sends data off the machine) — say so explicitly here so
they get a closer look.
-->
