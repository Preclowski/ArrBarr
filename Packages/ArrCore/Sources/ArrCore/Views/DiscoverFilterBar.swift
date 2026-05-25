import SwiftUI

public struct DiscoverFilterBar: View {
    @Binding var filter: DiscoverFilter
    let onReshuffle: () -> Void

    public init(filter: Binding<DiscoverFilter>,
                onReshuffle: @escaping () -> Void) {
        self._filter = filter
        self.onReshuffle = onReshuffle
    }

    public var body: some View {
        HStack(spacing: 8) {
            decadePicker
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

    private var decadePicker: some View {
        Menu {
            Picker(selection: $filter.decade) {
                ForEach(DiscoverDecade.allCases) { d in
                    Text(d.rawValue).tag(d)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(filter.decade.rawValue)
                    .scaledFont(size: 11, weight: .medium)
                Image(systemName: "chevron.down").scaledFont(size: 8, weight: .bold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var monitoredToggle: some View {
        Button {
            filter.monitoredOnly.toggle()
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
}
