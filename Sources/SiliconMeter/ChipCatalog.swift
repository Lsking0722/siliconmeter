//
//  ChipCatalog.swift
//  Per-chip facts macOS does not report: the colour each chip was introduced with, its
//  published unified-memory bandwidth, and how many memory packages sit on its package.
//
//  Colours follow the gradient Apple used for each chip's illustration or badge (M1 warm
//  peach→blue, M2 amber→violet, M4 lime→blue→violet, Pro chips blue, Max chips violet, …).
//  Bandwidth figures are Apple's published maxima (GB/s).
//
import Foundation
import CoreGraphics

struct RGB: Equatable {
    let r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    func mix(_ o: RGB, _ t: Double) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    static let white = RGB(0xFFFFFF)
    static let black = RGB(0x000000)
}

struct ChipPalette {
    let stops: [(RGB, Double)]
    /// Gradient axis in unit coordinates of the whole drawing, y pointing down.
    let start: CGPoint
    let end: CGPoint

    /// Bright tint for moving highlights (scan lines, pulses).
    var spark: RGB { stops.map { $0.0 }.max { lum($0) < lum($1) }!.mix(.white, 0.6) }
    /// Near-black cut into the silicon, tinted toward the deepest stop.
    var ink: RGB { stops.map { $0.0 }.min { lum($0) < lum($1) }!.mix(.black, 0.94) }
    /// UI accent for the spec panel (pressure pill, legend).
    var accent: RGB { stops[stops.count / 2].0 }

