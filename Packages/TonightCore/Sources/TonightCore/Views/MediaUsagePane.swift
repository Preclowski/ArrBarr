import SwiftUI
import AppKit
import MediaKit

/// The MediaKit debug window: who is being asked for what, how often the
/// cache saves the trip, and where the same title is being fetched twice.
///
/// This is the answer to "diagnose usage" — the numbers a data layer hides
/// from the UI by design, made visible on purpose. Recording is off until
/// switched on here (or with `MEDIAKIT_DEBUG=1`), because counting every call
/// forever is itself a cost.
struct MediaUsagePane: View {
    @ObservedObject private var stack = MediaStack.shared
    @State private var report: MediaUsageReport?
    @State private var refreshedAt = Date()

    /// Live enough to watch a screen load, calm enough to read.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle(isOn: $stack.telemetryEnabled) {
                    Text("Collect usage data", bundle: .module)
                }
                HStack {
                    Button { Task { await refresh() } } label: {
                        Text("Refresh", bundle: .module)
                    }
                    Button {
                        Task {
                            await stack.resetUsage()
                            await refresh()
                        }
                    } label: {
                        Text("Reset", bundle: .module)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report?.formatted() ?? "",
                                                       forType: .string)
                    } label: {
                        Text("Copy Report", bundle: .module)
                    }
                    .disabled(report == nil)
                }
            } header: {
                Text("Debug", bundle: .module)
            } footer: {
                Text("Counts requests, cache hits and bytes per provider. No URLs or keys are recorded.",
                     bundle: .module)
            }

            if let report, !report.providers.isEmpty {
                providerSection(report)
                fieldSection(report)
                if !report.repeatedFetches.isEmpty { repeatedSection(report) }
            } else {
                SwiftUI.Section {
                    Text(stack.telemetryEnabled
                         ? String(localized: "Nothing recorded yet — open a title.", bundle: .module)
                         : String(localized: "Switch collecting on to see traffic.", bundle: .module))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(tick) { _ in
            guard stack.telemetryEnabled else { return }
            Task { await refresh() }
        }
    }

    // MARK: - Sections

    private func providerSection(_ report: MediaUsageReport) -> some View {
        SwiftUI.Section {
            ForEach(report.providers.sorted { $0.requests > $1.requests }, id: \.provider) { usage in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(usage.provider.rawValue)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(verbatim: "\(usage.bytesDescription) · \(Int(usage.averageDuration * 1000)) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 12) {
                        stat("asked", usage.requests)
                        stat("wire", usage.responses)
                        // The gap between asked and wire is what the layer
                        // saved — the number this whole exercise is about.
                        stat("cache", Int(usage.cacheHitRate * 100), suffix: "%")
                        stat("joined", usage.coalesced)
                        if usage.failures > 0 { stat("failed", usage.failures, tint: .orange) }
                        if usage.skipped > 0 { stat("skipped", usage.skipped) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Providers", bundle: .module)
        }
    }

    private func fieldSection(_ report: MediaUsageReport) -> some View {
        SwiftUI.Section {
            ForEach(MediaField.allCases, id: \.self) { field in
                if let asked = report.fieldRequests[field], asked > 0 {
                    LabeledContent {
                        Text(verbatim: answerText(report, field))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(field.rawValue) ×\(asked)")
                    }
                }
            }
        } header: {
            Text("Fields", bundle: .module)
        } footer: {
            Text("Which source actually won each field.", bundle: .module)
        }
    }

    private func repeatedSection(_ report: MediaUsageReport) -> some View {
        SwiftUI.Section {
            ForEach(report.repeatedFetches.sorted { $0.value > $1.value }.prefix(8), id: \.key) { entry in
                LabeledContent {
                    Text(verbatim: "×\(entry.value)").monospacedDigit()
                } label: {
                    Text(verbatim: entry.key).font(.caption.monospaced())
                }
            }
        } header: {
            Text("Repeated fetches", bundle: .module)
        } footer: {
            Text("The same title asked of the same source more than once — usually a cache key or a view that rebuilds.",
                 bundle: .module)
        }
    }

    private func answerText(_ report: MediaUsageReport, _ field: MediaField) -> String {
        let answers = report.fieldAnswers[field] ?? [:]
        guard !answers.isEmpty else { return "—" }
        return answers.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \($0.value)" }
            .joined(separator: ", ")
    }

    private func stat(_ label: String, _ value: Int, suffix: String = "",
                      tint: Color? = nil) -> some View {
        Text(verbatim: "\(label) \(value)\(suffix)")
            .monospacedDigit()
            .foregroundStyle(tint ?? .secondary)
    }

    private func refresh() async {
        report = await stack.usageReport()
        refreshedAt = .now
    }
}
