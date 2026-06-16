import SwiftUI

/// ArrBarr Control paywall. The app is free to *watch*; this screen sells the
/// one-time unlock that turns on *interaction* ("Control"). The hero, headline
/// and subtitle adapt to the gated feature; the free reassurance, benefits, CTA
/// and footer are constant. No "pro"/"premium" wording — the upgrade is
/// "Control". Hosted in an NSWindow on macOS and a full-screen cover on iOS.
public struct PaywallView: View {
    @ObservedObject private var store = StoreManager.shared
    let context: ProFeature?
    let onClose: () -> Void

    public init(context: ProFeature?, onClose: @escaping () -> Void) {
        self.context = context
        self.onClose = onClose
    }

    private var feature: ProFeature { context ?? .chat }

    private let benefitKeys: [String] = [
        "Ask and manage in plain language",
        "Add movies and shows in one sentence",
        "Pause, resume and retry without a browser",
        "Plus everything else from Control mode",
    ]

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                hero

                VStack(spacing: 6) {
                    Text(LocalizedStringKey(feature.paywallHeadlineKey), bundle: .module)
                        .scaledFont(size: 21, weight: .bold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringKey(feature.paywallSubtitleKey), bundle: .module)
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                freeChip
                benefitsList
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)

            Spacer(minLength: 14)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
        #if !os(macOS)
        .overlay(alignment: .topTrailing) {
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        #endif
    }

    // MARK: - Hero (with accent glow)

    private var hero: some View {
        PaywallHero(feature: feature)
            .background(alignment: .top) {
                Ellipse()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(height: 120)
                    .blur(radius: 55)
                    .offset(y: -10)
                    .allowsHitTesting(false)
            }
    }

    // MARK: - "Free to watch" reassurance

    private var freeChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .scaledFont(size: 11, weight: .semibold)
            Text("paywall.watchingIsAlwaysFree.button", bundle: .module)
                .scaledFont(size: 11, weight: .medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Benefits

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(benefitKeys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(.green)
                    Text(LocalizedStringKey(key), bundle: .module)
                        .scaledFont(size: 13)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - Footer (CTA + reassurance + links)

    private var footer: some View {
        VStack(spacing: 11) {
            Button {
                Task { await store.purchase() }
            } label: {
                HStack(spacing: 6) {
                    Text("paywall.unlockControl.button", bundle: .module)
                    if let price = store.displayPrice {
                        Text(verbatim: "· \(price)")
                    }
                }
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)

            Text("paywall.oneTimePurchaseNo.tooltip", bundle: .module)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button { onClose() } label: { Text("paywall.maybeLater.button", bundle: .module) }
                    .buttonStyle(.plain)
                Button { Task { await store.restore() } } label: { Text("paywall.restorePurchases.button", bundle: .module) }
                    .buttonStyle(.plain)
                Link(destination: URL(string: "https://arrbarr.app/privacy")!) {
                    Text("settings.privacyPolicy.button", bundle: .module)
                }
            }
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}
