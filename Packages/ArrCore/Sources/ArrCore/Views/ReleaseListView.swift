import SwiftUI

/// Manual / interactive search results for a library item (movie / episode /
/// album) that isn't currently downloading. Pushed from the detail view's
/// "Download" CTA. Lists indexer releases; tapping one grabs it.
///
/// Row layout (per the spec):
///   (type) Release file name
///   (quality) (indexer) score                              size
/// Hovering a row pops a card with the full release metadata.
struct ReleaseListView: View {
    let target: ManualSearchTarget
    let onBack: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    @State private var releases: [Release] = []
    @State private var loading = true
    @State private var loadError: String?
    /// Guards against re-running the (indexer-hitting) search every time the
    /// menu-bar popover reopens — we fetch once per target and keep the results.
    @State private var loadedTargetId: String?
    /// The in-flight fetch, held as an UNSTRUCTURED task so closing the menu-bar
    /// popover (which would cancel a `.task`) doesn't abort the search mid-flight.
    @State private var loadTask: Task<Void, Never>?
    @State private var grabbing: Set<String> = []
    @State private var grabbed: Set<String> = []
    @State private var pendingGrab: Release?
    @State private var showGrabConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Always self-draw the back header on macOS. The parent DetailView
            // hides the window toolbar (for its own self-drawn header), which
            // suppresses the native NavigationStack chevron for everything pushed
            // below it — so without this the release list would be a back-less
            // trap in the menu-bar popover. iOS keeps the native nav bar.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                Text(verbatim: target.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif
            content
        }
        #if os(iOS)
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        .onAppear {
            // Fetch once per target, in a detached task that survives the popover
            // closing — reopening neither re-hits the indexers nor aborts a search
            // that's still running.
            guard loadedTargetId != target.id, loadTask == nil else { return }
            loadTask = Task {
                await load()
                loadTask = nil
            }
        }
        .inlineConfirm(
            isPresented: $showGrabConfirm,
            title: "Download this release?",
            message: "It will be sent to your download client.",
            confirmLabel: "Download",
            onConfirm: { grab(pendingGrab) }
        )
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            statusState(symbol: "exclamationmark.triangle", text: Text(verbatim: loadError))
        } else if releases.isEmpty {
            statusState(symbol: "magnifyingglass", text: Text("No releases found", bundle: .module))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(releases) { release in
                        ReleaseRow(
                            release: release,
                            isGrabbing: grabbing.contains(release.guid),
                            isGrabbed: grabbed.contains(release.guid)
                        ) {
                            pendingGrab = release
                            showGrabConfirm = true
                        }
                        Divider().opacity(0.35)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func statusState(symbol: String, text: Text) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(size: 22, weight: .regular)
            text.scaledFont(size: 12)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func makeClient() -> (any ArrAPIClient)? {
        switch target.source {
        case .radarr: return RadarrClient(config: configStore.radarr)
        case .sonarr: return SonarrClient(config: configStore.sonarr)
        case .lidarr: return LidarrClient(config: configStore.lidarr)
        case .whisparr: return WhisparrClient(config: configStore.whisparr)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        guard let client = makeClient() else {
            loadError = String(localized: "Service not configured", bundle: .module)
            return
        }
        do {
            let result = try await client.fetchReleases(query: target.query)
            // Keep the arr's own ranking, but sink rejected releases to the
            // bottom (they need an override to grab and are rarely what's wanted).
            var ordered = result.filter { !$0.isRejected } + result.filter { $0.isRejected }
            // A season search returns per-episode releases alongside the packs;
            // for a whole-season download the user wants the packs, so show only
            // those when any exist (also keeps the list short → no scroll jank
            // from dozens of episode rows). Fall back to everything when the
            // season genuinely has no pack.
            if target.isSeasonSearch {
                let packs = ordered.filter { $0.fullSeason == true }
                if !packs.isEmpty { ordered = packs }
            }
            releases = ordered
            loadedTargetId = target.id
        } catch is CancellationError {
            // view went away mid-load — ignore
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func grab(_ release: Release?) {
        guard let release, let indexerId = release.indexerId, let client = makeClient() else { return }
        grabbing.insert(release.guid)
        Task {
            do {
                try await client.grabRelease(guid: release.guid, indexerId: indexerId)
                await MainActor.run {
                    grabbing.remove(release.guid)
                    grabbed.insert(release.guid)
                }
            } catch {
                await MainActor.run {
                    grabbing.remove(release.guid)
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Row

private struct ReleaseRow: View {
    let release: Release
    let isGrabbing: Bool
    let isGrabbed: Bool
    let onGrab: () -> Void

    @State private var hovering = false
    @State private var showPopover = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: onGrab) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // Line 1 — (type, coloured outline) file name
                    HStack(spacing: 6) {
                        TagChip(text: release.protocolLabel, color: release.isTorrent ? .green : .orange)
                        Text(verbatim: release.title)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(release.isRejected ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // Line 2 — quality ........ score  size  (warning)  (plain text)
                    HStack(spacing: 6) {
                        if let quality = release.qualityName {
                            Text(verbatim: quality)
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let score = release.customFormatScore {
                            Text(verbatim: "\(score > 0 ? "+" : "")\(score)")
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(score > 0 ? Color.green : score < 0 ? Color.red : Color.secondary)
                        }
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                            .scaledFont(size: 10, weight: .medium)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if release.isRejected {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                grabIndicator
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGrabbing || isGrabbed)
        #if os(macOS)
        .onHover { isHovering in
            hovering = isHovering
            hoverTask?.cancel()
            if isHovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled, hovering { showPopover = true }
                }
            } else {
                showPopover = false
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            ReleaseDetailPopover(release: release)
                .popoverBehavior(.applicationDefined)
        }
        #endif
    }

    @ViewBuilder
    private var grabIndicator: some View {
        if isGrabbing {
            ProgressView().controlSize(.small)
        } else if isGrabbed {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 15, weight: .regular)
                .foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.down.circle")
                .scaledFont(size: 15, weight: .regular)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.45)
        }
    }
}

// MARK: - Hover detail card

private struct ReleaseDetailPopover: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: release.title)
                .scaledFont(size: 12, weight: .semibold)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            // Protocol as the same outlined chip used on the list.
            TagChip(text: release.protocolLabel)

            VStack(alignment: .leading, spacing: 4) {
                if let quality = release.qualityName { row("Quality", quality) }
                if let indexer = release.indexer { row("Indexer", indexer) }
                row("Size", ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                if release.isTorrent {
                    row("Seeders / leechers", "\(release.seeders ?? 0) / \(release.leechers ?? 0)")
                }
                if let hours = release.ageHours { row("Age", ageText(hours)) }
                if let group = release.releaseGroup, !group.isEmpty { row("Release group", group) }
                if let langs = languageNames { row("Languages", langs) }
                // Score lives in the table, coloured, no chip outline.
                if let score = release.customFormatScore {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Score", bundle: .module)
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(verbatim: "\(score > 0 ? "+" : "")\(score)")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(score > 0 ? Color.green : score < 0 ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Custom formats as chips, like the queue rows (score is in the table).
            let formats = customFormatList
            if !formats.isEmpty {
                CustomFormatChips(formats: formats, score: 0)
            }

            if release.isRejected, let rejections = release.rejections, !rejections.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label { Text("Rejected", bundle: .module) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.orange)
                    ForEach(rejections, id: \.self) { reason in
                        Text(verbatim: "• \(reason)")
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label, bundle: .module)
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: value)
                .scaledFont(size: 10, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageNames: String? {
        let names = (release.languages ?? []).compactMap { $0.name }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var customFormatList: [String] {
        (release.customFormats ?? []).compactMap { $0.name }
    }

    private func ageText(_ hours: Double) -> String {
        if hours >= 48 { return "\(Int(hours / 24))d" }
        if hours >= 1 { return "\(Int(hours))h" }
        return "<1h"
    }
}
