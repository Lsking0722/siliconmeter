//
//  DieHover.swift
//  Pointing at the die: every block of the same kind gets a soft glowing outline, and a small
//  label beside the pointer says what it is ("P-core", "GPU core", "Neural Engine", …) with
//  its live value.
//
import SwiftUI

/// The kind of thing under the pointer. Blocks of the same kind light up together.
enum DieRegion: Equatable {
    case core(cpu: Int, tier: Int)
    case cache
    case gpu(Int)
    case npu
    case slc
    case misc
    case memory
    case bridge(BridgeKind)

    /// Blocks with the same group are outlined together (a P-core lights every P-core).
    var group: String {
        switch self {
        case let .core(_, tier): return "core\(tier)"
        case .cache: return "cache"
        case .gpu: return "gpu"
        case .npu: return "npu"
        case .slc: return "slc"
        case .misc: return "misc"
        case .memory: return "memory"
        case let .bridge(kind): return kind.rawValue
        }
    }
}

struct DieHoverLabel {
    let title: String
    let detail: String
    let value: String?
}

enum DieHover {
    /// The region at `p` (drawing units). The smallest block wins; the chip name and unused
    /// cells answer nothing, so moving across them clears the label instead of naming the die.
    static func region(at p: CGPoint, in drawing: ChipDrawing) -> DieRegion? {
        var best: DieBlock?
        for block in drawing.blocks where block.rect.contains(p) {
            if let b = best, b.rect.width * b.rect.height <= block.rect.width * block.rect.height { continue }
            best = block
        }
        if let block = best {
            switch block.kind {
            case let .core(cpu, tier): return .core(cpu: cpu, tier: tier)
            case .clusterCache, .tierCache: return .cache
            case let .gpuCore(i): return .gpu(i)
            case .npuCore: return .npu
            case .slc: return .slc
            case .misc: return .misc
            case .filler, .logo: return nil
            }
        }
        if drawing.packages.contains(where: { $0.contains(p) }) { return .memory }
        if let bridge = drawing.bridges.first(where: { $0.rect.contains(p) }) { return .bridge(bridge.kind) }
        return nil
    }

    /// Every rectangle (drawing units) of the same kind as `region`.
    static func rects(of region: DieRegion, in drawing: ChipDrawing) -> [CGRect] {
        switch region {
        case .memory: return drawing.packages
        case let .bridge(kind): return drawing.bridges.filter { $0.kind == kind }.map(\.rect)
        default:
            let group = region.group
            return drawing.blocks.compactMap { block -> CGRect? in
                let r: DieRegion?
                switch block.kind {
                case let .core(cpu, tier): r = .core(cpu: cpu, tier: tier)
                case .clusterCache, .tierCache: r = .cache
                case let .gpuCore(i): r = .gpu(i)
                case .npuCore: r = .npu
                case .slc: r = .slc
                case .misc: r = .misc
                case .filler, .logo: r = nil
                }
                return r?.group == group ? block.rect : nil
            }
        }
    }

    static func label(for region: DieRegion, chip: ChipInfo, snapshot s: Snapshot) -> DieHoverLabel {
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        let gb = 1_073_741_824.0
        switch region {
        case let .core(cpu, tier):
            let t = chip.tiers.first { $0.index == tier }
            let load = s.valid && cpu < s.cores.count ? pct(s.cores[cpu]) : nil
            return DieHoverLabel(title: t?.shortName ?? "CPU core",
                                 detail: "\(t?.name ?? "CPU") core · CPU \(cpu)", value: load)
        case .cache:
            return DieHoverLabel(title: "CPU cache", detail: "Shared by a core cluster", value: nil)
        case let .gpu(i):
            return DieHoverLabel(title: "GPU core",
                                 detail: "\(i + 1) of \(chip.gpuCores) · load is for the whole GPU",
                                 value: s.valid ? pct(s.gpu) : nil)
        case .npu:
            return DieHoverLabel(title: "Neural Engine", detail: "\(chip.npuCores)-core",
                                 value: s.ane.map { pct($0) + (s.aneEstimated ? " est." : "") })
        case .slc:
            return DieHoverLabel(title: "System level cache", detail: "Shared by CPU, GPU and Neural Engine",
                                 value: nil)
        case .misc:
            return DieHoverLabel(title: "Media & I/O", detail: "Media engines, display, I/O", value: nil)
        case .memory:
            let total = Int((Double(chip.memoryBytes) / gb).rounded())
            let bw = ChipCatalog.formatBandwidth(ChipCatalog.bandwidth(chip).gbps)
            return DieHoverLabel(title: "Unified memory", detail: "\(total)GB · \(bw) GB/s",
                                 value: s.memory.total > 0 ? String(format: "%.1f GB", s.memory.used / gb) : nil)
        case .bridge(.ultraFusion):
            return DieHoverLabel(title: "UltraFusion", detail: "Joins the two dies", value: nil)
        case .bridge(.fusion):
            return DieHoverLabel(title: "Fusion", detail: "Joins the CPU die and the GPU die", value: nil)
        }
    }
}

