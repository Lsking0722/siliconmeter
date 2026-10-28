//
//  ChipLayout.swift
//  Turns a detected chip into a drawing: die outlines, blocks (cores, GPU cores, Neural
//  Engine, caches), memory packages, the memory lanes and the die-to-die bridges.
//
//  Each chip generation and variant has its own floorplan (Floorplans below): where the
//  CPU clusters, GPU, Neural Engine and caches sit, and the die's aspect ratio. Block
//  placement follows Apple's published chip illustrations for that chip (M1, M1 Pro/Max,
//  M2, M2 Pro/Max, M4, M4 Pro/Max, M5, M5 Pro/Max); where Apple published no illustration
//  (M3 family, M6) it follows the same generation's conventions and the die's proportions.
//  The detected cluster and core counts are poured into those regions, so binned parts
//  need no template of their own. Inner line detail is drawn procedurally, not traced.
//
//  Ultra chips are two Max dies stacked vertically, the second turned 180°, joined across
//  the whole seam by UltraFusion. M5 Ultra stacks two M5 Max packages (CPU die + GPU die).
//
//  Units: one die is 1.0 wide.
//
import CoreGraphics
import Foundation

enum BlockKind {
    case core(cpu: Int, tier: Int)
    case clusterCache(cpus: [Int])      // shared L2 strip above a CPU cluster
    case tierCache(tier: Int)           // larger cache array near a tier
    case gpuCore(Int)
    case npuCore(Int)
    case slc(Int)                       // system level cache bank
    case misc                           // media / display / I/O blocks
    case filler                         // unused grid cell
    case logo(title: String, tag: String?)
}

struct DieBlock {
    var rect: CGRect
    var kind: BlockKind
}

struct Trace {
    var from: CGPoint
    var to: CGPoint
}

enum BridgeKind: String {
    case fusion        // CPU die ↔ GPU die inside one package (M5 Pro/Max)
    case ultraFusion   // die ↔ die across an Ultra
}

struct Bridge {
    var rect: CGRect
    var kind: BridgeKind
}

struct ChipDrawing {
    var size: CGSize = .zero
    var dies: [CGRect] = []
    var blocks: [DieBlock] = []
    var packages: [CGRect] = []
    var traces: [Trace] = []
    var bridges: [Bridge] = []
    var bandwidth: Double = 100
    var bandwidthKnown = true
    var pulsesPerLane = 1
}

// MARK: - Floorplans

struct Area {
    var r: CGRect
    var rows: Int? = nil
    var slots: Int? = nil       // cells drawn even when fewer cores are enabled (binned parts)
}

struct GridSpec {
    var r: CGRect
    var cols: Int
    var rows: Int
}

struct Floorplan {
    var height: CGFloat
    var logo: CGRect? = nil
    var cpu: [CGRect] = []          // tier areas, fastest first
    var cache: CGRect? = nil        // cache array of the slowest tier
    var gpu: [Area] = []
    var npu: [CGRect] = []          // one rect per Neural Engine
    var npuRows: Int? = nil
    var slc: [GridSpec] = []
    var misc: [GridSpec] = []
}

enum Floorplans {
    private static let m: CGFloat = 0.027
    private static func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Single-die floorplan for a generation and variant.
    static func die(gen: Int, variant: ChipVariant) -> Floorplan {
        switch variant {
        case .base:
            switch gen {
            case ...1: return m1
            case 2: return m2
            case 3: return m3
            case 4: return m4
            case 5: return m5
            default: return m6
            }
        case .pro:
            switch gen {
            case ...2: return m1Pro
            case 3: return m3Pro
            default: return m4Pro
            }
        case .max, .ultra:
            switch gen {
            case ...1: return maxM1M2(height: 1.08)
            case 2: return maxM1M2(height: 1.1)
            case 3: return m3Max
            default: return m4Max
            }
        }
    }

    // Base chips: CPU column on the left under the name, GPU top-right, Neural Engine and
    // system cache bottom-right.

    static let m1 = Floorplan(
        height: 1.04,
        logo: R(m, m, 0.43, 0.13),
        cpu: [R(m, 0.165, 0.43, 0.30), R(m, 0.473, 0.43, 0.16)],
        cache: R(m, 0.641, 0.43, 0.372),
        gpu: [Area(r: R(0.465, m, 0.508, 0.40), rows: 2)],
        npu: [R(0.465, 0.435, 0.25, 0.21)],
        slc: [GridSpec(r: R(0.465, 0.653, 0.508, 0.36), cols: 2, rows: 6)],
        misc: [GridSpec(r: R(0.723, 0.435, 0.25, 0.21), cols: 1, rows: 2)])

