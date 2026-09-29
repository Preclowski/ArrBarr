import SwiftUI

/// Sheet for a dropped, opened or magnet-clicked download. No category field on purpose:
/// it follows from the arr, and editing it would break the import.
public struct AddDownloadView: View {
    /// Already narrowed to one protocol by the caller, so one arr choice covers the batch.
    let drops: [DownloadDrop]
    let onFinished: () -> Void

    @Environment(ConfigStore.self) private var configStore

    @State private var destinations: [DownloadDestination] = []
    @State private var selectedArr: ServiceKind?
    @State private var selectedDestination: DownloadDestination?
    @State private var paused = false
    @State private var loading = true
    @State private var submitting = false
    @State private var failure: String?

    public init(drops: [DownloadDrop], onFinished: @escaping () -> Void) {
        self.drops = drops
        self.onFinished = onFinished
    }

    /// Only arrs with at least one usable client for this protocol.
    private var arrs: [ServiceKind] {
        ServiceKind.arrKinds.filter { arr in destinations.contains { $0.arr == arr } }
    }

    private var clientsForSelection: [DownloadDestination] {
        destinations.filter { $0.arr == selectedArr }
    }

    private var kind: DownloadKind { drops.first?.kind ?? .torrent }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            payloadSummary

            if loading {
                LoadingStateView(label: nil)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else if arrs.isEmpty {
                emptyState
            } else {
                arrTiles
                if clientsForSelection.count > 1 { clientPicker }
                Toggle(isOn: $paused) {
                    Text("Add paused", bundle: .module)
                }
            }

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(role: .cancel) { onFinished() } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submit() }
                } label: {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add", bundle: .module)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDestination == nil || submitting)
            }
        }
        .padding(20)
        // Fixed, not `minWidth`: the window sizes to fit, so a long release name would widen it.
        // The name truncates in the middle instead.
        .frame(width: 340)
        .environment(\.locale, configStore.currentLocale)
        .task { await resolve() }
        // Re-reads the new client's paused default so the checkbox stays truthful.
        .onChange(of: selectedArr) { _, _ in
            selectedDestination = clientsForSelection.first
        }
        .onChange(of: selectedDestination) { _, destination in
            guard let destination else { return }
            Task { await loadPausedDefault(for: destination) }
        }
    }

    private var payloadSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .usenet ? "doc.text" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            if drops.count == 1, let drop = drops.first {
                Text(drop.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("addDownload.fileCount \(drops.count)", bundle: .module)
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No arr can take this", bundle: .module)
                .font(.callout.weight(.medium))
            // Names the missing half: the fix differs for each.
            Text(
                kind == .usenet
                    ? "None of your configured arrs has a usenet download client that ArrBarr can also reach."
                    : "None of your configured arrs has a torrent download client that ArrBarr can also reach.",
                bundle: .module
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arrTiles: some View {
        HStack(spacing: 8) {
            ForEach(arrs, id: \.self) { arr in
                let selected = selectedArr == arr
                Button {
                    selectedArr = arr
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: arr.symbolName)
                            .font(.title3)
                        Text(arr.displayName)
                            .font(.caption)
                            .fontWeight(selected ? .medium : .regular)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: selected ? 2 : 0.5
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : .primary)
            }
        }
    }

    private var clientPicker: some View {
        Picker(selection: $selectedDestination) {
            ForEach(clientsForSelection) { destination in
                Text(destination.client.name).tag(Optional(destination))
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func resolve() async {
        let configs = configStore.downloadDropConfigs
        let resolved = await DownloadDropService.shared.destinations(for: kind, configs: configs)
        destinations = resolved
        selectedArr = resolved.first?.arr
        selectedDestination = resolved.first
        loading = false
        if let first = resolved.first { await loadPausedDefault(for: first) }
    }

    private func loadPausedDefault(for destination: DownloadDestination) async {
        paused = await DownloadDropService.shared.defaultPaused(for: destination, configs: configStore.downloadDropConfigs)
    }

    /// A partial failure keeps the window open and names the failed count, so the user can retry.
    private func submit() async {
        guard let destination = selectedDestination else { return }
        submitting = true
        failure = nil
        let configs = configStore.downloadDropConfigs

        var failed = 0
        var lastError: String?
        for drop in drops {
            do {
                try await DownloadDropService.shared.add(drop, to: destination, paused: paused, configs: configs)
            } catch {
                failed += 1
                lastError = error.localizedDescription
            }
        }
        submitting = false

        guard failed == 0 else {
            failure = drops.count == 1
                ? (lastError ?? String(localized: "The download client refused the file.", bundle: .module))
                : String(localized: "addDownload.partialFailure \(failed) \(drops.count) \(lastError ?? "")", bundle: .module)
            return
        }
        onFinished()
    }
}