/// Pointer state of one die view (a popover and a window each have their own).
final class DieHoverState: ObservableObject {
    /// Pointer position in canvas points; nil when the pointer is off the die.
    @Published var point: CGPoint?
    @Published var region: DieRegion?

    // Drawn state, eased every frame (not published: the frame clock redraws anyway).
    var shown: DieRegion?
    var level = 0.0
    private var lastTime: Double?

    /// Eases the outline toward the pointer's region; returns what to outline and how strongly.
    func step(time: Double) -> (DieRegion, Double)? {
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        if let region {
            shown = region
            level += (1 - level) * (1 - exp(-dt * 14))
        } else {
            level += (0 - level) * (1 - exp(-dt * 10))
            if level < 0.01 { level = 0; shown = nil }
        }
        guard let shown, level > 0 else { return nil }
        return (shown, level)
    }
}

extension DieRenderer {
    /// Soft glowing outlines around every block of `region`'s kind.
    func drawHover(_ ctx: GraphicsContext, size: CGSize, region: DieRegion, level: Double, time t: Double) {
        let g = geometry(size)
        let pal = ChipCatalog.palette(chip)
        let rects = DieHover.rects(of: region, in: drawing)
        guard !rects.isEmpty else { return }
        var path = Path()
        for r in rects { path.addRect(g.R(r).insetBy(dx: -0.5, dy: -0.5)) }
        // A slow breath keeps it alive without drawing attention (still with Reduce Motion: t = 0).
        let breath = t == 0 ? 1 : 0.86 + 0.14 * sin(t * 2.4)
        let width = max(1, g.s * 0.004)
        var glow = ctx
        glow.addFilter(.shadow(color: pal.spark.color.opacity(0.75 * level), radius: 5))
        glow.stroke(path, with: .color(pal.spark.color.opacity(0.55 * level * breath)), lineWidth: width * 1.6)
        ctx.stroke(path, with: .color(Color.white.opacity(0.7 * level * breath)), lineWidth: width * 0.8)
    }
}

/// The label beside the pointer, drawn straight into the die's canvas: measured, then placed
/// right of and below the pointer, flipped to the other side near the right or bottom edge
/// and kept inside the canvas. (Placed as a SwiftUI overlay it stayed pinned to the canvas's
/// top-left corner in the live popover.)
enum DieHoverTag {
    static func draw(_ ctx: GraphicsContext, size: CGSize, at p: CGPoint, label: DieHoverLabel,
                     accent: Color, valueColor: Color, opacity: Double = 1) {
        var title = Text(label.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
        if let value = label.value {
            title = title + Text("  " + value).font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(valueColor)
        }
        let detail = Text(label.detail).font(.system(size: 10.5)).foregroundColor(Color(white: 1, opacity: 0.72))
        let t1 = ctx.resolve(title), t2 = ctx.resolve(detail)
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let s1 = t1.measure(in: unbounded), s2 = t2.measure(in: unbounded)
        let w = max(s1.width, s2.width) + 16, h = s1.height + 1 + s2.height + 10

        let x0 = p.x > size.width * 0.62 ? p.x - 14 - w : p.x + 16
        let y0 = p.y > size.height - 64 ? p.y - 12 - h : p.y + 18
        let box = CGRect(x: min(max(0, x0), max(0, size.width - w)),
                         y: min(max(0, y0), max(0, size.height - h)), width: w, height: h)

        var c = ctx
        c.opacity = opacity
        let shape = Path(roundedRect: box, cornerRadius: 7, style: .continuous)
        var shadowed = c
        shadowed.addFilter(.shadow(color: .black.opacity(0.35), radius: 6, y: 2))
        shadowed.fill(shape, with: .color(Color.black.opacity(0.82)))
        c.stroke(Path(roundedRect: box.insetBy(dx: 0.4, dy: 0.4), cornerRadius: 7, style: .continuous),
                 with: .color(accent.opacity(0.45)), lineWidth: 0.8)
        c.draw(t1, at: CGPoint(x: box.minX + 8, y: box.minY + 5), anchor: .topLeading)
        c.draw(t2, at: CGPoint(x: box.minX + 8, y: box.minY + 5 + s1.height + 1), anchor: .topLeading)
    }
}