    static let m2 = Floorplan(
        height: 0.98,
        logo: R(m, m, 0.40, 0.13),
        cpu: [R(m, 0.165, 0.40, 0.40), R(m, 0.573, 0.40, 0.17)],
        cache: R(m, 0.751, 0.40, 0.202),
        gpu: [Area(r: R(0.435, m, 0.538, 0.40), rows: 1)],
        npu: [R(0.435, 0.633, 0.42, 0.32)],
        slc: [GridSpec(r: R(0.863, 0.633, 0.11, 0.32), cols: 1, rows: 6)],
        misc: [GridSpec(r: R(0.435, 0.435, 0.538, 0.19), cols: 4, rows: 1)])

    /// M3, after Apple's line art: the name over a full-width band of ten GPU cores (5 × 2);
    /// below it, efficiency cores over four tall performance cores on the left, media and
    /// display blocks, the Neural Engine and a cache column on the right. 8-core GPUs leave
    /// two of the ten cells dark.
    static let m3 = Floorplan(
        height: 0.84,
        logo: R(m, m, 0.375, 0.12),
        cpu: [R(m, 0.571, 0.375, 0.242), R(m, 0.419, 0.375, 0.142)],
        gpu: [Area(r: R(m, 0.157, 0.946, 0.252), rows: 2, slots: 10)],
        npu: [R(0.412, 0.571, 0.176, 0.242)],
        slc: [GridSpec(r: R(0.788, 0.419, 0.185, 0.27), cols: 1, rows: 4)],
        misc: [GridSpec(r: R(0.412, m, 0.561, 0.12), cols: 6, rows: 2),
               GridSpec(r: R(0.412, 0.419, 0.366, 0.142), cols: 2, rows: 1),
               GridSpec(r: R(0.598, 0.571, 0.18, 0.242), cols: 1, rows: 2),
               GridSpec(r: R(0.788, 0.699, 0.185, 0.114), cols: 1, rows: 1)])

    static let m4 = Floorplan(
        height: 1.06,
        logo: R(m, m, 0.45, 0.14),
        cpu: [R(m, 0.175, 0.45, 0.38), R(m, 0.563, 0.45, 0.16)],
        cache: R(m, 0.731, 0.45, 0.302),
        gpu: [Area(r: R(0.485, m, 0.488, 0.46), rows: 2)],
        npu: [R(0.485, 0.613, 0.27, 0.42)],
        slc: [GridSpec(r: R(0.763, 0.613, 0.21, 0.42), cols: 2, rows: 8)],
        misc: [GridSpec(r: R(0.485, 0.495, 0.488, 0.11), cols: 3, rows: 1)])

    /// M5, after Apple's line art: the name over four tall super cores, six efficiency cores
    /// and the 16-core Neural Engine (8 × 2) down the left; ten GPU cores (5 × 2) on the
    /// right over media blocks and the system cache. 8-core GPUs leave two cells dark.
    static let m5 = Floorplan(
        height: 1.0,
        logo: R(m, m, 0.465, 0.145),
        cpu: [R(m, 0.182, 0.465, 0.43), R(m, 0.622, 0.465, 0.175)],
        gpu: [Area(r: R(0.502, m, 0.471, 0.585), rows: 2, slots: 10)],
        npu: [R(m, 0.806, 0.465, 0.167)],
        npuRows: 2,
        slc: [GridSpec(r: R(0.692, 0.622, 0.281, 0.351), cols: 2, rows: 4)],
        misc: [GridSpec(r: R(0.502, 0.622, 0.18, 0.351), cols: 1, rows: 3)])

    /// M6: Super and Performance share the large CPU area; two Neural Engines side by side.
    static let m6 = Floorplan(
        height: 0.84,
        logo: R(m, m, 0.44, 0.14),
        cpu: [R(m, 0.175, 0.44, 0.33), R(m, 0.513, 0.44, 0.15)],
        cache: R(m, 0.671, 0.44, 0.142),
        gpu: [Area(r: R(0.475, m, 0.498, 0.40), rows: 2)],
        npu: [R(0.475, 0.533, 0.245, 0.28), R(0.728, 0.533, 0.245, 0.28)],
        misc: [GridSpec(r: R(0.475, 0.435, 0.498, 0.09), cols: 4, rows: 1)])

