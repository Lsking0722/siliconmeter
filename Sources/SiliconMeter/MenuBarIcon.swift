//
//  MenuBarIcon.swift
//  A plain chip in the menu bar with its name engraved (cut out of the body).
//  Base chips are a square with the chip number; Pro, Max and Ultra are one upright
//  rectangle with the number on top and P, M or U below.
//  Template image, so macOS tints it for light and dark menu bars.
//
import AppKit
import CoreText

enum MenuBarIcon {
    static func make(for chip: ChipInfo) -> NSImage {
        let layout = MenuBarIcon.layout(for: chip)
        let image = NSImage(size: layout.canvas, flipped: false) { _ in
            MenuBarIcon.draw(layout)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = chip.brand
        return image
    }

    private struct Body {
        var rect: CGRect
        var lines: [(String, CGFloat, NSFont.Weight)]   // text, max point size, weight (top → bottom)
    }

    private struct Layout {
        var canvas: CGSize
        var bodies: [Body]
    }

    private static func layout(for chip: ChipInfo) -> Layout {
        let name = chip.family
        // Pro / Max / Ultra are marked by their first letter only, under the chip number.
        let tag = chip.tag.map { String($0.prefix(1)) } ?? ""
        switch chip.archetype {
        case .mono:
            // A18 Pro: square like the other one-die chips, "A18" over "P".
            let lines: [(String, CGFloat, NSFont.Weight)] = chip.series == .a && !tag.isEmpty
                ? [(name, 8, .bold), (tag, 7, .heavy)] : [(name, 9.5, .bold)]
            return Layout(canvas: CGSize(width: 18, height: 18),
                          bodies: [Body(rect: CGRect(x: 1, y: 1, width: 16, height: 16), lines: lines)])
        case .proMax, .fusion, .ultra, .fusionUltra:
            // One rectangle for every variant: the chip number on top, P / M / U below. One
            // width for all, so "M5" over "M" is not squeezed on 1× screens. The canvas is a
            // whole number of points: a 15.5 pt image is resampled to 15 px on a 1× screen,
            // which smeared every letter.
            let w: CGFloat = 13
            return Layout(canvas: CGSize(width: w + 2, height: 18),
                          bodies: [Body(rect: CGRect(x: 1, y: 1, width: w, height: 16),
                                        lines: [(name, 8, .bold), (tag, 7, .heavy)])])
        }
    }

    /// Draws at whatever scale the image is being rendered (the drawing handler runs once
    /// per screen scale). Lines are stacked by cap height, not line height, so the letters
    /// can be larger in the same body; on 1× screens they are a size larger and a weight
    /// heavier, and snapped to whole pixels, so the cut-out letters stay readable.
    private static func draw(_ layout: Layout) {
        guard let gc = NSGraphicsContext.current else { return }
        let cg = gc.cgContext
        let pixels = max(1, cg.userSpaceToDeviceSpaceTransform.a)
        let lowRes = pixels < 1.5
        func snap(_ v: CGFloat) -> CGFloat { lowRes ? (v * pixels).rounded() / pixels : v }

        NSColor.black.setFill()
        for body in layout.bodies {
            NSBezierPath(roundedRect: body.rect, xRadius: 2.4, yRadius: 2.4).fill()
        }

        // Engrave: everything below is cut out of the bodies.
        gc.compositingOperation = .destinationOut
        cg.setBlendMode(.destinationOut)

        cg.textMatrix = .identity
        for body in layout.bodies {
            let lines = body.lines.filter { !$0.0.isEmpty }
            let built = lines.map { line -> (line: CTLine, width: CGFloat, cap: CGFloat) in
                let maxWidth = body.rect.width - 2.5
                var size = line.1 * (lowRes ? 1.12 : 1)
                let weight = lowRes ? heavier(line.2) : line.2
                while true {
                    let font = NSFont.systemFont(ofSize: size, weight: weight)
                    let ct = CTLineCreateWithAttributedString(text(line.0, font: font))
                    let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
                    if width <= maxWidth || size <= 3.5 { return (ct, width, font.capHeight) }
                    size -= 0.25
                }
            }
            // On 1× screens the letters are only five to seven pixels tall, where any font
            // turns to mush; they come from pixel fonts instead, every stroke a whole pixel.
            // One line ("M4"): the large bold font; two lines ("M5" over "U"): small over bold.
            var pixel: [[[String]]]? = nil
            if lowRes {
                let tables = built.count == 2 ? [PixelFont.small, PixelFont.bold] : [PixelFont.large]
                let found = zip(lines, tables).compactMap { PixelFont.glyphs($0.0.0, in: $0.1) }
                if found.count == built.count && built.count <= 2 { pixel = found }
            }
            let caps = built.enumerated().map { i, item in pixel.map { CGFloat($0[i][0].count) } ?? item.cap }
            let gap: CGFloat = lowRes ? 2 : 1.7
            let total = caps.reduce(0, +) + gap * CGFloat(max(0, built.count - 1))
            var top = body.rect.midY + total / 2
            for (i, item) in built.enumerated() {
                let baseline = snap(top - caps[i])
                if let glyphs = pixel?[i] {
                    let unit = 1 / pixels
                    let rows = glyphs[0].count
                    var x = snap(body.rect.midX - CGFloat(PixelFont.width(glyphs)) * unit / 2)
                    for glyph in glyphs {
                        for (row, bits) in glyph.enumerated() {
                            for (col, bit) in bits.enumerated() where bit == "#" {
                                cg.fill(CGRect(x: x + CGFloat(col) * unit,
                                               y: baseline + CGFloat(rows - 1 - row) * unit,
                                               width: unit, height: unit))
                            }
                        }
                        x += CGFloat(glyph[0].count + 1) * unit
                    }
                } else {
                    cg.textPosition = CGPoint(x: snap(body.rect.midX - item.width / 2), y: baseline)
                    CTLineDraw(item.line, cg)
                }
                top = baseline - gap
            }
        }
        gc.compositingOperation = .sourceOver
        cg.setBlendMode(.normal)
    }

    private static func heavier(_ w: NSFont.Weight) -> NSFont.Weight {
        switch w {
        case .regular, .medium: return .semibold
        case .semibold: return .bold
        case .bold: return .heavy
        default: return .black
        }
    }

    private static func text(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: font.pointSize < 5.5 ? 0.3 : 0,
        ])
    }
}

