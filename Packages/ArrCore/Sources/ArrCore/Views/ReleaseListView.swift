import SwiftUI

/// Manual / interactive search results for a library item (movie / episode /
/// album) that isn't currently downloading. Pushed from the detail view's
/// "Download" CTA. Lists indexer releases; tapping one grabs it.
///
/// Row layout — two lines whose leading cells share a column, so the type
/// badge sits directly above the age and the release name directly above its
/// specs:
///   (type)  Release file name
///   age     quality  size ……………………………………………… score
/// Hovering a row pops a card with the full release metadata.
struct ReleaseListView: View {
    let target: ManualSearchTarget
    /// The file the library already holds for this item, when it holds one.
    /// Present → the list is framed as an upgrade: a "current file" header over
    /// the results, and each hover card compares its release against it instead
    /// of listing specs in a vacuum. nil → the plain list (nothing on disk, or a
    /// season pack, which replaces many files and so diffs against none).
    ///
    /// Passed in rather than fetched here: the detail views that push this
    /// screen already have the file loaded (and it's the only source that works
    /// in demo mode, where the file endpoints return nil).
    var existing: UpgradeDiffView.Side?
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
                    .accessibilityLabel(Text("settings.back.button", bundle: .module))
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
            // Header sits OUTSIDE the ScrollView: it's the baseline every row
            // is read against, so scrolling to row 30 mustn't lose it.
            currentFileHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(releases) { release in
                        ReleaseRow(
                            release: release,
                            existing: existing,
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

    /// What the library already has, pinned above the results — without it a
    /// list of qualities and sizes says nothing about whether any of them is an
    /// *upgrade*. Same banner the detail view uses for the on-disk file, so the
    /// two surfaces read identically.
    @ViewBuilder
    private var currentFileHeader: some View {
        if let existing {
            VStack(alignment: .leading, spacing: 4) {
                Text("queue.currentFile.button", bundle: .module)
                    .scaledFont(size: 9, weight: .semibold)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                ExistingFileBanner(
                    quality: existing.quality,
                    size: existing.size,
                    customFormatScore: existing.score,
                    customFormats: existing.formats,
                    fileName: existing.filename,
                    showMetadata: true
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            Divider().opacity(0.5)
        }
    }

    private func statusState(symbol: String, text: Text) -> some View {
        VStack(spacing: 8) {
            // Decorative empty/error glyph — the line under it says it.
            Image(systemName: symbol)
                .scaledFont(size: 22, weight: .regular)
                .accessibilityHidden(true)
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

/// The row's leading column — the type badge on line 1, the age on line 2.
///
/// Every cell reserves the width of the widest badge the list can produce
/// ("Torrent") via a hidden ghost, so the column is *the same width on every
/// row*: names and specs line up down the whole list, not just within one row's
/// two lines. A per-row Grid (or measuring the real content) can't do that —
/// each row would still size its own column, and a measured max would make the
/// list shuffle sideways as wider rows scroll into view.
private struct ReleaseLeadCell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .leading) {
            TagChip(text: "Torrent")
                .hidden()
                .accessibilityHidden(true)
            content
        }
    }
}

private struct ReleaseRow: View {
    let release: Release
    let existing: UpgradeDiffView.Side?
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
                    // Line 1 — (type, coloured outline) | file name
                    HStack(spacing: 8) {
                        ReleaseLeadCell {
                            TagChip(text: release.protocolLabel, color: release.isTorrent ? .green : .orange)
                        }
                        // Full-strength regardless of rejection. Dimming the
                        // title made a rejected release read as less of a
                        // release, when the name is the one thing the user
                        // scans every row for — and with most rows rejected on
                        // a typical search, the dimming stopped distinguishing
                        // anything at all. The warning lives on the grab
                        // button, which is what the rejection is actually about.
                        Text(verbatim: release.title)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // Line 2 — age | quality  size …………………………… score
                    HStack(spacing: 8) {
                        // Age leads the metadata line: on a manual search it's
                        // one of the things you actually pick on, and digging it
                        // out of the hover card per row isn't picking.
                        // Monospaced digits keep the column steady while
                        // scrolling ("9d" next to "31d"). Always rendered, dash
                        // and all — an omitted cell would slide the specs left
                        // and break this row's alignment.
                        let age = release.ageLabel ?? "—"
                        ReleaseLeadCell {
                            Text(verbatim: age)
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityLabel(Text("Age", bundle: .module))
                                .accessibilityValue(Text(verbatim: age))
                        }
                        HStack(spacing: 6) {
                            if let quality = release.qualityName {
                                Text(verbatim: quality)
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(.secondary)
                            }
                            // Size rides along with quality rather than sitting
                            // at the far edge: the two are read together ("1080p
                            // for 4 GB?"), and a spec split across the row makes
                            // that a saccade instead of a glance.
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer(minLength: 8)
                            if let score = release.customFormatScore {
                                // Same weight as the age / quality / size cells
                                // it shares the line with — the colour already
                                // carries the emphasis, and bolding on top of it
                                // made the score shout over the spec it belongs to.
                                ScoreLabel(score: score, baseline: existing?.score, size: 10)
                            }
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
        // Grabbing a release sends it straight to the download client — not
        // something to discover by pressing an unlabelled row.
        .accessibilityHint(Text("It will be sent to your download client.", bundle: .module))
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
            ReleaseDetailPopover(release: release, existing: existing)
                .popoverBehavior(.applicationDefined)
        }
        #endif
    }

    @ViewBuilder
    private var grabIndicator: some View {
        if isGrabbing {
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text("Sending to download client", bundle: .module))
        } else if isGrabbed {
            // Green tick is the only "this one is already on its way" cue.
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Sent to download client", bundle: .module))
        } else {
            // Resting affordance duplicating the row's own action. Rejection
            // badges THIS glyph rather than trailing the spec line: the warning
            // is about what pressing the button will do (grab an override), so
            // it belongs on the button, and the spec line stays specs only.
            //
            // Colour-wise it's a `LinkChevron`, not a status glyph: tertiary at
            // rest, secondary while the row is hovered, and it stays that way
            // when the release is rejected. The warning's colour belongs to the
            // badge — bleeding it into the affordance would make the button
            // itself read as a state.
            Image(systemName: "arrow.down.circle")
                .scaledFont(size: 18, weight: .regular)
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .animation(.easeInOut(duration: 0.12), value: hovering)
                .overlay(alignment: .bottomTrailing) {
                    if release.isRejected {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(.orange)
                            // Dark halo so the triangle reads where it overlaps
                            // the circle's stroke, without a solid backing plate
                            // that would need a per-appearance colour.
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .offset(x: 4, y: 3)
                    }
                }
                // Decoration when there's nothing to warn about (the row itself
                // is the labelled button); the badged state is the one thing
                // here VoiceOver must not lose, so it keeps the old "Rejected".
                .accessibilityHidden(!release.isRejected)
                .accessibilityLabel(Text("Rejected", bundle: .module))
        }
    }
}

// MARK: - Hover detail card

private struct ReleaseDetailPopover: View {
    let release: Release
    /// On-disk file to compare against, when the library has one — see
    /// `ReleaseListView.existing`.
    let existing: UpgradeDiffView.Side?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title with the protocol chip on the trailing edge — the same
            // header shape `QueueItemTooltip` uses (title left, badges pushed
            // right, first-baseline aligned). The chip used to sit on its own
            // line under the title, which read as a second heading and pushed
            // the actual content down a row.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: release.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                TagChip(text: release.protocolLabel)
            }

            // With a file on disk the card leads with the diff — the same
            // current → incoming columns (and gained/lost format chips) the
            // queue's upgrade surfaces use, so "is this better than what I
            // have?" is answered before any of the release's own trivia. The
            // dimensions it covers (quality, size, score, formats) then drop out
            // of the table below rather than being printed twice.
            if let existing {
                UpgradeDiffView(current: existing, incoming: UpgradeDiffView.side(release: release))
            }

            VStack(alignment: .leading, spacing: 4) {
                if existing == nil, let quality = release.qualityName { row("Quality", quality) }
                if let indexer = release.indexer { row("Indexer", indexer) }
                if existing == nil {
                    row("Size", ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                }
                if release.isTorrent {
                    row("Seeders / leechers", "\(release.seeders ?? 0) / \(release.leechers ?? 0)")
                }
                if let age = release.ageLabel { row("Age", age) }
                if let group = release.releaseGroup, !group.isEmpty { row("Release group", group) }
                if let langs = languageNames { row("Languages", langs) }
                // Score lives in the table, coloured, no chip outline.
                if existing == nil, let score = release.customFormatScore {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Score", bundle: .module)
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        // A labelled table row, so zero is printed rather than
                        // hidden — an empty cell next to a "Score" label reads
                        // as missing data, not as a score of nothing.
                        Text(verbatim: ScoreLabel.text(score))
                            .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(ScoreLabel.color(score))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Custom formats as chips, like the queue rows (score is in the table).
            let formats = customFormatList
            if existing == nil, !formats.isEmpty {
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
}

// MARK: - Age

private extension Release {
    /// Compact indexer age — "3d" / "12h" / "<1h", `nil` when the arr didn't
    /// report one. Shared by the row and the hover card so the same release
    /// can't read differently in the two places.
    var ageLabel: String? {
        guard let hours = ageHours else { return nil }
        if hours >= 48 { return "\(Int(hours / 24))d" }
        if hours >= 1 { return "\(Int(hours))h" }
        return "<1h"
    }
}