    /// A18 Pro (MacBook Neo), after Apple's line art: the name and two performance cores over
    /// four efficiency cores on the left, the 16-core Neural Engine (two rows of eight) below
    /// them; three blocks over a six-column GPU on the right (five columns enabled on the Mac
    /// part, the sixth drawn dark), media and I/O blocks, and two system-cache banks.
    static let a18Pro = Floorplan(
        height: 1.0,
        logo: R(m, m, 0.465, 0.13),
        cpu: [R(m, 0.167, 0.465, 0.275), R(m, 0.452, 0.465, 0.16)],
        gpu: [Area(r: R(0.502, 0.167, 0.471, 0.445), rows: 1, slots: 6)],
        npu: [R(m, 0.622, 0.465, 0.351)],
        npuRows: 2,
        slc: [GridSpec(r: R(0.502, 0.802, 0.471, 0.171), cols: 2, rows: 1)],
        misc: [GridSpec(r: R(0.502, m, 0.471, 0.13), cols: 3, rows: 1),
               GridSpec(r: R(0.502, 0.622, 0.471, 0.17), cols: 3, rows: 2)])

    // Pro chips: wider than tall. CPU column left, a cache spine, the GPU array, and an I/O
    // column on the right edge.

    static let m1Pro = Floorplan(
        height: 0.84,
        logo: R(m, m, 0.30, 0.12),
        cpu: [R(m, 0.155, 0.30, 0.42), R(m, 0.583, 0.30, 0.10)],
        cache: R(m, 0.691, 0.30, 0.122),
        gpu: [Area(r: R(0.443, m, 0.40, 0.52), rows: 4)],
        npu: [R(0.443, 0.555, 0.40, 0.258)],
        slc: [GridSpec(r: R(0.335, m, 0.10, 0.786), cols: 1, rows: 10)],
        misc: [GridSpec(r: R(0.851, m, 0.122, 0.786), cols: 1, rows: 6)])

    static let m3Pro = Floorplan(
        height: 1.16,
        logo: R(m, m, 0.40, 0.10),
        cpu: [R(m, 0.135, 0.40, 0.30), R(m, 0.443, 0.40, 0.22)],
        cache: R(m, 0.671, 0.40, 0.14),
        gpu: [Area(r: R(0.435, m, 0.538, 0.70), rows: 6)],
        npu: [R(m, 0.819, 0.40, 0.314)],
        misc: [GridSpec(r: R(0.435, 0.735, 0.538, 0.398), cols: 3, rows: 3)])

    static let m4Pro = Floorplan(
        height: 0.80,
        logo: R(m, m, 0.30, 0.10),
        cpu: [R(m, 0.135, 0.30, 0.42), R(m, 0.563, 0.30, 0.12)],
        cache: R(m, 0.691, 0.30, 0.082),
        gpu: [Area(r: R(0.335, m, 0.638, 0.46), rows: 2)],
        npu: [R(0.335, 0.573, 0.30, 0.20)],
        misc: [GridSpec(r: R(0.335, 0.495, 0.638, 0.07), cols: 6, rows: 1),
               GridSpec(r: R(0.643, 0.573, 0.33, 0.20), cols: 3, rows: 2)])

    // Max chips: taller than wide.

    /// M1 Max / M2 Max: the Pro layout on top, a second GPU array across the bottom.
    static func maxM1M2(height h: CGFloat) -> Floorplan {
        Floorplan(
            height: h,
            logo: R(m, m, 0.30, 0.09),
            cpu: [R(m, 0.125, 0.30, 0.31), R(m, 0.443, 0.30, 0.07)],
            cache: R(m, 0.521, 0.30, 0.08),
            gpu: [Area(r: R(0.443, m, 0.40, 0.43), rows: 4),
                  Area(r: R(m, 0.609, 0.946, h - 0.609 - m - 0.06 - 0.008), rows: 2)],
            npu: [R(0.443, 0.465, 0.40, 0.136)],
            slc: [GridSpec(r: R(0.335, m, 0.10, 0.574), cols: 1, rows: 8)],
            misc: [GridSpec(r: R(0.851, m, 0.122, 0.574), cols: 1, rows: 5),
                   GridSpec(r: R(m, h - m - 0.06, 0.946, 0.06), cols: 8, rows: 1)])
    }

