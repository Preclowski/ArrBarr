import SwiftUI

/// Shared anatomy for the two capsule-search surfaces — the Queue tab's
/// global search and the Library tab's lookup section. One home so the
/// pieces can't drift apart, same reasoning as `DetailSectionHeader`.

/// The capsule's leading slot: magnifying glass that swaps to a spinner
/// while lookups run. A fixed-size ZStack on purpose — swapping via
/// if/else shifts the TextField by ~1pt because ProgressView and the SF
/// magnifyingglass don't render at identical intrinsic widths. Both layers
/// always exist; only opacity changes, so the layout doesn't twitch while
/// typing.
struct SearchFieldLeadingIcon: View {
    let spinning: Bool

    var body: some View {
        ZStack {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(.tertiary)
                .opacity(spinning ? 0 : 1)
            ProgressView()
                .controlSize(.small)
                .opacity(spinning ? 1 : 0)
        }
        .frame(width: 15, height: 15)
        .animation(.easeInOut(duration: 0.12), value: spinning)
    }
}

/// Settled empty search: every lookup came back and there is nothing to
/// show. An error state is NOT an empty state — when a lookup failed the
/// message says so instead of pretending there are no hits.
struct SearchLookupEmptyState: View {
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: errorMessage == nil
                  ? "magnifyingglass" : "exclamationmark.triangle")
                .scaledFont(size: 22)
                .foregroundStyle(.tertiary)
            if let error = errorMessage {
                Text("search.error.title", bundle: .module)
                    .scaledFont(size: 13, weight: .semibold)
                Text(error)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("search.noResults.title", bundle: .module)
                    .scaledFont(size: 13, weight: .semibold)
                Text("search.noResults.message", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

/// Re-search treatment for lookup rows that answer a superseded query:
/// fade them and float a spinner over their top edge. No layout shift, no
/// list ↔ spinner flicker, and the re-search always reads as "these are
/// being replaced" — a loader appended under the rows would land below
/// the fold instead.
private struct LookupReloadDim: ViewModifier {
    let reloading: Bool

    func body(content: Content) -> some View {
        content
            .opacity(reloading ? 0.3 : 1)
            .overlay(alignment: .top) {
                if reloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 14)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: reloading)
    }
}

extension View {
    func lookupReloadDim(_ reloading: Bool) -> some View {
        modifier(LookupReloadDim(reloading: reloading))
    }
}
