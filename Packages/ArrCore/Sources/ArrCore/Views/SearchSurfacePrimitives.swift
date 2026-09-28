import SwiftUI

/// Both layers always exist and only opacity changes: ProgressView and the
/// magnifier differ in intrinsic width, so an if/else shifts the field.
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

/// A failed lookup says so rather than pretending there are no hits.
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

/// Fades superseded rows under a spinner: no layout shift, and a loader below
/// the rows would land below the fold.
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