    /// M3 Max, after Apple's line art: the name over twelve performance cores, four
    /// efficiency cores and their caches on the left; a cache spine, the Neural Engine and
    /// media blocks beside them; the whole lower half a 40-core GPU (8 × 5). 30-core parts
    /// leave ten cells dark.
    static let m3Max = Floorplan(
        height: 1.022,
        logo: R(m, m, 0.335, 0.07),
        cpu: [R(m, 0.105, 0.335, 0.225), R(m, 0.34, 0.335, 0.075)],
        cache: R(m, 0.425, 0.335, 0.12),
        gpu: [Area(r: R(m, 0.555, 0.946, 0.44), rows: 5, slots: 40)],
        npu: [R(0.542, 0.105, 0.431, 0.225)],
        npuRows: 2,
        slc: [GridSpec(r: R(0.372, 0.105, 0.16, 0.44), cols: 1, rows: 6)],
        misc: [GridSpec(r: R(0.372, m, 0.601, 0.068), cols: 6, rows: 2),
               GridSpec(r: R(0.542, 0.34, 0.431, 0.205), cols: 4, rows: 2)])

    /// M4 Max: 12 performance cores down the left column, 4 efficiency cores at its foot,
    /// a 5 × 8 GPU array, Neural Engine and media blocks along the bottom.
    static let m4Max = Floorplan(
        height: 1.14,
        logo: R(m, m, 0.31, 0.07),
        cpu: [R(m, 0.105, 0.31, 0.76), R(m, 0.873, 0.31, 0.12)],
        cache: R(m, 1.001, 0.31, 0.112),
        gpu: [Area(r: R(0.345, m, 0.628, 0.75), rows: 5)],
        npu: [R(0.345, 0.785, 0.26, 0.328)],
        misc: [GridSpec(r: R(0.613, 0.785, 0.36, 0.328), cols: 3, rows: 3)])

    // Fusion (M5 Pro / Max / Ultra): a CPU die above a GPU die.

    /// CPU die: super cores left, performance cores right, I/O strip along the top,
    /// Neural Engine on the right edge.
    static let fusionCPU = Floorplan(
        height: 0.52,
        logo: R(m, m, 0.36, 0.13),
        cpu: [R(m, 0.165, 0.36, 0.328), R(0.395, 0.165, 0.44, 0.328)],
        npu: [R(0.843, 0.165, 0.13, 0.328)],
        misc: [GridSpec(r: R(0.395, m, 0.578, 0.13), cols: 6, rows: 1)])

    static func fusionGPU(height h: CGFloat, rows: Int) -> Floorplan {
        Floorplan(
            height: h,
            gpu: [Area(r: R(m, m, 0.79, h - 2 * m), rows: rows)],
            misc: [GridSpec(r: R(0.825, m, 0.148, h - 2 * m), cols: 1, rows: 4)])
    }
}

// MARK: - Layout

enum ChipLayout {
    static let gap: CGFloat = 0.008     // silicon line between blocks

