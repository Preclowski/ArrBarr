import SwiftUI
import Markdown

/// Ids the tools returned in this conversation, handed down to every message so
/// the Markdown renderer can tell a real link from an invented one.
private struct ChatKnownLinkKeysKey: EnvironmentKey {
    /// Empty means "nothing to verify against" — outside the chat (previews,
    /// isolated renders) links behave as written rather than all vanishing.
    static let defaultValue: Set<String>? = nil
}

public extension EnvironmentValues {
    var chatKnownLinkKeys: Set<String>? {
        get { self[ChatKnownLinkKeysKey.self] }
        set { self[ChatKnownLinkKeysKey.self] = newValue }
    }
}

// Renders assistant chat messages from Markdown using the official swift-markdown
// parser (cmark-gfm). Handles paragraphs, headings, bold/italic/strikethrough/
// inline-code, links, bullet/numbered lists, code blocks, block quotes and GFM
// tables. Inline emphasis is baked into per-run fonts so it renders correctly
// under the app's custom `.scaledFont` environment.
struct MarkdownMessage: View {
    let text: String
    var baseSize: CGFloat = 13
    @Environment(\.fontScale) private var scale
    /// Ids the tools returned in this conversation. A link to anything else is
    /// the model's invention and renders as plain text — see
    /// `ChatLinkVerification`.
    @Environment(\.chatKnownLinkKeys) private var knownLinkKeys

    private var px: CGFloat { baseSize * scale }

    /// Reveal state for `||spoiler||` spans — tapping the bubble toggles every
    /// spoiler in the message at once (matches the previous behaviour).
    @State private var spoilersRevealed = false

    private var source: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSpoilers: Bool { ChatSpoilerMarkup.containsSpoiler(source) }

