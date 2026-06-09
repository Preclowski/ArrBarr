import SwiftUI

/// Contextual illustration shown at the top of the paywall. Picks a stylized,
/// static mock that matches the feature the user just tried to use. Built only
/// from existing tokens/symbols — no live data, no new assets.
struct PaywallHero: View {
    let feature: ProFeature

    var body: some View {
        switch feature {
        case .chat:            ChatPaywallHero()
        case .queueAction:     QueuePaywallHero()
        case .addTitle:        AddTitlePaywallHero()
        case .downloadClients: DownloadClientsPaywallHero()
        }
    }
}

// MARK: - Shared card chrome

/// Rounded glass card with a small header row (icon + label + lock) that every
/// hero shares, so the four illustrations read as one family.
private struct HeroCard<Content: View>: View {
    let symbol: String
    let titleKey: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tint)
                Text(titleKey, bundle: .module)
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Chat

private struct ChatPaywallHero: View {
    var body: some View {
        HeroCard(symbol: "sparkles", titleKey: "Chat") {
            VStack(spacing: 6) {
                bubble("What's downloading right now?", mine: true)
                bubble("3 movies in Radarr and a season in Sonarr.", mine: false)
            }
        }
    }

    private func bubble(_ key: LocalizedStringKey, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 28) }
            Text(key, bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mine ? Color.accentColor : Color.primary.opacity(0.08))
                )
            if !mine { Spacer(minLength: 28) }
        }
    }
}

// MARK: - Queue

private struct QueuePaywallHero: View {
    var body: some View {
        HeroCard(symbol: "arrow.down.circle", titleKey: "Queue") {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "No One Will Save You")
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width * 0.72)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 14) {
                    Image(systemName: "pause.fill")
                    Image(systemName: "arrow.clockwise")
                    Image(systemName: "trash")
                    Spacer(minLength: 0)
                    Text(verbatim: "1.0 GB left")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add title

private struct AddTitlePaywallHero: View {
    var body: some View {
        HeroCard(symbol: "plus.circle", titleKey: "Add") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 34, height: 50)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Stranger Things")
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                    Text(verbatim: "2016 · Series")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("paywall.add.button", bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Download clients

private struct DownloadClientsPaywallHero: View {
    private let clients: [(String, String)] = [
        ("SAB", "shippingbox.fill"),
        ("qBit", "arrow.down.app.fill"),
        ("Trans", "bolt.horizontal.fill"),
    ]

    var body: some View {
        HeroCard(symbol: "server.rack", titleKey: "Download clients") {
            HStack(spacing: 8) {
                ForEach(clients, id: \.0) { client in
                    VStack(spacing: 5) {
                        Image(systemName: client.1)
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(.tint)
                        Text(verbatim: client.0)
                            .scaledFont(size: 9, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
            }
        }
    }
}