    static func build(for chip: ChipInfo) -> ChipDrawing {
        var d = ChipDrawing()
        let bw = ChipCatalog.bandwidth(chip)
        d.bandwidth = bw.gbps
        d.bandwidthKnown = bw.known
        d.pulsesPerLane = ChipCatalog.pulsesPerLane(bw.gbps)

        let tiers = (0..<max(chip.tiers.count, 1)).map { chip.clusters(ofTier: $0) }
        let gen = chip.mGeneration ?? 4
        // Apple's line art sets the name in one size ("M3 MAX", "A18 PRO"), which also keeps
        // the variant legible on the small logo blocks of Max and Ultra dies.
        let title = ([chip.family] + [chip.tag].compactMap { $0 }).joined(separator: " ")
        let tag: String? = nil
        let g = chip.gpuCores, n = chip.npuCores
        let fullGPU = ChipCatalog.fullGPUCores(chip)       // per die
        let fusionBridge: CGFloat = 0.05
        let seam: CGFloat = 0.085
        var sides = false

        switch chip.archetype {
        case .mono, .proMax:
            let fp = chip.series == .a ? Floorplans.a18Pro : Floorplans.die(gen: gen, variant: chip.variant)
            let die = CGRect(x: 0, y: 0, width: 1, height: fp.height)
            d.dies = [die]
            d.blocks = blocks(fp, die: die, tiers: tiers, gpu: 0..<g, npu: 0..<n, title: title, tag: tag,
                              gpuSlots: fullGPU)

        case .ultra:
            // Two Max dies, the second turned 180°, joined along the whole seam.
            let fp = Floorplans.die(gen: gen, variant: .max)
            let die0 = CGRect(x: 0, y: 0, width: 1, height: fp.height)
            let die1 = CGRect(x: 0, y: fp.height + seam, width: 1, height: fp.height)
            d.dies = [die0, die1]
            let halves = halve(tiers)
            let gHalf = (g + 1) / 2, nHalf = n / 2
            d.blocks = blocks(fp, die: die0, tiers: halves.map { $0.0 }, gpu: 0..<gHalf, npu: 0..<nHalf,
                              title: title, tag: tag, gpuSlots: fullGPU)
            d.blocks += blocks(fp, die: die1, tiers: halves.map { $0.1 }, gpu: gHalf..<g, npu: nHalf..<n,
                               title: nil, tag: nil, gpuSlots: fullGPU).map { rotated($0, in: die1) }
            d.bridges = [Bridge(rect: CGRect(x: 0, y: fp.height, width: 1, height: seam), kind: .ultraFusion)]
            sides = true

        case .fusion:
            let cpuFP = Floorplans.fusionCPU
            let gpuFP = chip.variant == .max ? Floorplans.fusionGPU(height: 0.92, rows: 4)
                                             : Floorplans.fusionGPU(height: 0.6, rows: 2)
            let cpuDie = CGRect(x: 0, y: 0, width: 1, height: cpuFP.height)
            let gpuDie = CGRect(x: 0, y: cpuFP.height + fusionBridge, width: 1, height: gpuFP.height)
            d.dies = [cpuDie, gpuDie]
            d.blocks = blocks(cpuFP, die: cpuDie, tiers: tiers, gpu: 0..<0, npu: 0..<n, title: title, tag: tag)
                + blocks(gpuFP, die: gpuDie, tiers: [], gpu: 0..<g, npu: 0..<0, title: nil, tag: nil, gpuSlots: fullGPU)
            d.bridges = [Bridge(rect: CGRect(x: 0, y: cpuFP.height, width: 1, height: fusionBridge), kind: .fusion)]

        case .fusionUltra:
            // Two M5 Max packages stacked, the lower one turned 180°: CPU, GPU | GPU, CPU.
            let cpuFP = Floorplans.fusionCPU
            let gpuFP = Floorplans.fusionGPU(height: 0.8, rows: 4)
            var y: CGFloat = 0
            let cpu0 = CGRect(x: 0, y: y, width: 1, height: cpuFP.height); y += cpuFP.height
            let f0 = CGRect(x: 0, y: y, width: 1, height: fusionBridge); y += fusionBridge
            let gpu0 = CGRect(x: 0, y: y, width: 1, height: gpuFP.height); y += gpuFP.height
            let u = CGRect(x: 0, y: y, width: 1, height: seam); y += seam
            let gpu1 = CGRect(x: 0, y: y, width: 1, height: gpuFP.height); y += gpuFP.height
            let f1 = CGRect(x: 0, y: y, width: 1, height: fusionBridge); y += fusionBridge
            let cpu1 = CGRect(x: 0, y: y, width: 1, height: cpuFP.height)
            d.dies = [cpu0, gpu0, gpu1, cpu1]
            let halves = halve(tiers)
            let gHalf = (g + 1) / 2, nHalf = n / 2
            d.blocks = blocks(cpuFP, die: cpu0, tiers: halves.map { $0.0 }, gpu: 0..<0, npu: 0..<nHalf,
                              title: title, tag: tag)
            d.blocks += blocks(gpuFP, die: gpu0, tiers: [], gpu: 0..<gHalf, npu: 0..<0, title: nil, tag: nil,
                               gpuSlots: fullGPU)
            d.blocks += blocks(gpuFP, die: gpu1, tiers: [], gpu: gHalf..<g, npu: 0..<0, title: nil, tag: nil,
                               gpuSlots: fullGPU)
                .map { rotated($0, in: gpu1) }
            d.blocks += blocks(cpuFP, die: cpu1, tiers: halves.map { $0.1 }, gpu: 0..<0, npu: nHalf..<n,
                               title: nil, tag: nil).map { rotated($0, in: cpu1) }
            d.bridges = [Bridge(rect: f0, kind: .fusion), Bridge(rect: u, kind: .ultraFusion),
                         Bridge(rect: f1, kind: .fusion)]
            sides = true
        }

        let lanes = ChipCatalog.memoryLanes(bw.gbps)
        let packages = ChipCatalog.memoryPackages(chip)
        if sides { addMemorySides(&d, count: packages, lanes: lanes) }
        else { addMemoryBelow(&d, count: packages, lanes: lanes) }
        return d
    }

