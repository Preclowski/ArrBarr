#if os(macOS)
import SwiftUI

/// The About window.
///
/// Not `orderFrontStandardAboutPanel`: that panel renders whatever you hand it
/// as `.credits` inside its own scroll view, which turned the links into a
/// stack of underlined blue web links fenced off by full-width rules, in three
/// different type sizes. This is the same information laid out as a window —
/// identity block, the three places to go, then the notices that have to be
/// there but nobody reads.
public struct AboutView: View {
    public init() {}

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }

    private static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    public var body: some View {
        VStack(spacing: 0) {
            identity
            links
                .padding(.top, 16)
            notices
                .padding(.top, 20)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Icon, name, version, byline — the block the system panel gets right.
    private var identity: some View {
        VStack(spacing: 6) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
            Text(verbatim: "ArrBarr")
                .font(.title2.weight(.semibold))
            Text(verbatim: Self.version)
                .font(.callout)
                .foregroundStyle(.secondary)
                // Selectable: a version number exists to be pasted into a bug
                // report.
                .textSelection(.enabled)
            // The pretzel is the byline, not decoration — leave it be.
            Text("Made by 🥨", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// The three destinations. Stacked and equal-width, not a wrapping row:
    /// the labels differ in length by a factor of three across languages, so a
    /// row wrapped into a ragged 1 + 2 arrangement that looked accidental.
    private var links: some View {
        VStack(spacing: 6) {
            linkButton("settings.website.button", symbol: "globe", url: "https://arrbarr.app")
            linkButton("settings.privacyPolicy.button", symbol: "hand.raised", url: "https://arrbarr.app/privacy")
            linkButton(verbatim: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                       url: "https://github.com/Preclowski/ArrBarr")
        }
        .frame(width: 210)
    }

    private func linkButton(_ key: LocalizedStringKey, symbol: String, url: String) -> some View {
        linkButton(label: Text(key, bundle: .module), symbol: symbol, url: url)
    }

    private func linkButton(verbatim title: String, symbol: String, url: String) -> some View {
        linkButton(label: Text(verbatim: title), symbol: symbol, url: url)
    }

    private func linkButton(label: Text, symbol: String, url: String) -> some View {
        Button {
            guard let url = URL(string: url) else { return }
            PlatformURLOpener.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 14)
                label.lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .modifier(GlassButtonStyle())
        .controlSize(.small)
    }

    /// Attribution and licence notices. Both are required — CC BY wants the
    /// credit and the licence named, TMDB wants its mark and this exact
    /// sentence — so they are here, short and quiet. The long-form version
    /// (including the "recoloured" modification notice) lives in
    /// Settings → Acknowledgements.
    private var notices: some View {
        VStack(spacing: 3) {
            Divider()
                .padding(.bottom, 5)
            Link(destination: URL(string: "https://dashboardicons.com")!) {
                Text(verbatim: "Dashboard Icons · CC BY 4.0")
            }
            HStack(spacing: 4) {
                Image("rating-tmdb", bundle: .module)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Text(verbatim: "TMDB")
                }
            }
            Text(verbatim: "This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .padding(.top, 1)
            if !Self.copyright.isEmpty {
                Text(verbatim: Self.copyright)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.center)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}
#endif