    /// Colour at position u on the palette run forwards then back (A→…→Z→…→A), so any
    /// phase is seamless. Used for gradients that drift slowly over time.
    func cyclic(_ u: Double) -> RGB {
        let colours = stops.map { $0.0 }
        let sequence = colours + colours.dropFirst().dropLast().reversed()
        let n = sequence.count
        guard n > 1 else { return colours[0] }
        let wrapped = (u.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let x = wrapped * Double(n)
        let i = Int(x) % n
        return sequence[i].mix(sequence[(i + 1) % n], x - floor(x))
    }

    private func lum(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    /// Light at the bottom-left, saturated at the top-right: the usual keynote lighting.
    static func diagonal(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> ChipPalette {
        ChipPalette(stops: [(RGB(a), 0), (RGB(b), 0.45), (RGB(c), 1)],
                    start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0))
    }
}

enum ChipCatalog {

    // MARK: - Colour

    static func palette(_ chip: ChipInfo) -> ChipPalette {
        // A18 Pro: Apple's line art is rose gold / copper, lighter at the top-left.
        if chip.series == .a {
            return ChipPalette(stops: [(RGB(0xF4D8BF), 0), (RGB(0xD6A782), 0.45), (RGB(0x9C6C4B), 1)],
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        }
        let gen = chip.generation ?? 4
        switch (gen, chip.variant) {
        case (1, .base):
            // Peach top-left, coral/pink down the left edge, violet into blue on the right.
            return ChipPalette(stops: [(RGB(0xF9B48A), 0), (RGB(0xF2667F), 0.35), (RGB(0x9A5CF5), 0.7), (RGB(0x3F8CFF), 1)],
                               start: CGPoint(x: 0, y: 0.1), end: CGPoint(x: 1, y: 0.6))
        case (1, .pro):   return .diagonal(0x8FD6FF, 0x3B9BFF, 0x2160F0)
        case (1, .max):   return .diagonal(0xD2B2FF, 0x9C6BFA, 0x6A35E0)
        case (1, .ultra):
            return ChipPalette(stops: [(RGB(0xFFB066), 0), (RGB(0xF2508F), 0.35), (RGB(0xA35CF5), 0.65), (RGB(0x4FB4FF), 1)],
                               start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0))
        case (2, .base):
            // Amber top-left through coral and magenta to violet at the bottom-right.
            return ChipPalette(stops: [(RGB(0xF6B03C), 0), (RGB(0xFF7547), 0.3), (RGB(0xE8418F), 0.62), (RGB(0x8B2BE2), 1)],
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        case (2, .pro):   return .diagonal(0x9ADCFF, 0x4A97FF, 0x2E62EE)
        case (2, .max):   return .diagonal(0xD7BEFF, 0xA06BFF, 0x6E36EA)
        case (2, .ultra): return .diagonal(0xFF9BC9, 0xC266F5, 0x6E6BFF)
        case (3, .base):  return .diagonal(0xB6F3E0, 0x45BFC6, 0x1F6E93)
        case (3, .pro):   return .diagonal(0xA9DCFF, 0x3C7DF5, 0x2C3FC4)
        case (3, .max):   return .diagonal(0xF6C2EB, 0xB262F2, 0x5B2CC8)
        case (3, .ultra): return .diagonal(0xFF9FD0, 0xA85EF6, 0x4F78FF)
        case (4, .pro):   return .diagonal(0x8CCBFF, 0x3E88FF, 0x2350DE)
        case (4, .max), (4, .ultra): return .diagonal(0xC6A4FF, 0x8D52FF, 0x5A24D8)
        case (5, .base):  return .diagonal(0x9EF3EA, 0x33C5D8, 0x2B78E2)
        case (5, .pro):   return .diagonal(0x9EDBFF, 0x4890FF, 0x3A54EE)
        case (5, .max):   return .diagonal(0xE8B4FF, 0xA866FF, 0x6A30E2)
        case (5, .ultra): return .diagonal(0xFF8DBE, 0xAE5BF7, 0x4F7DFF)
        case (6..., .base): return .diagonal(0x8FF2BF, 0x2CC0AE, 0x2C7BE5)
        case (6..., .pro):  return .diagonal(0x9EDBFF, 0x4890FF, 0x3A54EE)
        case (6..., .max):  return .diagonal(0xE8B4FF, 0xA866FF, 0x6A30E2)
        case (6..., .ultra): return .diagonal(0xFF8DBE, 0xAE5BF7, 0x4F7DFF)
        default:
            // M4, sampled from Apple's keynote die shot: lime at the bottom-left through mint and
            // cyan to blue at the other two corners, indigo and violet at the top-right. The axis
            // spans the die itself (its bottom edge is at 0.82 of the drawing; the memory below
            // takes the lime and blue ends). The last stop is a little lighter than the photo's
            // near-black violet so busy GPU cores in that corner still read.
            return ChipPalette(stops: [(RGB(0xC2D276), 0), (RGB(0x89CFB8), 0.125), (RGB(0x67C2D1), 0.25),
                                       (RGB(0x2E86E0), 0.5), (RGB(0x2A28B0), 0.75), (RGB(0x45208E), 1)],
                               start: CGPoint(x: 0, y: 0.82), end: CGPoint(x: 1, y: 0))
        }
    }

    /// UltraFusion: a warm gold, banded across the seam like brushed metal.
    static let gold: [(RGB, Double)] = [
        (RGB(0x5E3F0E), 0), (RGB(0xB8862B), 0.16), (RGB(0xF3D27A), 0.32), (RGB(0xFFF4CF), 0.46),
        (RGB(0xE6B650), 0.6), (RGB(0x9A6C1C), 0.78), (RGB(0xD9A845), 0.9), (RGB(0x6E4A12), 1),
    ]
    static let goldSpark = RGB(0xFFF3C4)
    static let goldBase = RGB(0x24180A)

    // MARK: - Memory

    /// Apple's published maximum unified-memory bandwidth, GB/s. `known` is false where the
    /// figure is extrapolated (a future chip, or a configuration Apple did not list).
    static func bandwidth(_ chip: ChipInfo) -> (gbps: Double, known: Bool) {
        // A18 Pro: 64-bit LPDDR5X, about 60 GB/s.
        if chip.series == .a { return (60, chip.family == "A18") }
        let gen = chip.generation ?? 0
        let bigGPU = chip.gpuCores >= 40
        switch (gen, chip.variant) {
        case (1, .base): return (68.25, true)
        case (1, .pro):  return (200, true)
        case (1, .max):  return (400, true)
        case (1, .ultra): return (800, true)
        case (2, .base): return (100, true)
        case (2, .pro):  return (200, true)
        case (2, .max):  return (400, true)
        case (2, .ultra): return (800, true)
        case (3, .base): return (100, true)
        case (3, .pro):  return (150, true)
        case (3, .max):  return (bigGPU ? 400 : 300, true)
        case (3, .ultra): return (819, true)
        case (4, .base): return (120, true)
        case (4, .pro):  return (273, true)
        case (4, .max):  return (bigGPU ? 546 : 410, true)
        case (5, .base): return (153.6, true)
        case (5, .pro):  return (307, true)
        case (5, .max):  return (bigGPU ? 614 : 460, true)
        case (5, .ultra): return (1228.8, true)
        case (6, .base): return (170, true)
        default:
            switch chip.variant {
            case .base: return (170, false)
            case .pro: return (307, false)
            case .max: return (614, false)
            case .ultra: return (1228.8, false)
            }
        }
    }

    /// GPU cores on one full die of this chip (one Max die for an Ultra). Lower-core models
    /// are the same die with cores disabled, so they are drawn on the full array.
    static func fullGPUCores(_ chip: ChipInfo) -> Int? {
        if chip.series == .a { return chip.family == "A18" ? 6 : nil }
        let perDie = chip.variant == .ultra ? (chip.gpuCores + 1) / 2 : chip.gpuCores
        let full: Int?
        switch (chip.generation ?? 0, chip.variant) {
        case (1, .base): full = 8
        case (1, .pro): full = 16
        case (1, .max), (1, .ultra): full = 32
        case (2, .base): full = 10
        case (2, .pro): full = 19
        case (2, .max), (2, .ultra): full = 38
        case (3, .base): full = 10
        case (3, .pro): full = 18
        case (3, .max), (3, .ultra): full = 40
        case (4, .base): full = 10
        case (4, .pro): full = 20
        case (4, .max), (4, .ultra): full = 40
        case (5, .base): full = 10
        case (5, .pro): full = 20
        case (5, .max), (5, .ultra): full = 40
        default: full = nil
        }
        return full.map { max($0, perDie) }
    }

    /// Neural Engine power taken as full load: about 3 W per 16-core engine. Apple publishes
    /// no figure; this is an estimate, raised automatically to the highest power observed.
    static func aneReferenceWatts(_ chip: ChipInfo) -> Double {
        3.0 * Double(max(16, chip.npuCores)) / 16
    }

    static func memoryPackages(_ chip: ChipInfo) -> Int {
        if chip.series == .a { return 1 }       // one 64-bit LPDDR5X package
        switch chip.variant {
        case .ultra: return 8
        case .max: return 4
        case .pro: return chip.generation == 3 ? 3 : 2
        case .base: return 2
        }
    }

    /// Memory lanes drawn in total, proportional to bandwidth.
    static func memoryLanes(_ gbps: Double) -> Int {
        min(96, max(8, Int((6 + gbps / 14).rounded())))
    }

    /// Pulses travelling each lane at once, proportional to bandwidth.
    static func pulsesPerLane(_ gbps: Double) -> Int {
        1 + min(4, Int(gbps / 300))
    }

    static func formatBandwidth(_ gbps: Double) -> String {
        String(format: "%g", gbps)
    }
}
