import SwiftUI
import WebKit

/// YouTube trailer in a sheet — privacy-enhanced embed, no API key needed.
struct TrailerSheet: View {
    let youTubeKey: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Text("Done", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            YouTubeEmbed(key: youTubeKey)
                .frame(width: 854, height: 480)
        }
        .background(.black)
        .colorScheme(.dark)
    }
}

private struct YouTubeEmbed: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Without this the player's fullscreen button is silently inert.
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        // A bare navigation to the embed URL arrives with no Origin/Referer,
        // which YouTube rejects with player error 153. Hosting the iframe in
        // a page whose baseURL is the embed host (plus a desktop Safari UA)
        // gives the player the origin it insists on.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&playsinline=1&rel=0&modestbranding=1&iv_load_policy=3&fs=1&color=white"
                allow="autoplay; encrypted-media; fullscreen; picture-in-picture"
                allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
