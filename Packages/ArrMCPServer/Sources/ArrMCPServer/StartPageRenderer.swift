import Foundation
import ArrCore

/// Turns a `StartPageSnapshot` into a self-contained HTML status page (or JSON).
/// Pure, stateless, English-only. This is the *display layer*: every byte/date/
/// status/source string is formatted here, once, so the raw snapshot stays a
/// clean data model and nothing leaks the OS locale onto the page.
///
/// Visual language is "Liquid Glass": translucent frosted panels floating over a
/// vivid, blurred backdrop, with a soft edge sheen and layered shadows.
enum StartPageRenderer {
    /// Auto-refresh cadence (browser re-fetches static HTML; the app rebuilds the
    /// snapshot from already-live data, so this costs no extra arr API calls).
    private static let refreshSeconds = 10

    // MARK: - HTML

    static func html(_ s: StartPageSnapshot) -> String {
        var body = ""

        body += #"<header><div class="brandrow">"#
        if let icon = s.appIcon { body += #"<img class="logo-ic" src="\#(icon)" alt="">"# }
        body += #"<span class="brand">ArrBarr</span></div>"# + statusPill(s) + "</header>"

        for error in s.errors {
            body += #"<div class="banner glass">"# + esc(error) + "</div>"
        }

        body += statTiles(s.stats)

        if !s.services.isEmpty {
            body += #"<section><h2>Servers</h2><div class="servers">"#
            body += s.services.map(serverChip).joined()
            body += "</div></section>"
        }

        // "Coming up" — the poster hero. A horizontal shelf (App-Store style): one
        // row that scrolls, so it never wraps and can never leave an orphan card.
        if !s.upcoming.isEmpty {
            body += #"<section><h2>Coming up"# + countChip(s.upcomingTotal) + "</h2>"
            body += #"<div class="shelf">"# + s.upcoming.map(upcomingCard).joined()
            let more = s.upcomingTotal - s.upcoming.count
            if more > 0 { body += moreCard(more) }
            body += "</div></section>"
        }

        // "Now downloading" — a compact, secondary strip. Not the main dish.
        body += #"<section><h2>Now downloading"#
        body += s.stats.total > 0 ? countChip(s.stats.downloading + s.stats.queued + s.stats.paused) : ""
        body += "</h2>"
        if s.downloads.isEmpty {
            body += #"<p class="idle">Nothing downloading — all caught up.</p>"#
        } else {
            body += #"<div class="strip">"# + s.downloads.map(downloadRow).joined() + "</div>"
            let extra = s.stats.total - s.downloads.count
            if extra > 0 { body += #"<p class="more-line">+ \#(extra) more in the queue</p>"# }
        }
        body += "</section>"

        let updated = s.generatedAt.timeIntervalSince1970 > 0
            ? "Updated " + timeFormatter.string(from: s.generatedAt)
            : "Waiting for first refresh…"
        return page(body: body, footer: updated, backdrop: backdropToken(s))
    }

    /// A poster to use, heavily blurred, as the cinematic page backdrop — the
    /// first artwork we have (upcoming first, then a download). Served through the
    /// same `/poster` proxy, so it's already membership-checked. nil → the page
    /// falls back to its mesh-gradient background.
    private static func backdropToken(_ s: StartPageSnapshot) -> String? {
        let url = s.upcoming.compactMap(\.posterURL).first
            ?? s.downloads.compactMap(\.posterURL).first
        return url.map { StartPagePosterToken.encode($0) }
    }

    // MARK: - JSON

    static func json(_ snapshot: StartPageSnapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }

    // MARK: - Pieces

    private static func statusPill(_ s: StartPageSnapshot) -> String {
        let down = s.services.filter { $0.health == .down }.count
        let (kind, text): (String, String)
        if s.offline {
            (kind, text) = ("warn", "Offline — showing last state")
        } else if down > 0 {
            (kind, text) = ("bad", "\(down) server\(down == 1 ? "" : "s") down")
        } else if !s.errors.isEmpty {
            (kind, text) = ("bad", "\(s.errors.count) issue\(s.errors.count == 1 ? "" : "s")")
        } else if s.stats.downloading > 0 {
            (kind, text) = ("go", "\(s.stats.downloading) downloading")
        } else {
            (kind, text) = ("ok", "All clear")
        }
        return #"<div class="pill glass \#(kind)"><span class="dot"></span>"# + esc(text) + "</div>"
    }

    private static func statTiles(_ st: StartPageSnapshot.Stats) -> String {
        func tile(_ value: String, _ label: String) -> String {
            #"<div class="tile glass"><div class="num">"# + esc(value)
                + #"</div><div class="lbl">"# + esc(label) + "</div></div>"
        }
        var tiles = ""
        tiles += tile("\(st.downloading)", "Downloading")
        tiles += tile("\(st.queued)", "Queued")
        tiles += tile("\(st.paused)", "Paused")
        tiles += tile(st.bytesLeft > 0 ? formatBytes(st.bytesLeft) : "—", "Left to fetch")
        return #"<div class="tiles">"# + tiles + "</div>"
    }

    private static func serverChip(_ svc: StartPageSnapshot.Service) -> String {
        // Brand icon (tinted by health via a CSS mask); plain dot if none ships.
        let mark: String
        if let name = svc.iconName, let uri = StartPageAssets.maskDataURI(name) {
            mark = #"<span class="ic \#(svc.health.rawValue)" style="-webkit-mask-image:url(\#(uri));mask-image:url(\#(uri))"></span>"#
        } else {
            mark = #"<span class="dot \#(svc.health.rawValue)"></span>"#
        }
        var inner = mark + #"<span class="sn">"# + esc(svc.name) + "</span>"
        if svc.warnings > 0 { inner += #"<span class="wct">"# + String(svc.warnings) + "</span>" }
        // Link to the service's own web UI when it has a (safe http/https) URL.
        if let raw = svc.url, let href = safeHref(raw) {
            inner += #"<span class="ext">↗</span>"#
            return #"<a class="srv glass" href="\#(href)" target="_blank" rel="noopener noreferrer">"# + inner + "</a>"
        }
        return #"<div class="srv glass">"# + inner + "</div>"
    }

    /// Escape a URL for an `href` attribute, allowing only http/https so a stored
    /// config value can never inject `javascript:` or markup.
    private static func safeHref(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return esc(raw)
    }

    private static func downloadRow(_ d: StartPageSnapshot.Download) -> String {
        let pct = Int((d.progress * 100).rounded())
        var meta = statusLabel(d.status)
        if d.status == .downloading || d.status == .queued {
            if d.bytesLeft > 0 { meta += " · " + formatBytes(d.bytesLeft) + " left" }
            if let time = d.timeLeft, !time.isEmpty { meta += " · " + time }
        }
        var html = #"<div class="item glass" data-pop>"#
        html += poster(d.posterURL, title: d.title, size: "thumb")
        html += #"<div class="item-body"><div class="item-top"><span class="t">"# + esc(d.title) + "</span>"
        html += #"<span class="badge">"# + esc(d.source.displayName) + "</span></div>"
        if let sub = d.subtitle, !sub.isEmpty {
            html += #"<div class="s">"# + esc(sub) + "</div>"
        }
        html += #"<div class="bar"><div class="fill \#(barClass(d.status))" style="width:"# + String(pct) + #"%"></div></div>"#
        html += #"<div class="m"><span>"# + esc(meta) + "</span><span>" + String(pct) + "%</span></div>"
        html += "</div>"
        html += popTemplate(downloadPopover(d))
        html += "</div>"
        return html
    }

    private static func upcomingCard(_ u: StartPageSnapshot.Upcoming) -> String {
        var html = #"<div class="card" data-pop>"#
        html += poster(u.posterURL, title: u.title, size: "card")
        html += #"<div class="when glass">"# + esc(airDateLabel(u.airDate)) + "</div>"
        html += #"<div class="card-body"><div class="ct">"# + esc(u.title) + "</div>"
        html += #"<div class="cs">"# + esc(subLine(u.source, u.subtitle)) + "</div></div>"
        html += popTemplate(upcomingPopover(u))
        html += "</div>"
        return html
    }

    // MARK: - Hover popover (content built here; positioned by the page script)

    /// Wrap popover inner HTML in an inert `<template>`. It isn't rendered or
    /// laid out (so the scrolling shelf can't clip it) until the script clones it
    /// into a floating panel on hover.
    private static func popTemplate(_ inner: String) -> String {
        #"<template class="pop">"# + inner + "</template>"
    }

    /// The rich "grab" card, mirroring the app's queue tooltip: an old→new quality
    /// comparison (score + size), a custom-format diff (added green / removed red),
    /// the release name, and the file being replaced.
    private static func downloadPopover(_ d: StartPageSnapshot.Download) -> String {
        // Badges: Upgrade/New + download client.
        var tags = #"<span class="tag \#(d.isUpgrade ? "up" : "new")">"#
            + (d.isUpgrade ? "Upgrade" : "New") + "</span>"
        if let client = d.downloadClient, !client.isEmpty {
            tags += #"<span class="tag">"# + esc(client) + "</span>"
        }

        // Quality comparison — two columns when replacing an existing file.
        let newCol = qualityCol(d.quality, d.customFormatScore, d.sizeTotal, isNew: true)
        let hasOld = d.isUpgrade && (d.existingQuality != nil || (d.existingSize ?? 0) > 0)
        let comparison: String
        if hasOld {
            let oldCol = qualityCol(d.existingQuality, d.existingCustomFormatScore ?? 0,
                                    d.existingSize ?? 0, isNew: false)
            comparison = #"<div class="cmp">"# + oldCol + #"<span class="cmp-arrow">→</span>"# + newCol + "</div>"
        } else {
            comparison = #"<div class="cmp">"# + newCol + "</div>"
        }

        // Custom-format diff: added not in the old file (green), removed (red).
        let added = d.customFormats.filter { !d.existingCustomFormats.contains($0) }
        let removed = d.existingCustomFormats.filter { !d.customFormats.contains($0) }
        var pills = added.map { #"<span class="cf add">+"# + esc($0) + "</span>" }.joined()
        pills += removed.map { #"<span class="cf rem">−"# + esc($0) + "</span>" }.joined()
        let pillRow = pills.isEmpty ? "" : #"<div class="cf-row">"# + pills + "</div>"

        var html = #"<div class="pop-head">"# + poster(d.posterURL, title: d.title, size: "pop")
        html += #"<div class="pop-h"><div class="pop-top"><span class="pop-title">"# + esc(d.title)
        html += #"</span><span class="tags">"# + tags + "</span></div>"
        if let sub = d.subtitle, !sub.isEmpty { html += #"<div class="pop-sub">"# + esc(sub) + "</div>" }
        html += comparison + pillRow + "</div></div>"

        // Footer (full width): release name, replaced file, indexer.
        var foot = ""
        if let rel = d.releaseName, !rel.isEmpty { foot += #"<div class="rel">"# + esc(rel) + "</div>" }
        if let old = d.existingFileName, !old.isEmpty {
            foot += #"<div class="rel old">↳ "# + esc(old) + "</div>"
        }
        if let idx = d.indexer, !idx.isEmpty { foot += #"<div class="idx">Indexer · "# + esc(idx) + "</div>" }
        if !foot.isEmpty { html += #"<div class="pop-foot">"# + foot + "</div>" }
        return html
    }

    /// One column of the quality comparison — quality name, signed score, size.
    private static func qualityCol(_ quality: String?, _ score: Int, _ size: Int64, isNew: Bool) -> String {
        var html = #"<div class="qcol\#(isNew ? " new" : "")"><div class="q">"# + esc(quality ?? "—") + "</div>"
        html += #"<div class="sc">"# + (score >= 0 ? "+" : "") + String(score) + "</div>"
        if size > 0 { html += #"<div class="sz">"# + formatBytes(size) + "</div>" }
        return html + "</div>"
    }

    private static func upcomingPopover(_ u: StartPageSnapshot.Upcoming) -> String {
        var rows = popCell("Airs", airDateLabel(u.airDate))
        if let r = u.imdb, r > 0 { rows += popCell("IMDb", "★ " + String(format: "%.1f", r)) }
        if let rt = u.runtime, rt > 0 { rows += popCell("Runtime", "\(rt) min") }
        return popCard(poster: u.posterURL, title: u.title,
                       sub: subLine(u.source, u.subtitle), rows: rows, overview: u.overview)
    }

    /// A wide "detail card": poster on the left with the metadata grid attached
    /// beside it, and the overview spanning the full width below.
    private static func popCard(poster posterURL: URL?, title: String, sub: String,
                                rows: String, overview: String?) -> String {
        var html = #"<div class="pop-head">"# + poster(posterURL, title: title, size: "pop")
        html += #"<div class="pop-h"><div class="pop-title">"# + esc(title) + "</div>"
        if !sub.isEmpty { html += #"<div class="pop-sub">"# + esc(sub) + "</div>" }
        html += #"<div class="pop-rows">"# + rows + "</div></div></div>"
        if let overview, !overview.isEmpty {
            html += #"<div class="pop-overview">"# + esc(overview) + "</div>"
        }
        return html
    }

    /// One label-over-value stat cell in the metadata grid.
    private static func popCell(_ label: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return #"<div class="pr"><span class="pl">"# + esc(label)
            + #"</span><span class="pv">"# + esc(value) + "</span></div>"
    }

    private static func subLine(_ source: QueueItem.Source, _ subtitle: String?) -> String {
        var s = source.displayName
        if let sub = subtitle, !sub.isEmpty { s += " · " + sub }
        return s
    }

    /// The "+N more" tile that closes the upcoming grid — poster-shaped so it
    /// fills the row instead of leaving a lone card hanging.
    private static func moreCard(_ n: Int) -> String {
        #"<div class="card"><div class="poster card more glass"><span class="more-n">+\#(n)<br>more</span></div></div>"#
    }

    /// A poster box: a gradient+initials placeholder that a proxied `<img>` covers
    /// once loaded. `onerror` removes a failed image so the placeholder shows
    /// through — no broken-image icon, no JS framework.
    private static func poster(_ url: URL?, title: String, size: String) -> String {
        var html = #"<div class="poster \#(size)"><span class="ph">"# + esc(initials(title)) + "</span>"
        if let url {
            let token = StartPagePosterToken.encode(url)
            html += #"<img loading="lazy" src="/poster?u=\#(token)" onerror="this.remove()">"#
        }
        return html + "</div>"
    }

    private static func countChip(_ n: Int) -> String {
        #"<span class="chip glass">"# + String(n) + "</span>"
    }

    private static func page(body: String, footer: String, backdrop: String?) -> String {
        let art = backdrop.map { #"<div class="art" style="background-image:url(/poster?u=\#($0))"></div>"# } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ArrBarr</title>
        <style>\(css)</style>
        </head>
        <body>
        <div class="bg"></div>
        \(art)
        <div class="tint"></div>
        <main>
        \(body)
        <footer>\(esc(footer))</footer>
        </main>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    /// Two tiny jobs, no dependencies: (1) an auto-reload timer that PAUSES while a
    /// popover is open, so the page doesn't refresh out from under a hover; (2) the
    /// hover popover itself — clone the item's inert `<template>` into a
    /// `position: fixed` panel appended to `<body>` (so the scrolling shelf's
    /// `overflow: hidden` can't clip it) and place it beside the item.
    private static let js = """
    (function(){
      var pop, hovering=false;
      function place(p, host){
        var r=host.getBoundingClientRect(), pr=p.getBoundingClientRect();
        var left=r.right+12, top=r.top-6;
        if(left+pr.width>window.innerWidth-8) left=r.left-pr.width-12;
        if(left<8) left=8;
        if(top+pr.height>window.innerHeight-8) top=window.innerHeight-pr.height-8;
        if(top<8) top=8;
        p.style.left=left+'px'; p.style.top=top+'px';
      }
      function show(host){
        var t=host.querySelector('template.pop'); if(!t) return;
        clear();
        pop=document.createElement('div'); pop.className='popover glass';
        pop.appendChild(t.content.cloneNode(true));
        document.body.appendChild(pop); place(pop, host);
      }
      function clear(){ if(pop){ pop.remove(); pop=null; } }
      var hosts=document.querySelectorAll('[data-pop]');
      for(var i=0;i<hosts.length;i++){
        hosts[i].addEventListener('mouseenter', (function(el){ return function(){ hovering=true; show(el); }; })(hosts[i]));
        hosts[i].addEventListener('mouseleave', function(){ hovering=false; clear(); });
      }
      (function tick(){ setTimeout(function(){ hovering ? tick() : location.reload(); }, \(refreshSeconds*1000)); })();
    })();
    """

    // MARK: - Formatting (English, display-layer)

    /// Per-status progress-bar colour class — mirrors the app's status tints
    /// (blue downloading, pink importing, orange paused, green done…).
    private static func barClass(_ s: QueueItem.Status) -> String {
        switch s {
        case .downloading: return "dl"
        case .importing:   return "imp"
        case .paused:      return "pause"
        case .queued:      return "queue"
        case .completed:   return "done"
        case .warning:     return "warn"
        case .failed:      return "fail"
        case .unknown:     return "unk"
        }
    }

    private static func statusLabel(_ status: QueueItem.Status) -> String {
        switch status {
        case .downloading: return "Downloading"
        case .paused:      return "Paused"
        case .queued:      return "Queued"
        case .importing:   return "Importing"
        case .completed:   return "Completed"
        case .warning:     return "Warning"
        case .failed:      return "Failed"
        case .unknown:     return "Unknown"
        }
    }

    private static func airDateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        var f = Date.FormatStyle.dateTime.day().month(.abbreviated)
        f.locale = Locale(identifier: "en_US_POSIX")
        return date.formatted(f)
    }

    /// English byte formatting (period decimals) regardless of OS locale —
    /// `ByteCountFormatter` has no locale knob, `ByteCountFormatStyle.locale` does.
    private static func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// Up to two leading letters for the poster placeholder.
    private static func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "—" || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Style (Liquid Glass)

    private static let css = """
    :root {
      color-scheme: light dark;
      --ink: #17181c; --sub: rgba(60,60,67,0.62);
      --glass: rgba(255,255,255,0.52);
      --glass-brd: rgba(255,255,255,0.7);
      --glass-hi: rgba(255,255,255,0.9);
      --shadow: 0 4px 14px rgba(30,30,60,0.10), 0 18px 40px rgba(30,30,60,0.10);
      --accent: #6366f1; --accent2: #22d3ee;
      --go: #30d158; --warn: #ff9f0a; --bad: #ff453a; --unknown: #9aa0aa;
      --base: #eef0f5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --ink: #f3f4f7; --sub: rgba(235,235,245,0.6);
        --glass: rgba(30,32,40,0.46);
        --glass-brd: rgba(255,255,255,0.14);
        --glass-hi: rgba(255,255,255,0.16);
        --shadow: 0 6px 16px rgba(0,0,0,0.4), 0 22px 48px rgba(0,0,0,0.4);
        --base: #0a0b0f;
      }
    }
    * { box-sizing: border-box; }
    html, body { min-height: 100%; }
    body {
      margin: 0; color: var(--ink); background: var(--base);
      font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    /* Cinematic backdrop, three fixed layers behind everything:
       .bg   — a mesh-gradient base (also the fallback when there's no artwork)
       .art  — the library's own poster, blurred to an atmospheric wash
       .tint — a veil for text legibility (glass panels refract all of it) */
    .bg, .art, .tint { position: fixed; z-index: -3; pointer-events: none; inset: -8%; }
    .bg {
      background:
        radial-gradient(48% 44% at 12% 6%, rgba(99,102,241,0.55), transparent 60%),
        radial-gradient(46% 40% at 92% 4%, rgba(34,211,238,0.45), transparent 60%),
        radial-gradient(50% 46% at 78% 96%, rgba(168,85,247,0.42), transparent 60%),
        radial-gradient(44% 44% at 20% 92%, rgba(244,114,182,0.34), transparent 60%);
      filter: blur(28px) saturate(130%);
    }
    .art {
      z-index: -2; background-size: cover; background-position: center; background-repeat: no-repeat;
      filter: blur(70px) saturate(1.4) brightness(1.02); opacity: 0.4;
    }
    .tint { z-index: -1; inset: 0;
      background: linear-gradient(180deg, rgba(240,241,246,0.55), rgba(240,241,246,0.8)); }
    @media (prefers-color-scheme: dark) {
      .art { filter: blur(70px) saturate(1.45) brightness(0.6); opacity: 0.85; }
      .tint { background: linear-gradient(180deg, rgba(10,11,15,0.4), rgba(10,11,15,0.74)); }
    }
    main { max-width: 880px; margin: 0 auto; padding: 32px 20px 60px; }
    /* Frosted glass shared by every floating panel */
    .glass {
      background: var(--glass);
      -webkit-backdrop-filter: blur(22px) saturate(185%);
      backdrop-filter: blur(22px) saturate(185%);
      border: 1px solid var(--glass-brd);
      box-shadow: var(--shadow), inset 0 1px 0 var(--glass-hi);
    }
    header { display: flex; align-items: center; justify-content: space-between; gap: 14px; margin-bottom: 24px; }
    .brandrow { display: flex; align-items: center; gap: 11px; }
    .logo-ic { width: 34px; height: 34px; border-radius: 9px; display: block; box-shadow: var(--shadow); }
    .brand { font-size: 23px; font-weight: 800; letter-spacing: -0.02em; color: var(--ink); }
    .pill { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600;
      padding: 7px 14px; border-radius: 999px; }
    .ic { width: 16px; height: 16px; flex: none; background-color: var(--ink);
      -webkit-mask-repeat: no-repeat; mask-repeat: no-repeat;
      -webkit-mask-position: center; mask-position: center;
      -webkit-mask-size: contain; mask-size: contain; }
    .ic.down { background-color: var(--bad); }
    .ic.unknown { background-color: var(--sub); }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--unknown); flex: none; }
    .dot.ok, .pill.ok .dot, .pill.go .dot { background: var(--go); }
    .dot.down, .pill.bad .dot { background: var(--bad); }
    .pill.go .dot { box-shadow: 0 0 0 4px color-mix(in srgb, var(--go) 26%, transparent); }
    .pill.warn .dot { background: var(--warn); box-shadow: 0 0 0 4px color-mix(in srgb, var(--warn) 26%, transparent); }
    .pill.bad .dot { box-shadow: 0 0 0 4px color-mix(in srgb, var(--bad) 26%, transparent); }
    .banner { padding: 12px 15px; border-radius: 14px; margin-bottom: 14px; font-size: 14px; }
    /* Tiles */
    .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 13px; margin-bottom: 28px; }
    .tile { border-radius: 20px; padding: 17px 18px 15px; }
    .tile .num { font-size: 27px; font-weight: 800; letter-spacing: -0.02em; }
    .tile .lbl { font-size: 12px; color: var(--sub); margin-top: 3px; }
    h2 { display: flex; align-items: center; gap: 9px; font-size: 12.5px; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.08em; color: var(--sub); margin: 0 0 14px; }
    .chip { font-size: 12px; font-weight: 700; color: var(--sub); border-radius: 999px; padding: 1px 10px; }
    section { margin-bottom: 30px; }
    .idle, .more-line { color: var(--sub); font-size: 13px; margin: 6px 2px 0; }
    /* Servers */
    .servers { display: flex; flex-wrap: wrap; gap: 9px; }
    .srv { display: inline-flex; align-items: center; gap: 8px; padding: 7px 13px; border-radius: 999px;
      font-size: 13px; font-weight: 600; }
    .srv .sn { letter-spacing: -0.01em; }
    .srv .wct { font-size: 11px; font-weight: 800; color: #fff; background: var(--warn);
      border-radius: 999px; padding: 0 6px; min-width: 17px; text-align: center; }
    a.srv { text-decoration: none; color: inherit; transition: transform .12s ease; }
    a.srv:hover { transform: translateY(-1px); }
    .srv .ext { font-size: 11px; color: var(--sub); margin-left: -2px; }
    /* Download strip — compact 2-up grid so it stays secondary to the posters */
    .strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 11px; }
    .item { display: flex; gap: 11px; border-radius: 16px; padding: 10px 12px; }
    .item-body { flex: 1; min-width: 0; align-self: center; }
    .item-top { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
    .item .t { font-weight: 650; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .item .s { font-size: 12.5px; color: var(--sub); margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar { height: 6px; border-radius: 4px; margin: 8px 0 6px; background: color-mix(in srgb, var(--ink) 12%, transparent); overflow: hidden; }
    .fill { height: 100%; border-radius: 4px; background: var(--accent);
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.32); }
    .fill.dl { background: #0a84ff; }
    .fill.imp { background: #ff375f; }
    .fill.pause { background: #ff9f0a; }
    .fill.queue { background: #7d8794; }
    .fill.done { background: #30d158; }
    .fill.warn { background: #ff9f0a; }
    .fill.fail { background: #ff453a; }
    .fill.unk { background: var(--sub); }
    .m { display: flex; justify-content: space-between; gap: 10px; font-size: 12px; color: var(--sub); }
    .badge { font-size: 11px; font-weight: 700; color: var(--sub); white-space: nowrap; }
    /* Upcoming shelf — one horizontally-scrolling row (never wraps → no orphan) */
    .shelf { display: flex; gap: 15px; overflow-x: auto; overflow-y: hidden;
      padding: 2px 2px 12px; scroll-snap-type: x proximity; -webkit-overflow-scrolling: touch; }
    .shelf > .card { flex: 0 0 auto; width: 88px; scroll-snap-align: start; }
    .shelf::-webkit-scrollbar { height: 8px; }
    .shelf::-webkit-scrollbar-thumb { background: color-mix(in srgb, var(--ink) 20%, transparent); border-radius: 4px; }
    .shelf::-webkit-scrollbar-track { background: transparent; }
    .card { position: relative; }
    .card-body { padding: 9px 2px 0; }
    .ct { font-size: 13px; font-weight: 650; line-height: 1.25; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .cs { font-size: 11.5px; color: var(--sub); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .when { position: absolute; top: 8px; left: 8px; font-size: 11px; font-weight: 700; color: #fff;
      background: rgba(0,0,0,0.42); padding: 3px 9px; border-radius: 999px; border: none;
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.25); }
    /* Poster box + placeholder */
    .poster { position: relative; aspect-ratio: 2/3; border-radius: 14px; overflow: hidden;
      box-shadow: var(--shadow);
      background: linear-gradient(155deg, color-mix(in srgb, var(--accent) 60%, #333), color-mix(in srgb, var(--accent2) 50%, #222)); }
    .poster.thumb { width: 42px; flex: none; border-radius: 9px; align-self: center; }
    .poster .ph { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
      font-weight: 800; color: rgba(255,255,255,0.92); font-size: 21px; letter-spacing: .02em; }
    .poster.thumb .ph { font-size: 13px; }
    .poster img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; display: block; }
    .poster.more { display: flex; align-items: center; justify-content: center; background: var(--glass); }
    .more-n { text-align: center; font-weight: 800; font-size: 17px; color: var(--ink); line-height: 1.15; }
    footer { margin-top: 36px; font-size: 12px; color: var(--sub); }
    /* Hover popover (a floating glass panel, positioned by the page script) */
    [data-pop] { cursor: default; }
    .popover { position: fixed; z-index: 60; width: 460px; max-width: calc(100vw - 16px);
      border-radius: 20px; padding: 17px; pointer-events: none; animation: pop .12s ease-out; }
    @keyframes pop { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
    .pop-head { display: flex; gap: 15px; margin-bottom: 13px; }
    .poster.pop { width: 124px; flex: none; border-radius: 12px; }
    .pop-h { flex: 1; min-width: 0; }
    .pop-title { font-weight: 700; font-size: 16px; line-height: 1.2; }
    .pop-sub { font-size: 12.5px; color: var(--sub); margin: 4px 0 12px; }
    .pop-rows { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 16px; }
    .pr { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    .pl { font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--sub); }
    .pv { font-size: 13px; font-weight: 600; overflow-wrap: anywhere; }
    .pop-overview { margin-top: 13px; padding-top: 13px; border-top: 1px solid var(--glass-brd);
      font-size: 12.5px; line-height: 1.5; color: var(--sub);
      display: -webkit-box; -webkit-line-clamp: 5; -webkit-box-orient: vertical; overflow: hidden; }
    /* Download grab card */
    .pop-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
    .tags { display: flex; gap: 6px; flex: none; padding-top: 2px; }
    .tag { font-size: 10px; font-weight: 800; padding: 2px 8px; border-radius: 7px; white-space: nowrap;
      background: color-mix(in srgb, var(--ink) 12%, transparent); color: var(--sub); }
    .tag.up { background: color-mix(in srgb, var(--accent) 26%, transparent); color: color-mix(in srgb, var(--accent) 76%, var(--ink)); }
    .tag.new { background: color-mix(in srgb, #3b82f6 26%, transparent); color: color-mix(in srgb, #3b82f6 76%, var(--ink)); }
    .cmp { display: flex; align-items: flex-start; gap: 16px; margin: 11px 0; }
    .qcol { display: flex; flex-direction: column; gap: 2px; }
    .qcol .q { font-weight: 700; font-size: 14px; }
    .qcol .sc { font-size: 12px; font-weight: 700; color: var(--sub); }
    .qcol.new .sc { color: var(--go); }
    .qcol .sz { font-size: 12px; color: var(--sub); }
    .cmp-arrow { color: var(--sub); font-size: 16px; align-self: center; }
    .cf-row { display: flex; flex-wrap: wrap; gap: 5px; }
    .cf { font-size: 10.5px; font-weight: 700; padding: 2px 7px; border-radius: 6px; white-space: nowrap; }
    .cf.add { background: color-mix(in srgb, var(--go) 20%, transparent); color: color-mix(in srgb, var(--go) 72%, var(--ink)); }
    .cf.rem { background: color-mix(in srgb, var(--bad) 18%, transparent); color: color-mix(in srgb, var(--bad) 78%, var(--ink)); }
    .pop-foot { margin-top: 13px; padding-top: 12px; border-top: 1px solid var(--glass-brd);
      display: flex; flex-direction: column; gap: 5px; }
    .rel { font: 11.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
    .rel.old { color: var(--sub); }
    .idx { font-size: 11.5px; color: var(--sub); margin-top: 3px; }
    @media (max-width: 560px) { .tiles { grid-template-columns: repeat(2, 1fr); } }
    """
}
