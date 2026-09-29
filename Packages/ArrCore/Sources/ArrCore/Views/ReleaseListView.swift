import SwiftUI
import MediaKit

/// Manual search results for a library item that isn't downloading; a row expands
/// into the detail that decides the grab.
struct ReleaseListView: View {
    let target: ManualSearchTarget
    /// Present → upgrade framing with a diff per release; nil for nothing on disk or a season pack.
    /// Passed in because it's the only source that works in demo mode (file endpoints return nil).
    var existing: UpgradeDiffView.Side?
    /// A season pack has no single baseline, but its per-episode rows do.
    var existingByEpisode: [Int: UpgradeDiffView.Side] = [:]
    var waitContext = WaitCardContext()
    let onBack: () -> Void

    @EnvironmentObject var configStore: ConfigStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var releases: [ArrRelease] = []
    @State private var loading = true
    @State private var loadError: String?
    /// Fetch once per target; reopening the popover must not re-hit the indexers.
    @State private var loadedTargetId: String?
    /// Unstructured so closing the popover (which cancels a `.task`) doesn't abort the search.
    @State private var loadTask: Task<Void, Never>?
    @State private var grabbing: Set<String> = []
    @State private var grabbed: Set<String> = []
    @State private var pendingGrab: ArrRelease?
    @State private var showGrabConfirm = false
    /// One at a time: two open rows in a 380pt popover is a scroll, not a comparison.
    @State private var expanded: String?
    @State private var scope: ScopeFilter = .all
    @State private var sort: ReleaseSort = .rank
    @State private var showRejected = false
    /// Empty until it loads; the row falls back to the arr's own label meanwhile.
    @State private var indexerNames: [Int: String] = [:]

    private enum ScopeFilter { case all, packs, episodes }

    private enum ReleaseSort: CaseIterable {
        case rank, score, seeders, size, age

