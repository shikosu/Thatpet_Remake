import AppKit

/// Rendu Markdown minimal pour NSTextView / NSTextField : gras, italique, code, liens,
/// titres, listes à puces et blocs de code. Le reste s'affiche tel quel.
enum Markdown {
    static func render(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inFence = false
        var lines: [NSAttributedString] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                lines.append(NSAttributedString(string: raw, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: NSColor.quaternaryLabelColor,
                ]))
            } else if let (level, title) = heading(raw) {
                let extra: CGFloat = level == 1 ? 4 : level == 2 ? 2 : 1
                lines.append(NSAttributedString(string: title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: size + extra), .foregroundColor: color]))
            } else {
                lines.append(inline(bullet(raw), size: size, color: color))
            }
        }
        for (i, line) in lines.enumerated() {
            out.append(line)
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    /// « ## Titre » → (2, « Titre »).
    static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, String(line.dropFirst(hashes.count + 1)))
    }

    /// « - item », « * item » ou « + item » → « • item » (indentation conservée).
    static func bullet(_ line: String) -> String {
        let trimmed = line.drop { $0 == " " }
        guard let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " else { return line }
        return String(repeating: " ", count: line.count - trimmed.count) + "• " + trimmed.dropFirst(2)
    }

    /// Markdown en ligne (gras, italique, code, liens, barré), en conservant les espaces et retours.
    static func inline(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                } else {
                    if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            attributes[.font] = font
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    /// Description lisible des styles d'un texte rendu (pour les tests : `TPRemake md-debug "…"`).
    static func describe(_ attributed: NSAttributedString) -> [String] {
        var result: [String] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var traits: [String] = []
            if let font = attributes[.font] as? NSFont {
                if font.fontDescriptor.symbolicTraits.contains(.bold) { traits.append("gras") }
                if font.fontDescriptor.symbolicTraits.contains(.italic) { traits.append("italique") }
                if font.isFixedPitch { traits.append("code") }
                traits.append("\(Int(font.pointSize))pt")
            }
            if attributes[.link] != nil { traits.append("lien") }
            if attributes[.strikethroughStyle] != nil { traits.append("barré") }
            if attributes[.backgroundColor] != nil { traits.append("fond") }
            result.append("[\((attributed.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: "⏎"))] \(traits.joined(separator: ","))")
        }
        return result
    }
}
