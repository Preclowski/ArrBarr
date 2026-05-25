import SwiftUI

public struct DiscoverFilterBar: View {
    @Binding var filter: DiscoverFilter
    let onUserChange: () -> Void
    let onReshuffle: () -> Void

    public init(filter: Binding<DiscoverFilter>,
                onUserChange: @escaping () -> Void,
                onReshuffle: @escaping () -> Void) {
        self._filter = filter
        self.onUserChange = onUserChange
        self.onReshuffle = onReshuffle
    }

    public var body: some View {
        HStack(spacing: 8) {
            decadePicker
            genrePicker
            statusPicker
            monitoredToggle
            Spacer(minLength: 4)
            Button(action: onReshuffle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Reshuffle", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Decade

    private var decadePicker: some View {
        Menu {
            Picker(selection: Binding(
                get: { filter.decade },
                set: { filter.decade = $0; onUserChange() }
            )) {
                ForEach(DiscoverDecade.allCases) { d in
                    Text(d.rawValue).tag(d)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            chipLabel(filter.decade.rawValue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Genre (multi-select)

    private var genrePicker: some View {
        Menu {
            ForEach(DiscoverGenre.allCases) { genre in
                Button {
                    if filter.genres.contains(genre) {
                        filter.genres.remove(genre)
                    } else {
                        filter.genres.insert(genre)
                    }
                    onUserChange()
                } label: {
                    HStack {
                        Text(genre.displayName)
                        if filter.genres.contains(genre) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !filter.genres.isEmpty {
                Divider()
                Button {
                    filter.genres.removeAll()
                    onUserChange()
                } label: {
                    Text("Clear genres", bundle: .module)
                }
            }
        } label: {
            chipLabel(genreLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var genreLabel: String {
        switch filter.genres.count {
        case 0: return String(localized: "Genres", bundle: .module)
        case 1: return filter.genres.first!.displayName
        default:
            let first = filter.genres.sorted(by: { $0.displayName < $1.displayName }).first!
            return "\(first.displayName) +\(filter.genres.count - 1)"
        }
    }

    // MARK: - Status (single-select)

    private var statusPicker: some View {
        Menu {
            Picker(selection: Binding(
                get: { filter.status },
                set: { filter.status = $0; onUserChange() }
            )) {
                ForEach(DiscoverStatus.allCases) { s in
                    Text(LocalizedStringKey(s.rawValue), bundle: .module).tag(s)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            chipLabel(filter.status == .any
                      ? String(localized: "Status", bundle: .module)
                      : String(localized: String.LocalizationValue(filter.status.rawValue), bundle: .module))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Monitored toggle

    private var monitoredToggle: some View {
        Button {
            filter.monitoredOnly.toggle()
            onUserChange()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: filter.monitoredOnly ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 11, weight: .semibold)
                Text("Monitored", bundle: .module)
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundStyle(filter.monitoredOnly ? Color.accentColor : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(
                filter.monitoredOnly
                ? Color.accentColor.opacity(0.18)
                : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared chip label helper

    private func chipLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .scaledFont(size: 11, weight: .medium)
            Image(systemName: "chevron.down").scaledFont(size: 8, weight: .bold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}