        var title: Text {
            switch self {
            case .rank: Text("Rank", bundle: .module)
            case .score: Text("Score", bundle: .module)
            case .seeders: Text("Seeders", bundle: .module)
            case .size: Text("Size", bundle: .module)
            case .age: Text("Age", bundle: .module)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // DetailView hides the toolbar, which suppresses the NavigationStack chevron
            // for everything pushed below it; without this the list is a back-less trap.
            HStack(spacing: 6) {
                FloatingBackButton(action: onBack)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("settings.back.button", bundle: .module))
                Text(verbatim: target.title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !releases.isEmpty {
                    viewMenu
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            #endif
            content
        }
        // The wait stage runs under the header too, and the header reads on it.
        .background { if loading { WaitBackdrop(poster: waitContext.poster) } }
        .environment(\.colorScheme, loading ? .dark : colorScheme)
        #if os(iOS)
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { viewMenu } }
        #else
        .toolbar(.hidden, for: .windowToolbar)
        #endif
        .onAppear {
            guard loadedTargetId != target.id, loadTask == nil else { return }
            loadTask = Task {
                await load()
                loadTask = nil
            }
        }
        .inlineConfirm(
            isPresented: $showGrabConfirm,
            title: "Download this release?",
            message: pendingGrab?.isRejected == true
                ? "Your *arr rejected it — downloading anyway overrides that."
                : "It will be sent to your download client.",
            confirmLabel: "Download",
            onConfirm: { grab(pendingGrab) }
        )
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            WaitStories(context: waitContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            statusState(symbol: "exclamationmark.triangle", text: Text(verbatim: loadError))
        } else if releases.isEmpty {
            statusState(symbol: "magnifyingglass", text: Text("No releases found", bundle: .module))
        } else if visible.isEmpty {
            // Said outright: an empty list would read as "the search found nothing".
            statusState(symbol: "line.3.horizontal.decrease.circle",
                        text: Text("Every result is filtered out.", bundle: .module))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { release in
                        row(release)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func row(_ release: ArrRelease) -> some View {
        let isExpanded = expanded == release.guid
        VStack(spacing: 0) {
            ReleaseRow(
                release: release,
                existing: baseline(for: release),
                indexerName: indexerName(for: release),
                showScope: target.isSeasonSearch,
                isExpanded: isExpanded,
                isGrabbing: grabbing.contains(release.guid),
                isGrabbed: grabbed.contains(release.guid),
                onTap: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expanded = isExpanded ? nil : release.guid
                    }
                },
                onGrab: {
                    pendingGrab = release
                    showGrabConfirm = true
                }
            )
            #if os(iOS)
            if isExpanded {
                ReleaseDetail(release: release, existing: baseline(for: release),
                              indexerName: indexerName(for: release))
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
            #endif
        }
        .background(isExpanded ? drawerFill : Color.clear)
        Divider().opacity(0.35)
    }

    private var drawerFill: Color {
        Color.primary.opacity(0.05)
    }

    /// Rejected releases need an override to grab, so they stay hidden until toggled on.
    private var viewMenu: some View {
        TrailingMenu {
            Section {
                Picker(selection: $sort) {
                    ForEach(ReleaseSort.allCases, id: \.self) { $0.title.tag($0) }
                } label: { Text("Sort", bundle: .module) }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                if target.isSeasonSearch {
                    Picker(selection: $scope.animation(.easeInOut(duration: 0.15))) {
                        Text("All", bundle: .module).tag(ScopeFilter.all)
                        Text("Packs", bundle: .module).tag(ScopeFilter.packs)
                        Text("Episodes", bundle: .module).tag(ScopeFilter.episodes)
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Toggle(isOn: $showRejected.animation(.easeInOut(duration: 0.15))) {
                    Text("release.showRejected \(rejected.count)", bundle: .module)
                }
                .disabled(rejected.isEmpty)
            }
        } label: {
            #if os(macOS)
            HeaderGlyph(systemName: "slider.horizontal.3")
            #else
            Label { Text("View", bundle: .module) } icon: { Image(systemName: "slider.horizontal.3") }
            #endif
        }
        .help(Text("View", bundle: .module))
        .accessibilityLabel(Text("View", bundle: .module))
    }

    private func statusState(symbol: String, text: Text) -> some View {
        VStack(spacing: 8) {
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

    private func indexerName(for release: ArrRelease) -> String? {
        release.indexerId.flatMap { indexerNames[$0] } ?? release.indexerName
    }

    private func baseline(for release: ArrRelease) -> UpgradeDiffView.Side? {
        if let existing { return existing }
        let numbers = release.episodeNumbers ?? []
        guard numbers.count == 1, let number = numbers.first else { return nil }
        return existingByEpisode[number]
    }

    // MARK: - Ordering

    /// Rejected appended after, so revealing them never reorders the rows above.
    private var visible: [ArrRelease] { accepted + (showRejected ? ordered(rejected) : []) }
    private var accepted: [ArrRelease] { ordered(releases.filter { !$0.isRejected }) }
    private var rejected: [ArrRelease] { releases.filter(\.isRejected) }

    private func ordered(_ input: [ArrRelease]) -> [ArrRelease] {
        let scoped = input.filter { release in
            guard target.isSeasonSearch else { return true }
            switch scope {
            case .all: return true
            case .packs: return release.fullSeason == true
            case .episodes: return release.fullSeason != true
            }
        }
        switch sort {
        case .rank: return scoped
        case .score: return scoped.sorted { ($0.customFormatScore ?? 0) > ($1.customFormatScore ?? 0) }
        case .seeders: return scoped.sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        case .size: return scoped.sorted { $0.sizeBytes > $1.sizeBytes }
        case .age: return scoped.sorted { ($0.ageHours ?? .greatestFiniteMagnitude) < ($1.ageHours ?? .greatestFiniteMagnitude) }
        }
    }

    // MARK: - Data

    private func makeClient() -> (any ArrAPIClient)? {
        configStore.arrClient(for: target.source)
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
            releases = try await client.fetchReleases(target.release)
            loadedTargetId = target.id
            Task { indexerNames = await IndexerNames.names(for: target.source, configStore: configStore) }
            // All rejected is normal for a complete season; hiding them all would show a blank screen.
            showRejected = releases.allSatisfy(\.isRejected)
        } catch is CancellationError {
            // view went away mid-load — ignore
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func grab(_ release: ArrRelease?) {
        guard let release, let indexerId = release.indexerId, let client = makeClient() else { return }
        grabbing.insert(release.guid)
        Task {
            do {
                try await client.grabRelease(guid: release.guid, indexerId: indexerId)
                await MainActor.run {
                    grabbing.remove(release.guid)
                    grabbed.insert(release.guid)
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = nil }
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

/// Every cell reserves the widest badge's width ("Torrent") via a hidden ghost, so the
/// column is equal on every row; a measured max would shuffle sideways while scrolling.
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
    let release: ArrRelease
    let existing: UpgradeDiffView.Side?
    let indexerName: String?
    let showScope: Bool
    let isExpanded: Bool
    let isGrabbing: Bool
    let isGrabbed: Bool
    let onTap: () -> Void
    let onGrab: () -> Void


    var body: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            lines
            #else
            Button(action: onTap) { lines }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the release's details.", bundle: .module))
            #endif
            // Its own control, so reading a row never grabs it.
            grabControl
                .padding(.trailing, 12)
        }
        #if os(macOS)
        // The hover card is the whole detail; the indexer's page moves to the context menu.
        .hoverTooltip(delay: .milliseconds(400)) {
            ReleaseDetail(release: release, existing: existing, indexerName: indexerName, showsLink: false)
                .padding(12)
                .frame(width: 340)
        }
        .contextMenu {
            if let info = release.infoUrl, let url = URL(string: info) {
                Button { PlatformURLOpener.open(url) } label: {
                    if let indexerName {
                        Text("Open in \(indexerName)", bundle: .module)
                    } else {
                        Text("Open in browser", bundle: .module)
                    }
                }
            }
        }
        #endif
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleLine
            specLine
            reasonLine
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            if showScope {
                ReleaseLeadCell { scopeBadge }
            }
            // Not dimmed when rejected: the name is what the user scans every row for.
            Text(verbatim: release.shortTitle)
                .scaledFont(size: 12)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            #if os(iOS)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            #endif
        }
    }

    private var specLine: some View {
        HStack(spacing: 8) {
            ReleaseLeadCell {
                TagChip(text: release.protocolLabel, color: release.isTorrent ? .green : .orange)
            }
            Text(verbatim: specs)
                .scaledFont(size: 11, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var reasonLine: some View {
        HStack(spacing: 8) {
            // Always rendered: an omitted cell would slide the rest left and break alignment.
            let age = release.ageLabel ?? "—"
            ReleaseLeadCell {
                Text(verbatim: age)
                    .scaledFont(size: 11, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Age", bundle: .module))
                    .accessibilityValue(Text(verbatim: age))
            }
            HStack(spacing: 5) {
                ForEach(reasons, id: \.text) { reason in
                    if reason.isFormat {
                        TagChip(text: reason.text, color: reason.color)
                            .lineLimit(1)
                    } else {
                        Text(verbatim: reason.text)
                            .scaledFont(size: 11)
                            .foregroundStyle(reason.color)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            scoreCell
        }
    }

    @ViewBuilder
    private var scopeBadge: some View {
        switch release.scope {
        case .pack:
            TagChip(text: String(localized: "release.scope.pack", bundle: .module), color: .purple)
        case .episodes(let label):
            TagChip(text: label, color: .blue)
        case nil:
            EmptyView()
        }
    }

    /// A sent release is downloading, not downloaded.
    @ViewBuilder
    private var grabControl: some View {
        if isGrabbing {
            ProgressView().controlSize(.small)
                .frame(width: 22)
                .accessibilityLabel(Text("Sending to download client", bundle: .module))
        } else if isGrabbed {
            Label { Text("queue.downloading.button", bundle: .module) } icon: { Image(systemName: "arrow.down.circle.fill") }
                .scaledFont(size: 11)
                .foregroundStyle(QueueItem.Status.downloading.tint)
        } else {
            Button(action: onGrab) {
                Image(systemName: "arrow.down.circle")
                    .scaledFont(size: 17)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Download", bundle: .module))
            .accessibilityLabel(Text("Download", bundle: .module))
        }
    }

    @ViewBuilder
    private var scoreCell: some View {
        if let score = release.customFormatScore {
            ScoreLabel(score: score, baseline: existing?.score, size: 11)
        }
    }

    private var specs: String {
        var parts: [String] = []
        if let indexer = indexerName { parts.append(indexer) }
        if let quality = release.qualityName { parts.append(quality) }
        if release.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
        }
        if release.isTorrent {
            parts.append("↑\(release.seeders ?? 0) ↓\(release.leechers ?? 0)")
        }
        return parts.joined(separator: " · ")
    }

    private var reasons: [(text: String, color: Color, isFormat: Bool)] {
        var out: [(text: String, color: Color, isFormat: Bool)] = []
        let languages = (release.languages ?? []).compactMap(\.name)
        if languages.count > 1 || (languages.first.map { $0 != "English" } ?? false) {
            out.append((languages.joined(separator: ", "), .secondary, false))
        }
        out += release.indexerFlagNames.map { (text: $0, color: Color.green, isFormat: false) }
        let baseline = Set(existing?.formats ?? [])
        let formats = (release.customFormats ?? []).compactMap(\.name)
        out += formats.map { (text: $0, color: existing != nil && !baseline.contains($0) ? Color.green : Color.primary, isFormat: true) }
        guard out.count > 4 else { return out }
        return Array(out.prefix(3)) + [(text: "+\(out.count - 3)", color: .secondary, isFormat: false)]
    }
}

// MARK: - Detail

private struct ReleaseDetail: View {
    let release: ArrRelease
    let existing: UpgradeDiffView.Side?
    let indexerName: String?
    var showsLink = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The diff covers quality, size, score and formats, so they drop out of the table below.
            if let existing {
                UpgradeDiffView(current: existing, incoming: UpgradeDiffView.side(release: release), labeled: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                if existing == nil, let quality = release.qualityName { row("Quality", quality) }
                if existing == nil {
                    row("Size", ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))
                }
                if existing == nil, let score = release.customFormatScore {
                    HStack(alignment: .top, spacing: 8) {
                        label("Score")
                        // Zero is printed: an empty cell next to a label reads as missing data.
                        Text(verbatim: ScoreLabel.text(score))
                            .scaledFont(size: 11, monospacedDigit: true)
                            .foregroundStyle(ScoreLabel.color(score))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let indexer = indexerName { row("Indexer", indexer) }
                if release.isTorrent {
                    row("Seeders / leechers", "\(release.seeders ?? 0) / \(release.leechers ?? 0)")
                }
                if let age = release.ageLabel { row("Age", age) }
                if let group = release.releaseGroup, !group.isEmpty { row("ArrRelease group", group) }
                if let langs = languageNames { row("Languages", langs) }
            }

            let formats = customFormatList
            if existing == nil, !formats.isEmpty {
                CustomFormatChips(formats: formats, score: 0)
            }

            if release.isRejected, let rejections = release.rejections, !rejections.isEmpty {
                QueueStatusMessagesBanner(messages: rejections, tint: .orange)
            }

            ReleaseNameBlock(release: release.title, existing: existing?.filename)
                .textSelection(.enabled)

            if showsLink, let info = release.infoUrl, let url = URL(string: info) {
                    Link(destination: url) {
                        Label {
                            if let indexer = indexerName {
                                Text("Open in \(indexer)", bundle: .module)
                            } else {
                                Text("Open in browser", bundle: .module)
                            }
                        } icon: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .scaledFont(size: 11, weight: .medium)
                    }
                    .modifier(GlassButtonStyle())
                    .controlSize(.small)
            }
        }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            label(key)
            Text(verbatim: value)
                .scaledFont(size: 11)
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

private extension ArrRelease {
    /// Shared by the row and the detail so the same release can't read differently.
    var ageLabel: String? {
        guard let hours = ageHours else { return nil }
        if hours >= 48 { return "\(Int(hours / 24))d" }
        if hours >= 1 { return "\(Int(hours))h" }
        return "<1h"
    }
}
