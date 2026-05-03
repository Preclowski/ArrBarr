import SwiftUI
import AppKit

struct WelcomeView: View {
    let variant: WelcomeContent.Variant
    let onDismiss: () -> Void
    let onAddService: () -> Void
    let onTryDemo: () -> Void

    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            featureList
            footer
        }
        .frame(width: 600, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, configStore.currentLocale)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            appIcon
                .frame(width: 96, height: 96)
            Text(titleText)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 36)
        .padding(.bottom, 26)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Feature list

    private var featureList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(WelcomeContent.features(for: variant)) { item in
                    FeatureRow(item: item)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if case .firstRun = variant {
                    Button(String(localized: "Try demo mode")) { onTryDemo() }
                        .buttonStyle(.link)
                }
                Spacer()
                Button(primaryButtonTitle) { onPrimary() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }

    // MARK: - Strings

    private var titleText: String {
        switch variant {
        case .firstRun:
            return String(localized: "Welcome to ArrBarr")
        case .whatsNew:
            return String(localized: "What's New in ArrBarr")
        }
    }

    private var subtitleText: String {
        switch variant {
        case .firstRun:
            return String(localized: "Your menu-bar companion for Radarr, Sonarr, and Lidarr.")
        case .whatsNew(let v):
            return String(format: String(localized: "Version %@"), v)
        }
    }

    private var primaryButtonTitle: String {
        switch variant {
        case .firstRun: return String(localized: "Add a service")
        case .whatsNew: return String(localized: "Continue")
        }
    }

    private func onPrimary() {
        switch variant {
        case .firstRun:
            onAddService()
        case .whatsNew:
            onDismiss()
        }
    }
}

private struct FeatureRow: View {
    let item: WelcomeContent.FeatureItem

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: item.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 44, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(item.titleKey))
                    .font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(item.bodyKey))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
