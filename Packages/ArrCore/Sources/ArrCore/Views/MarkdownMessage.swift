import SwiftUI
import Markdown

// Renders assistant chat messages from Markdown using the official swift-markdown
// parser (cmark-gfm). Handles paragraphs, headings, bold/italic/strikethrough/
// inline-code, links, bullet/numbered lists, code blocks, block quotes and GFM
// tables. Inline emphasis is baked into per-run fonts so it renders correctly
// under the app's custom `.scaledFont` environment.
struct MarkdownMessage: View {
    let text: String
    var baseSize: CGFloat = 13
    @Environment(\.fontScale) private var scale

    private var px: CGFloat { baseSize * scale }

    /// Reveal state for `||spoiler||` spans — tapping the bubble toggles every
    /// spoiler in the message at once (matches the previous behaviour).
    @State private var spoilersRevealed = false

    private var source: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSpoilers: Bool { ChatSpoilerMarkup.containsSpoiler(source) }

    var body: some View {
        let doc = Document(parsing: source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(doc.blockChildren.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        // Tap to reveal/hide spoilers — only when the message has any, so normal
        // messages keep their default tap/selection behaviour.
        .modifier(SpoilerRevealTap(active: hasSpoilers) {
            withAnimation(.easeInOut(duration: 0.25)) { spoilersRevealed.toggle() }
        })
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
            if let dest = link.destination, let url = URL(string: dest) {
                inner.link = url
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