    var body: some View {
        let doc = Document(parsing: source)
        Group {
            // A message that is ENTIRELY spoiler gets the blurred block, never
            // inline redaction. Inline redaction hides glyphs by colouring them
            // clear, which is fine for a phrase inside a sentence and reads as a
            // broken, empty bubble when it's the whole message — the block at
            // least says "Tap to reveal".
            if let hidden = fullyHiddenBody {
                spoilerBlockView(hidden)
            }
            // Prose-only messages render as ONE Text so a drag selects the whole
            // answer (see `flattened`). Everything else keeps the stacked path.
            else if !hasSpoilers, let flat = flattened(doc) {
                Text(flat)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(doc.blockChildren.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
        }
        // Tap to reveal/hide spoilers — only when the message has any, so normal
        // messages keep their default tap/selection behaviour.
        .modifier(SpoilerRevealTap(active: hasSpoilers) {
            withAnimation(.easeInOut(duration: 0.25)) { spoilersRevealed.toggle() }
        })
    }

    // MARK: - Whole-message selection

    /// SwiftUI selection never crosses a `Text` boundary: a message built as a
    /// stack of per-block views can only be selected one paragraph / one bullet
    /// at a time. So when a message is *only* prose — headings, paragraphs,
    /// simple lists — flatten it into a single AttributedString and let one drag
    /// take the lot. Returns nil for anything that genuinely needs its own view
    /// (code blocks, tables, block quotes, rules, nested lists), which keeps the
    /// stacked renderer for those instead of degrading them.
    ///
    /// The only thing lost is the bullets' hanging indent — a wrapped bullet
    /// wraps to the margin rather than under its own text — because a plain
    /// `Text` has no way to express one.
    private func flattened(_ doc: Document) -> AttributedString? {
        var out = AttributedString()
        for (idx, block) in doc.blockChildren.enumerated() {
            guard let piece = flattenBlock(block) else { return nil }
            if idx > 0 { out += gap(6) }
            out += piece
        }
        return out.characters.isEmpty ? nil : out
    }

    private func flattenBlock(_ markup: BlockMarkup) -> AttributedString? {
        switch markup {
        case let h as Heading:
            let bump: CGFloat = h.level == 1 ? 3 : (h.level == 2 ? 1.5 : 0)
            return inline(h, size: baseSize + bump, bold: true)
        case let p as Paragraph:
            return inline(p, size: baseSize)
        case let list as UnorderedList:
            return flattenList(Array(list.listItems), ordered: false)
        case let list as OrderedList:
            return flattenList(Array(list.listItems), ordered: true)
        default:
            return nil
        }
    }

    private func flattenList(_ items: [ListItem], ordered: Bool) -> AttributedString? {
        var out = AttributedString()
        for (idx, item) in items.enumerated() {
            let blocks = Array(item.blockChildren)
            // Nested lists / code inside a bullet need real views — bail out and
            // let the whole message use the stacked path.
            guard blocks.allSatisfy({ $0 is Paragraph }) else { return nil }
            if idx > 0 { out += AttributedString("\n") }
            var marker = styled(ordered ? "\(idx + 1).  " : "•  ", size: baseSize, bold: false, italic: false)
            marker.foregroundColor = .secondary
            out += marker
            for (i, block) in blocks.enumerated() {
                if i > 0 { out += AttributedString("\n") }
                out += inline(block, size: baseSize)
            }
        }
        return out
    }

    /// Vertical breathing room between blocks: an empty line whose own font size
    /// *is* the gap, which is the only spacing control a single `Text` has.
    private func gap(_ points: CGFloat) -> AttributedString {
        var a = AttributedString("\n\n")
        a.font = .system(size: points * scale)
        return a
    }

    // MARK: - Block rendering

    // Returns AnyView because the block renderer recurses (block quotes, list
    // items contain blocks) — a recursive `some View` defines its opaque type in
    // terms of itself and won't compile.
    private func blockView(_ markup: BlockMarkup) -> AnyView {
        switch markup {
        case let h as Heading:
            let bump: CGFloat = h.level == 1 ? 3 : (h.level == 2 ? 1.5 : 0)
            return AnyView(Text(inline(h, size: baseSize + bump, bold: true))
                .fixedSize(horizontal: false, vertical: true))
        case let p as Paragraph:
            // A paragraph that is ENTIRELY one spoiler renders as a blurred
            // block (real frosted blur, possible because it's its own view).
            // Inline spoilers mid-paragraph fall back to the redaction bar.
            if let body = blockSpoilerBody(p) {
                return AnyView(spoilerBlockView(body))
            }
            return AnyView(Text(inline(p, size: baseSize))
                .fixedSize(horizontal: false, vertical: true))
        case let list as UnorderedList:
            return AnyView(listView(Array(list.listItems), ordered: false))
        case let list as OrderedList:
            return AnyView(listView(Array(list.listItems), ordered: true))
        case let code as CodeBlock:
            return AnyView(Text(verbatim: code.code.trimmingCharacters(in: .newlines))
                .font(.system(size: px - 1, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)))
        case let quote as BlockQuote:
            return AnyView(HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(quote.blockChildren.enumerated()), id: \.offset) { _, b in
                        blockView(b)
                    }
                }
            })
        case let table as Markdown.Table:
            return AnyView(tableView(table))
        case is ThematicBreak:
            return AnyView(Divider())
        default:
            return AnyView(Text(verbatim: markup.format()).scaledFont(size: baseSize))
        }
    }

    @ViewBuilder
    private func listView(_ items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: ordered ? "\(idx + 1)." : "•")
                        .scaledFont(size: baseSize)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, b in
                            blockView(b)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tableView(_ table: Markdown.Table) -> some View {
        let head = Array(table.head.cells)
        let rows = Array(table.body.rows)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(head.enumerated()), id: \.offset) { _, cell in
                    Text(inline(cell, size: baseSize, bold: true))
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell, size: baseSize))
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Block spoiler

    /// The message's text when *all* of it is spoiler — nothing outside the
    /// markers but whitespace. Returns nil for a message with any visible prose
    /// (that one redacts inline, in place) and for one with no spoilers at all.
    private var fullyHiddenBody: String? {
        let segments = ChatSpoilerMarkup.parse(source)
        var hidden: [String] = []
        for segment in segments {
            switch segment {
            case .spoiler(let body):
                hidden.append(body)
            case .text(let plain):
                // Any real prose outside the markers and this isn't a
                // whole-message spoiler.
                guard plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            }
        }
        return hidden.isEmpty ? nil : hidden.joined(separator: "\n\n")
    }

    /// If a paragraph is exactly one `||spoiler||` (no other prose), returns the
    /// inner text — it renders as a blurred, tap-to-reveal block.
    private func blockSpoilerBody(_ p: Paragraph) -> String? {
        let plain = p.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.hasPrefix("||"), plain.hasSuffix("||") else { return nil }
        let segments = ChatSpoilerMarkup.parse(plain)
        guard segments.count == 1, case .spoiler(let body) = segments[0] else { return nil }
        return body
    }

    @ViewBuilder
    private func spoilerBlockView(_ body: String) -> some View {
        Text(body)
            .scaledFont(size: baseSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .blur(radius: spoilersRevealed ? 0 : 6)
            .overlay {
                if !spoilersRevealed {
                    Label {
                        Text("chat.tapToRevealSpoiler.button", bundle: .module)
                    } icon: {
                        Image(systemName: "eye.slash.fill")
                    }
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .animation(.easeInOut(duration: 0.25), value: spoilersRevealed)
            .contentShape(Rectangle())
    }

    // MARK: - Inline rendering (explicit per-run fonts)

    private func inline(_ markup: Markup, size: CGFloat, bold: Bool = false, italic: Bool = false) -> AttributedString {
        var result = AttributedString()
        for child in markup.children {
            result += renderInline(child, size: size, bold: bold, italic: italic)
        }
        return result
    }

    private func renderInline(_ markup: Markup, size: CGFloat, bold: Bool, italic: Bool) -> AttributedString {
        switch markup {
        case let t as Markdown.Text:
            return styledText(t.string, size: size, bold: bold, italic: italic)
        case let code as InlineCode:
            var a = AttributedString(code.code)
            a.font = .system(size: size * scale, design: .monospaced)
            return a
        case let strong as Strong:
            return concat(strong, size: size, bold: true, italic: italic)
        case let em as Emphasis:
            return concat(em, size: size, bold: bold, italic: true)
        case let strike as Strikethrough:
            var inner = concat(strike, size: size, bold: bold, italic: italic)
            inner.strikethroughStyle = .single
            return inner
        case let link as Markdown.Link:
            var inner = concat(link, size: size, bold: bold, italic: italic)
            // ONLY in-app links survive. A model asked for a markdown link will
            // happily invent a plausible URL from memory — that is how a chat
            // about your Radarr library produced a link to a rickroll — and we
            // have no way to tell an invented URL from a real one. An external
            // destination is therefore dropped and the text stays text: the app
            // never hands the user off to a web page it can't vouch for.
            if let dest = link.destination, let url = URL(string: dest),
               url.scheme == ChatLink.scheme, linkIsTrustworthy(url) {
                // `arrbarr://person/19292` carries no name, but the link's own
                // text is the name — stamp it in so `PersonView` can title
                // itself the moment it's pushed, instead of sitting blank until
                // TMDB answers. The tap handler only ever sees the URL, which is
                // why this has to happen at render time.
                inner.link = Self.namingPersonLinks(url, label: link.plainText)
                inner.foregroundColor = .accentColor
            }
            return inner
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        default:
            return concat(markup, size: size, bold: bold, italic: italic)
        }
    }

    /// Whether this in-app link points at an id some tool in this conversation
    /// actually returned. The model invents ids when it has none — a "gaps in
    /// your collection" answer names films that `check_titles` never printed an
    /// id for — and an invented id opens a real, wrong film. Unverified links
    /// render as ordinary text.
    private func linkIsTrustworthy(_ url: URL) -> Bool {
        guard let knownLinkKeys else { return true }
        guard let link = ChatLink(url: url) else { return false }
        return ChatLinkVerification.isVerified(link, against: knownLinkKeys)
    }

    /// Adds `?name=<link text>` to a person link that doesn't already carry one.
    /// Everything else — media links, http links, malformed URLs — passes
    /// through untouched.
    static func namingPersonLinks(_ url: URL, label: String) -> URL {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              case .person(let id, let existing)? = ChatLink(url: url), existing.isEmpty,
              let named = ChatLink.person(id: id, name: trimmed).url else { return url }
        return named
    }

    private func concat(_ markup: Markup, size: CGFloat, bold: Bool, italic: Bool) -> AttributedString {
        var result = AttributedString()
        for child in markup.children {
            result += renderInline(child, size: size, bold: bold, italic: italic)
        }
        return result
    }

    private func styled(_ s: String, size: CGFloat, bold: Bool, italic: Bool) -> AttributedString {
        var a = AttributedString(s)
        var font = Font.system(size: size * scale)
        if bold { font = font.bold() }
        if italic { font = font.italic() }
        a.font = font
        return a
    }

    /// Like `styled`, but splits out `||spoiler||` spans and redacts them (text
    /// hidden behind a solid bar) until the bubble is tapped to reveal. Keeps the
    /// surrounding Markdown intact — spoilers no longer bypass the renderer.
    private func styledText(_ s: String, size: CGFloat, bold: Bool, italic: Bool) -> AttributedString {
        guard s.contains("||") else { return styled(s, size: size, bold: bold, italic: italic) }
        var result = AttributedString()
        for segment in ChatSpoilerMarkup.parse(s) {
            switch segment {
            case .text(let txt):
                result += styled(txt, size: size, bold: bold, italic: italic)
            case .spoiler(let txt):
                // Keep the REAL text (same glyph positions) so revealing doesn't
                // reflow / jump the layout — just toggle its colour. Hidden: a
                // subtle highlight bar with invisible text; selection is disabled
                // on spoiler messages (see SpoilerRevealTap) so it can't be peeked.
                var a = styled(txt, size: size, bold: bold, italic: italic)
                if !spoilersRevealed {
                    a.foregroundColor = .clear
                    a.backgroundColor = .secondary.opacity(0.30)
                }
                result += a
            }
        }
        return result
    }
}

/// Applies a reveal tap only when the message carries spoilers, so ordinary
/// messages keep their default tap/selection behaviour.
private struct SpoilerRevealTap: ViewModifier {
    let active: Bool
    let toggle: () -> Void
    func body(content: Content) -> some View {
        if active {
            // Disable selection on spoiler messages so the tap reveals (and so a
            // drag-select can't peek at hidden glyphs); normal messages stay
            // selectable.
            content
                .textSelection(.disabled)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
        } else {
            content
                .textSelection(.enabled)
        }
    }
}
