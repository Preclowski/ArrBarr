# Follow-ups

Work agreed but deliberately kept out of the change that surfaced it. One line each; link the plan or the code.

- **LAN discovery UI.** MediaKit `Discovery` (`Packages/MediaKit/Sources/MediaKit/Discovery/`) parses Bonjour and
  beacon answers and is tested (`DiscoveryTests`), but nothing calls `Discovery.scan`. Add a "Find servers" action to
  the arr / media server Settings that fills the URL. Keep the code until then (decided 2026-09-27).
- **`Observations` for `ConfigStore` consumers.** 39 views on an `ObservableObject`; separate branch, visual check.
- **Criterion 28.** Spotlight intents with parameters, a queue snippet, `@Generable` results.
- **Split the largest files.** `SettingsView` (1537 lines), `DetailView` (1456), `QueueViewModel` (1289),
  `QueueListView`, `PopoverContentView`, `ConfigStore`: one type per concern, after the 2026-09-28 junk sweep.
