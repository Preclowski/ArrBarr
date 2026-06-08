# Agent guide

This project's agent instructions live in [CLAUDE.md](CLAUDE.md) — architecture,
build & run, tests, and the key patterns to follow. Read it first.

Quick reminders:

- All real code is in the **ArrCore** Swift package (`Packages/ArrCore`); the
  `ArrBarr` / `ArrBarriOS` / `ArrBarrWidgets` targets are thin shells. The MCP
  server is the **ArrMCPServer** package.
- After any code change, rebuild and relaunch the macOS app (see CLAUDE.md).
- Localize via `Text("…", bundle: .module)` / `String(localized: "…", bundle: .module)`.
- The discover feature is named "Quiz" — never the word "tinder".