    // MARK: - Floorplan → blocks

    /// `gpuSlots`: GPU cores on the full die (ChipCatalog.fullGPUCores). Binned parts draw
    /// the full array with the disabled cores dark, so every model of a chip shares one
    /// GPU layout (a 64-core M5 Ultra looks like the 80-core one, eight cores dark per die).
    static func blocks(_ fp: Floorplan, die: CGRect, tiers: [[CoreCluster]], gpu: Range<Int>, npu: Range<Int>,
                       title: String?, tag: String?, gpuSlots: Int? = nil) -> [DieBlock] {
        func T(_ r: CGRect) -> CGRect { r.offsetBy(dx: die.minX, dy: die.minY) }
        var b: [DieBlock] = []
        if let l = fp.logo {
            b.append(DieBlock(rect: T(l), kind: title.map { .logo(title: $0, tag: tag) } ?? .filler))
        }
        if !fp.cpu.isEmpty {
            b += tiers.isEmpty ? fp.cpu.map { DieBlock(rect: T($0), kind: .filler) }
                               : placeTiers(tiers, areas: fp.cpu.map(T))
        }
        if let c = fp.cache {
            b.append(DieBlock(rect: T(c), kind: .tierCache(tier: max(0, tiers.count - 1))))
        }
        b += cores(fp.gpu.map { Area(r: T($0.r), rows: $0.rows, slots: $0.slots) }, range: gpu, target: 0.55,
                   slots: gpu.isEmpty ? nil : gpuSlots) { .gpuCore($0) }
        b += cores(fp.npu.map { Area(r: T($0), rows: fp.npuRows) }, range: npu, target: 1.0) { .npuCore($0) }
        var bank = 0
        for s in fp.slc {
            for cell in grid(T(s.r), cols: s.cols, rows: s.rows) {
                b.append(DieBlock(rect: cell, kind: .slc(bank)))
                bank += 1
            }
        }
        for s in fp.misc {
            b += grid(T(s.r), cols: s.cols, rows: s.rows).map { DieBlock(rect: $0, kind: .misc) }
        }
        return b
    }

    /// Spreads a core range over areas in proportion to their size; each area becomes a grid
    /// with the requested row count (or the best-fitting one).
    /// With `slots` (cells on the full die), the cells are spread over the areas first and
    /// the enabled cores fill each area in proportion, so the grid never depends on binning.
    private static func cores(_ areas: [Area], range: Range<Int>, target: CGFloat, slots: Int? = nil,
                              kind: (Int) -> BlockKind) -> [DieBlock] {
        guard !areas.isEmpty else { return [] }
        let weights = areas.map { $0.r.width * $0.r.height }
        let slotCounts = slots.map { split(max($0, range.count), weights: weights) }
        let counts = slotCounts.map { split(range.count, weights: $0.map { CGFloat($0) }) }
            ?? split(range.count, weights: weights)
        var next = range.lowerBound
        var out: [DieBlock] = []
        for (index, (area, c)) in zip(areas, counts).enumerated() {
            guard c > 0 else { out.append(DieBlock(rect: area.r, kind: .filler)); continue }
            let total = max(c, slotCounts?[index] ?? area.slots ?? 0)
            let dims: (Int, Int)
            if let wanted = area.rows {
                let r = max(1, min(wanted, total))
                dims = ((total + r - 1) / r, r)
            } else {
                dims = bestGrid(total, in: area.r, target: target)
            }
            let (cols, rows) = dims
            for (i, cell) in grid(area.r, cols: cols, rows: rows).enumerated() {
                out.append(DieBlock(rect: cell, kind: i < c ? kind(next + i) : .filler))
            }
            next += c
        }
        return out
    }

    /// Integer split of n by weights, largest remainders first.
    static func split(_ n: Int, weights: [CGFloat]) -> [Int] {
        let total = max(weights.reduce(0, +), 0.0001)
        let exact = weights.map { Double(n) * Double($0 / total) }
        var counts = exact.map { Int($0) }
        var left = n - counts.reduce(0, +)
        for i in exact.indices.sorted(by: { exact[$0] - Double(counts[$0]) > exact[$1] - Double(counts[$1]) }) where left > 0 {
            counts[i] += 1
            left -= 1
        }
        return counts
    }

    // MARK: - Memory

