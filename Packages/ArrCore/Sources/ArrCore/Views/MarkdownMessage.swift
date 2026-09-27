import SwiftUI
import Markdown

/// Ids the tools returned in this conversation; links to anything else render as plain text.
private struct ChatKnownLinkKeysKey: EnvironmentKey {
    /// nil (outside the chat) means nothing to verify against, so links behave as written.
    static let defaultValue: Set<String>? = nil
}

public extension EnvironmentValues {
    var chatKnownLinkKeys: Set<String>? {
        get { self[ChatKnownLinkKeysKey.self] }
        set { self[ChatKnownLinkKeysKey.self] = newValue }
    }
}

// Assistant messages via swift-markdown (cmark-gfm). Emphasis is baked into per-run fonts
// so it survives the custom `.scaledFont` environment.
struct MarkdownMessage: View {
    let text: String
    var baseSize: CGFloat = 13
    @Environment(\.fontScale) private var scale
    @Environment(\.chatKnownLinkKeys) private var knownLinkKeys

    private var px: CGFloat { baseSize * scale }

    /// One tap toggles every spoiler in the message.
    @State private var spoilersRevealed = false

    private var source: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSpoilers: Bool { ChatSpoilerMarkup.containsSpoiler(source) }

    var body: some View {
        let doc = Markdown.Document(parsing: source)
        Group {
            // A whole-message spoiler gets the blurred block: inline redaction of the entire text reads as an empty bubble.
            if let hidden = fullyHiddenBody {
                spoilerBlockView(hidden)
            }
            // One Text so a drag selects the whole answer (see `flattened`).
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
        .modifier(SpoilerRevealTap(active: hasSpoilers) {
            withAnimation(.easeInOut(duration: 0.25)) { spoilersRevealed.toggle() }
        })
    }

    // MARK: - Whole-message selection

    /// SwiftUI selection never crosses a `Text` boundary, so prose-only messages flatten into one
    /// AttributedString (losing only the bullets' hanging indent). nil for blocks that need their own view.
    private func flattened(_ doc: Markdown.Document) -> AttributedString? {
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

    /// An empty line whose font size is the gap: the only spacing control a single `Text` has.
    private func gap(_ points: CGFloat) -> AttributedString {
        var a = AttributedString("\n\n")
        a.font = .system(size: points * scale)
        return a
    }

    // MARK: - Block rendering

    // AnyView because the renderer recurses; a recursive `some View` won't compile.
    private func blockView(_ markup: BlockMarkup) -> AnyView {
        switch markup {
        case let h as Heading:
            let bump: CGFloat = h.level == 1 ? 3 : (h.level == 2 ? 1.5 : 0)
            return AnyView(Text(inline(h, size: baseSize + bump, bold: true))
                .fixedSize(horizontal: false, vertical: true))
        case let p as Paragraph:
            // Its own view, so a real blur; inline spoilers fall back to the redaction bar.
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

    private var fullyHiddenBody: String? {
        let segments = ChatSpoilerMarkup.parse(source)
        var hidden: [String] = []
        for segment in segments {
            switch segment {
            case .spoiler(let body):
                hidden.append(body)
            case .text(let plain):
                guard plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            }
        }
        return hidden.isEmpty ? nil : hidden.joined(separator: "\n\n")
    }

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
                    .glassEffect(.regular, in: .capsule)
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
            // Only in-app links survive: models invent plausible external URLs from memory,
            // and the app can't vouch for them.
            if let dest = link.destination, let url = URL(string: dest),
               url.scheme == ChatLink.scheme, linkIsTrustworthy(url) {
                // The tap handler sees only the URL, so the name is stamped in at render time
                // and `PersonView` can title itself before TMDB answers.
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

    /// Models invent ids when they have none, and an invented id opens a real, wrong title.
    private func linkIsTrustworthy(_ url: URL) -> Bool {
        guard let knownLinkKeys else { return true }
        guard let link = ChatLink(url: url) else { return false }
        return ChatLinkVerification.isVerified(link, against: knownLinkKeys)
    }

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

    /// Redacts `||spoiler||` spans until the bubble is tapped, keeping the surrounding Markdown.
    private func styledText(_ s: String, size: CGFloat, bold: Bool, italic: Bool) -> AttributedString {
        guard s.contains("||") else { return styled(s, size: size, bold: bold, italic: italic) }
        var result = AttributedString()
        for segment in ChatSpoilerMarkup.parse(s) {
            switch segment {
            case .text(let txt):
                result += styled(txt, size: size, bold: bold, italic: italic)
            case .spoiler(let txt):
                // Keeps the real glyphs and only toggles colour so revealing doesn't reflow.
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

private struct SpoilerRevealTap: ViewModifier {
    let active: Bool
    let toggle: () -> Void
    func body(content: Content) -> some View {
        if active {
            // No selection on spoiler messages, so a drag-select can't peek at hidden glyphs.
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
