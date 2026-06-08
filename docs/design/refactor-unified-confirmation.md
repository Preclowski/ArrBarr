# Refactor: unified confirmation modal (one class, conditional render)

**Goal:** one confirmation surface. On **iOS** render a **native**
`.confirmationDialog` (or `.alert`); on **macOS** keep the in-panel
`InlineConfirmCard` (a native dialog steals focus and dismisses the
MenuBarExtra popover). One model, one host modifier, conditional body inside —
no per-call-site custom cards.

## Today (scattered)
- `PendingConfirm` model + `ConfirmCenter` (notification-based request bus).
- `InlineConfirmCard` (custom card) rendered via a `.inlineConfirm(...)` modifier
  at some call sites (DetailView, EpisodeDetailOverlay).
- `ConfirmCenter.request(...)` posted from row-level deletes (QueueRowView,
  MultiRow, QueueGroupRowView) and rendered at a host (PopoverContentView).
- Net: two presentation paths + several call shapes.

## Target
**One** `PendingConfirm` (keep), driven through **one** coordinator, presented
by **one** host modifier:

```
// Single source of truth — an @Observable (or the existing ConfirmCenter)
// holding `pending: PendingConfirm?`.

extension View {
    func confirmationHost() -> some View { modifier(ConfirmationHost()) }   // attach once per surface root
}

private struct ConfirmationHost: ViewModifier {
    @State/@ObservedObject var center  // pending: PendingConfirm?
    func body(content: Content) -> some View {
        #if os(iOS)
        content.confirmationDialog(
            pending?.title ?? "", isPresented: binding, titleVisibility: .visible
        ) {
            Button(pending.confirmLabel, role: pending.isDestructive ? .destructive : nil) { pending.onConfirm() }
            Button(pending.cancelLabel, role: .cancel) {}
        } message: { Text(pending.message) }
        #else
        content.overlay { if let p = pending { InlineConfirmCard(p) } }  // existing card
        #endif
    }
}
```

Call sites everywhere become a single call: `ConfirmCenter.request(PendingConfirm(...))`
(already the shape used by rows). Remove the bespoke `.inlineConfirm(...)`
modifiers in DetailView/EpisodeDetailOverlay and route their delete/search
confirms through `ConfirmCenter.request` too.

## Decisions
- Keep `PendingConfirm` (title/message/confirmLabel/cancelLabel/isDestructive/onConfirm).
  Add `role`/secondary action only if a call site needs it (search-confirm in
  EpisodeDetailOverlay is a non-destructive confirm — supported by the same model).
- Coordinator: prefer a single `@MainActor @Observable ConfirmCenter` with a
  `pending: PendingConfirm?` instead of the NotificationCenter bus, so the host
  binds directly (cleaner than posting/observing notifications).
- Attach `confirmationHost()` once per top-level surface: PopoverContentView
  (macOS), each iOS tab root (or iOSAppRoot once).

## Files
- `ConfirmCenter.swift`: become the observable holder (`pending`), keep `request`.
- New `ConfirmationHost` modifier (in ConfirmActionCard.swift or its own file).
- `ConfirmActionCard.swift` / `InlineConfirmCard`: reused as the macOS body.
- Remove `.inlineConfirm(...)` usages: DetailView, EpisodeDetailOverlay.
- Call sites already using `ConfirmCenter.request`: QueueRowView, MultiRow,
  QueueGroupRowView — unchanged.
- Host attach: PopoverContentView (macOS), iOSAppRoot (iOS).

## Risks / verify
- iOS `.confirmationDialog` needs a stable `isPresented` binding derived from
  `pending != nil`; clearing `pending` on dismiss.
- macOS popover focus: keep InlineConfirmCard (do NOT use native dialog there).
- One host per surface — avoid double-presentation if attached twice.

## Steps
1. Convert ConfirmCenter to an observable `pending` holder.
2. Add `ConfirmationHost` (iOS native / macOS inline).
3. Attach host at the two surface roots; remove inline-confirm modifiers.
4. Route DetailView/Episode delete + search confirms via `ConfirmCenter.request`.
5. Build macOS + iOS + device; verify a delete confirm on each.