    /// Packages in a row under the dies, lanes running up into the die.
    private static func addMemoryBelow(_ d: inout ChipDrawing, count: Int, lanes: Int) {
        let width = d.dies.map(\.maxX).max() ?? 1
        let bottom = d.dies.map(\.maxY).max() ?? 1
        let top = bottom + 0.06
        let height: CGFloat = 0.17
        let spacing: CGFloat = 0.035
        let n = max(1, count)
        // A single package (A18 Pro) sits centred under the die rather than spanning it.
        let w = n == 1 ? width * 0.62 : (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        let x0 = n == 1 ? (width - w) / 2 : 0
        let perPackage = max(2, Int((Double(lanes) / Double(n)).rounded()))
        for i in 0..<n {
            let r = CGRect(x: x0 + CGFloat(i) * (w + spacing), y: top, width: w, height: height)
            d.packages.append(r)
            for k in 0..<perPackage {
                let x = r.minX + r.width * (0.1 + 0.8 * CGFloat(k) / CGFloat(perPackage - 1))
                d.traces.append(Trace(from: CGPoint(x: x, y: bottom), to: CGPoint(x: x, y: top)))
            }
        }
        d.size = CGSize(width: width, height: top + height)
    }

    /// Ultra: four packages down each side of the die stack, as on the real package.
    private static func addMemorySides(_ d: inout ChipDrawing, count: Int, lanes: Int) {
        let stackH = d.dies.map(\.maxY).max() ?? 1
        let perSide = max(1, count / 2)
        let pw: CGFloat = 0.26, gapX: CGFloat = 0.06, spacing: CGFloat = 0.035
        let ph = (stackH - spacing * CGFloat(perSide - 1)) / CGFloat(perSide)
        let shift = pw + gapX
        let perPackage = max(2, Int((Double(lanes) / Double(perSide * 2)).rounded()))

        // Move the dies right to make room for the left column.
        d.dies = d.dies.map { $0.offsetBy(dx: shift, dy: 0) }
        d.blocks = d.blocks.map { DieBlock(rect: $0.rect.offsetBy(dx: shift, dy: 0), kind: $0.kind) }
        d.bridges = d.bridges.map { Bridge(rect: $0.rect.offsetBy(dx: shift, dy: 0), kind: $0.kind) }
        let left = shift, right = shift + 1

        func onDie(_ y: CGFloat) -> Bool { d.dies.contains { $0.minY + 0.01 <= y && y <= $0.maxY - 0.01 } }
        for side in 0..<2 {
            for i in 0..<perSide {
                let y = CGFloat(i) * (ph + spacing)
                let r = side == 0 ? CGRect(x: 0, y: y, width: pw, height: ph)
                                  : CGRect(x: right + gapX, y: y, width: pw, height: ph)
                d.packages.append(r)
                for k in 0..<perPackage {
                    let ly = r.minY + r.height * (0.1 + 0.8 * CGFloat(k) / CGFloat(perPackage - 1))
                    guard onDie(ly) else { continue }
                    d.traces.append(side == 0
                        ? Trace(from: CGPoint(x: left, y: ly), to: CGPoint(x: r.maxX, y: ly))
                        : Trace(from: CGPoint(x: right, y: ly), to: CGPoint(x: r.minX, y: ly)))
                }
            }
        }
        d.size = CGSize(width: right + gapX + pw, height: stackH)
    }

    // MARK: - Placement helpers

    /// Splits each tier's clusters between two dies, first half to the first die.
    private static func halve(_ tiers: [[CoreCluster]]) -> [([CoreCluster], [CoreCluster])] {
        tiers.map { clusters in
            let cut = (clusters.count + 1) / 2
            return (Array(clusters.prefix(cut)), Array(clusters.dropFirst(cut)))
        }
    }

    /// Assigns each tier to an area. With more tiers than areas (M6: Super + Performance +
    /// Efficiency), the faster tiers share the first, largest area, weighted toward the
    /// bigger cores. Spare areas become filler. Every tier but the slowest uses the large
    /// pipeline core drawing.
    private static func placeTiers(_ tiers: [[CoreCluster]], areas: [CGRect]) -> [DieBlock] {
        var tierAreas: [CGRect]
        var blocks: [DieBlock] = []
        if tiers.count <= areas.count {
            tierAreas = Array(areas.prefix(tiers.count))
            blocks += areas.dropFirst(tiers.count).map { DieBlock(rect: $0, kind: .filler) }
        } else {
            let shared = tiers.count - areas.count + 1
            let weights = (0..<shared).map { i -> CGFloat in
                let cores = CGFloat(max(1, tiers[i].reduce(0) { $0 + $1.cpus.count }))
                return cores * (1 + 0.6 * CGFloat(shared - 1 - i))
            }
            tierAreas = splitWeighted(areas[0], weights: weights) + Array(areas.dropFirst())
        }
        for (ti, clusters) in tiers.enumerated() {
            let big = tiers.count > 1 && ti < tiers.count - 1
            blocks += placeClusters(clusters, in: tierAreas[ti], tier: ti, big: big)
        }
        return blocks
    }

    private static func splitWeighted(_ r: CGRect, weights: [CGFloat]) -> [CGRect] {
        let total = max(weights.reduce(0, +), 0.001)
        let horizontal = r.width >= r.height * 0.8
        let span = (horizontal ? r.width : r.height) - gap * CGFloat(weights.count - 1)
        var cursor = horizontal ? r.minX : r.minY
        return weights.map { w in
            let share = span * w / total
            defer { cursor += share + gap }
            return horizontal
                ? CGRect(x: cursor, y: r.minY, width: share, height: r.height)
                : CGRect(x: r.minX, y: cursor, width: r.width, height: share)
        }
    }

    /// Splits a tier area between its clusters (proportional to core count); each cluster
    /// gets a shared-cache strip on top and a grid of cores below.
    private static func placeClusters(_ clusters: [CoreCluster], in area: CGRect, tier: Int, big: Bool) -> [DieBlock] {
        guard !clusters.isEmpty else { return [DieBlock(rect: area, kind: .filler)] }
        let total = max(1, clusters.reduce(0) { $0 + $1.cpus.count })
        let horizontal = area.width >= area.height * 0.8
        let span = (horizontal ? area.width : area.height) - gap * CGFloat(clusters.count - 1)
        var cursor = horizontal ? area.minX : area.minY
        var blocks: [DieBlock] = []

        for c in clusters {
            let share = span * CGFloat(c.cpus.count) / CGFloat(total)
            let cr = horizontal
                ? CGRect(x: cursor, y: area.minY, width: share, height: area.height)
                : CGRect(x: area.minX, y: cursor, width: area.width, height: share)
            cursor += share + gap

            let stripH = max(0.012, cr.height * (big ? 0.085 : 0.16))
            blocks.append(DieBlock(rect: CGRect(x: cr.minX, y: cr.minY, width: cr.width, height: stripH),
                                   kind: .clusterCache(cpus: c.cpus)))
            let coresRect = CGRect(x: cr.minX, y: cr.minY + stripH + gap,
                                   width: cr.width, height: cr.height - stripH - gap)
            let n = c.cpus.count
            let (cols, rows) = bestGrid(n, in: coresRect, target: big ? 0.42 : 1.0)
            for (i, cell) in grid(coresRect, cols: cols, rows: rows).enumerated() {
                blocks.append(DieBlock(rect: cell, kind: i < n ? .core(cpu: c.cpus[i], tier: tier) : .filler))
            }
        }
        return blocks
    }

    /// Picks the grid whose cells come closest to the target aspect (w/h), penalising empty cells.
    static func bestGrid(_ n: Int, in r: CGRect, target: CGFloat) -> (Int, Int) {
        guard n > 0 else { return (1, 1) }
        var best = (n, 1)
        var bestScore = Double.infinity
        for rows in 1...n {
            let cols = (n + rows - 1) / rows
            if (rows - 1) * cols >= n { continue }       // would leave a whole row empty
            let w = (r.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (r.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let score = abs(log(Double(w / h / target))) + 0.25 * Double(cols * rows - n)
            if score < bestScore { bestScore = score; best = (cols, rows) }
        }
        return best
    }

    static func grid(_ r: CGRect, cols: Int, rows: Int) -> [CGRect] {
        let cw = (r.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (r.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var out: [CGRect] = []
        for j in 0..<rows {
            for i in 0..<cols {
                out.append(CGRect(x: r.minX + CGFloat(i) * (cw + gap),
                                  y: r.minY + CGFloat(j) * (ch + gap),
                                  width: cw, height: ch))
            }
        }
        return out
    }

    /// The second die of an Ultra is the first turned 180°.
    private static func rotated(_ block: DieBlock, in die: CGRect) -> DieBlock {
        var b = block
        b.rect.origin.x = die.minX + (die.maxX - block.rect.maxX)
        b.rect.origin.y = die.minY + (die.maxY - block.rect.maxY)
        return b
    }
}
