import SwiftUI

// Block-aware markdown renderer for chat bubbles.
//
// SwiftUI's `Text(AttributedString(markdown:))` only resolves *inline* markdown
// (bold/italic/code/links) and even then leans on `inlinePresentationIntent`
// composing with the surrounding `.font()` — which, with the app's custom
// `.scaledFont(...)`, did not reliably render bold. Block markdown (lists,
// headings, code fences) was dropped entirely.
//
// This view fixes both: it splits the message into blocks and renders each,
// and for inline spans it resolves `inlinePresentationIntent` into an EXPLICIT
// per-run `.font` (bold/italic/mono), so emphasis renders regardless of the
// outer font modifier.

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(label: String, text: String)
    case paragraph(text: String)
    case code(text: String)
}

enum MarkdownParser {
    static func blocks(_ raw: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var code: [String] = []
        var inCode = false

        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(text: para.joined(separator: "\n"))); para = [] }
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(text: code.joined(separator: "\n"))); code = []; inCode = false
                } else {
                    flushPara(); inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }

            if trimmed.isEmpty { flushPara(); continue }

            // Heading: leading #'s followed by a space.
            if let hashes = headingLevel(trimmed) {
                flushPara()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                out.append(.heading(level: hashes, text: text))
                continue
            }
            // Bullet: -, *, or • followed by a space.
            if let marker = trimmed.first, "-*•".contains(marker),
               trimmed.dropFirst().first == " " {
                flushPara()
                out.append(.bullet(text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // Numbered: digits + '.' or ')' + space.
            if let n = numberedPrefix(trimmed) {
                flushPara()
                out.append(.numbered(label: n.label, text: n.rest))
                continue
            }
            para.append(trimmed)
        }
        flushPara()
        if inCode, !code.isEmpty { out.append(.code(text: code.joined(separator: "\n"))) }
        return out
    }

    private static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for ch in s { if ch == "#" { n += 1 } else { break } }
        guard n >= 1, n <= 6 else { return nil }
        // Require a space after the #'s so "#1 pick" isn't a heading.
        let after = s.index(s.startIndex, offsetBy: n)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return n
    }

    private static func numberedPrefix(_ s: String) -> (label: String, rest: String)? {
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { digits.append(s[idx]); idx = s.index(after: idx) }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let sep = s[idx]
        let afterSep = s.index(after: idx)
        guard afterSep < s.endIndex, s[afterSep] == " " else { return nil }
        let rest = String(s[s.index(after: afterSep)...]).trimmingCharacters(in: .whitespaces)
        return ("\(digits)\(sep)", rest)
    }
}

struct MarkdownMessage: View {
    let text: String
    var baseSize: CGFloat = 13
    @Environment(\.fontScale) private var scale

    private var blocks: [MarkdownBlock] { MarkdownParser.blocks(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // h1/h2 a touch larger; deeper headings just bold at body size.
            let bump: CGFloat = level == 1 ? 3 : (level == 2 ? 1.5 : 0)
            Text(inline(text, size: baseSize + bump, bold: true))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(inline(text, size: baseSize)).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let label, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: label).foregroundStyle(.secondary)
                Text(inline(text, size: baseSize)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(inline(text, size: baseSize)).fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(verbatim: text)
                .font(.system(size: baseSize * scale - 1, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Inline markdown → AttributedString with EXPLICIT per-run fonts so emphasis
    /// renders independently of the enclosing `.font()` modifier.
    private func inline(_ s: String, size: CGFloat, bold: Bool = false) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attr = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        let px = size * scale
        for run in attr.runs {
            let ip = run.inlinePresentationIntent
            var font = Font.system(size: px, design: (ip?.contains(.code) == true) ? .monospaced : .default)
            if bold || ip?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if ip?.contains(.emphasized) == true { font = font.italic() }
            attr[run.range].font = font
        }
        return attr
    }
}