/// Pixel fonts for 1× screens: a 7-row bold font for one-line icons, and for two-line icons
/// a 5-row font for the chip number over a 6-row bold one (two-pixel stems) for P / M / U.
private enum PixelFont {
    typealias Table = [Character: [String]]
    static let small: Table = [
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
        "A": [".##.", "#..#", "####", "#..#", "#..#"],
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", "###", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", "..#", "..#", "..#"],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
    ]
    static let large: Table = [
        "M": ["##...##", "###.###", "#######", "##.#.##", "##...##", "##...##", "##...##"],
        "1": [".##", "###", ".##", ".##", ".##", ".##", ".##"],
        "2": ["####.", "...##", "...##", ".###.", "##...", "##...", "#####"],
        "3": ["####.", "...##", "...##", ".###.", "...##", "...##", "####."],
        "4": ["##.##", "##.##", "##.##", "#####", "...##", "...##", "...##"],
        "5": ["#####", "##...", "####.", "...##", "...##", "...##", "####."],
        "6": [".###.", "##...", "####.", "##.##", "##.##", "##.##", ".###."],
        "7": ["#####", "...##", "...##", "..##.", "..##.", ".##..", ".##.."],
        "8": [".###.", "##.##", "##.##", ".###.", "##.##", "##.##", ".###."],
        "9": [".###.", "##.##", "##.##", ".####", "...##", "...##", ".###."],
    ]
    static let bold: Table = [
        "P": ["####.", "##.##", "##.##", "####.", "##...", "##..."],
        "M": ["##...##", "###.###", "##.#.##", "##...##", "##...##", "##...##"],
        "U": ["##.##", "##.##", "##.##", "##.##", "#####", ".###."],
    ]

    /// Glyphs for `text`, or nil when a character has none (the system font is used instead).
    static func glyphs(_ text: String, in table: Table) -> [[String]]? {
        var out: [[String]] = []
        for ch in text.uppercased() {
            guard let g = table[ch] else { return nil }
            out.append(g)
        }
        return out.isEmpty ? nil : out
    }

    /// Width in pixels, one blank column between glyphs.
    static func width(_ glyphs: [[String]]) -> Int {
        glyphs.reduce(0) { $0 + $1[0].count } + max(0, glyphs.count - 1)
    }
}
