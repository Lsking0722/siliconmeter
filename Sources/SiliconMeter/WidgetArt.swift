//
//  WidgetArt.swift
//  What the desktop widget draws, shared by the widget extension and the app (whose
//  `--simulate` renders every chip's widgets for review). Plain SwiftUI, no WidgetKit.
//
import SwiftUI

enum WidgetArt {
    enum Family: String, CaseIterable {
        case small, medium, large

        /// Desktop widget sizes on macOS (points), for offscreen renders.
        var size: CGSize {
            switch self {
            case .small: return CGSize(width: 170, height: 170)
            case .medium: return CGSize(width: 364, height: 170)
            case .large: return CGSize(width: 364, height: 382)
            }
        }
    }

    /// Sizes offered for a chip. An Ultra is two dies stacked (about 1 : 2.5), far too tall
    /// for the square small widget, so it gets only the medium and large ones.
    static func families(for chip: ChipInfo) -> [Family] {
        chip.variant == .ultra ? [.medium, .large] : Family.allCases
    }

    /// The dies (and the bridges between them) alone, cropped to their own bounds: no memory
    /// packages or lanes, so the chip fills the widget.
    static func dieOnly(_ d: ChipDrawing) -> ChipDrawing {
        var bounds = d.dies.reduce(CGRect.null) { $0.union($1) }
        for bridge in d.bridges { bounds = bounds.union(bridge.rect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return d }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        var out = d
        out.size = bounds.size
        out.dies = d.dies.map(move)
        out.blocks = d.blocks.map { DieBlock(rect: move($0.rect), kind: $0.kind) }
        out.bridges = d.bridges.map { Bridge(rect: move($0.rect), kind: $0.kind) }
        out.packages = []
        out.traces = []
        return out
    }
}

/// The die at rest: the same renderer as the app, every load at zero, no motion.
///
/// `tinted`: when the desktop isn't in front, macOS shows widgets tinted ("vibrant"/
/// "accented"): it keeps only each pixel's opacity and paints it white, so the die (opaque
/// everywhere) turned into a white slab. Then the die's brightness becomes its opacity
/// instead: the lit silicon stays, the dark cut-outs drop away, and it reads as line art.
struct WidgetDie: View {
    let chip: ChipInfo
    let drawing: ChipDrawing
    var tinted = false

    var body: some View {
        let canvas = Canvas { context, size in
            DieRenderer(drawing: drawing, chip: chip).render(context, size: size, state: AnimState(), time: 0)
        }
        Group {
            if tinted { canvas.luminanceToAlpha() } else { canvas }
        }
        .accessibilityLabel(Text("\(chip.brand) die"))
    }
}

/// The widget's content for one size. `drawing` is already `WidgetArt.dieOnly`.
struct WidgetContent: View {
    let chip: ChipInfo
    let drawing: ChipDrawing
    let family: WidgetArt.Family
    var tinted = false

    var body: some View {
        switch family {
        case .small: WidgetDie(chip: chip, drawing: drawing, tinted: tinted).padding(10)
        case .large: WidgetDie(chip: chip, drawing: drawing, tinted: tinted).padding(14)
        case .medium: medium.padding(14)
        }
    }

    /// The die on the left, as tall as the widget; the chip's name and parts on the right.
    private var medium: some View {
        let pal = ChipCatalog.palette(chip)
        let aspect = drawing.size.width / max(drawing.size.height, 0.01)
        let gb = 1_073_741_824.0
        let memory = Int((Double(chip.memoryBytes) / gb).rounded())
        // "2S+4P+6E": compact, so three tiers still fit beside the die.
        let tiers = chip.tiers.map { "\($0.cpuCount)\($0.letter)" }.joined(separator: "+")
        return GeometryReader { geo in
            HStack(alignment: .center, spacing: 14) {
                WidgetDie(chip: chip, drawing: drawing, tinted: tinted)
                    .frame(width: min(geo.size.height * aspect, geo.size.width * 0.5), height: geo.size.height)
                VStack(alignment: .leading, spacing: 4) {
                    Text(chip.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.bottom, 2)
                    row("CPU", "\(chip.cpuCount)-core", tiers, pal)
                    row("GPU", "\(chip.gpuCores)-core", nil, pal)
                    row("NE", "\(chip.npuCores)-core", nil, pal)
                    row("MEM", "\(memory)GB", "\(ChipCatalog.formatBandwidth(ChipCatalog.bandwidth(chip).gbps)) GB/s", pal)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ label: String, _ value: String, _ detail: String?, _ pal: ChipPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(pal.accent.color)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundColor(pal.value.color)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Color(white: 1, opacity: 0.6))
            }
        }
    }
}

/// Every widget size a chip offers on a desktop-like background: the top row in colour, the
/// bottom row tinted as macOS shows them when another window is in front. For review: the
/// debug panel's widget preview and `--simulate`.
struct WidgetPreviewSheet: View {
    let chip: ChipInfo
    let drawing: ChipDrawing        // the full drawing; the widget crops it itself

    var body: some View {
        let die = WidgetArt.dieOnly(drawing)
        let families = WidgetArt.families(for: chip)
        VStack(alignment: .leading, spacing: 18) {
            ForEach([false, true], id: \.self) { tinted in
                HStack(alignment: .top, spacing: 18) {
                    ForEach(families, id: \.self) { f in tile(f, die: die, tinted: tinted) }
                }
            }
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.30),
                                            Color(red: 0.20, green: 0.17, blue: 0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ f: WidgetArt.Family, die: ChipDrawing, tinted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Group {
            if tinted {
                // The system keeps opacity only and paints it white over a frosted plate.
                Color.white.opacity(0.92)
                    .mask(WidgetContent(chip: chip, drawing: die, family: f, tinted: true))
                    .background(shape.fill(Color.white.opacity(0.12)))
            } else {
                WidgetContent(chip: chip, drawing: die, family: f).background(Color.black)
            }
        }
        .frame(width: f.size.width, height: f.size.height)
        .clipShape(shape)
    }
}
