//
//  Simulate.swift
//  `SiliconMeter --simulate <dir>` runs the app's own detection, layout and rendering code
//  for every Apple Silicon Mac configuration, M1 through M6, and writes the results:
//
//    <dir>/chips.json        detected tiers/clusters and the full die drawing per chip
//    <dir>/icons/<id>.png    the menu bar icon (template, black on transparent, 4×)
//    <dir>/snaps/<id>.png    the popover rendered offscreen with a fixed sample load
//    <dir>/snaps/<id>_simple.png    the same in Simple mode
//
//  Only the inputs are simulated: what sysctl (perf levels) and the device tree (cpuN
//  cluster types and ids) would report on that chip. Everything after that is the same
//  code path the menu bar app runs: ChipInfo.make → ChipLayout.build → DieRenderer.
//
//  Cluster splits of binned parts (e.g. 5+5 performance cores on a 14-core M4 Pro) follow
//  the full die with cores disabled per cluster; Apple does not publish these.
//
import AppKit
import SwiftUI

struct SimSpec {
    let id: String
    let brand: String
    let config: String
    let year: Int
    let levels: [(String, Int)]      // perf levels, fastest first, as hw.perflevelN reports
    let clusters: [(String, Int)]    // device-tree order: (cluster-type, core count)
    let gpu: Int
    let memoryGB: Int

    var cpuCount: Int { clusters.reduce(0) { $0 + $1.1 } }

    /// M1–M4: Performance + Efficiency. Per die, efficiency clusters enumerate first.
    static func classic(_ brand: String, _ year: Int, e: [Int], p: [Int], dies: Int = 1,
                        gpu: Int, mem: Int) -> SimSpec {
        let perDie = e.map { ("E", $0) } + p.map { ("P", $0) }
        let clusters = Array(repeating: perDie, count: dies).flatMap { $0 }
        return make(brand, year, levels: [("Performance", p.reduce(0, +) * dies),
                                          ("Efficiency", e.reduce(0, +) * dies)],
                    clusters: clusters, gpu: gpu, mem: mem)
    }

    /// M5 base: Super ("P" clusters) + Efficiency.
    static func superEff(_ brand: String, _ year: Int, s: Int, e: Int, gpu: Int, mem: Int) -> SimSpec {
        make(brand, year, levels: [("Super", s), ("Efficiency", e)],
             clusters: [("E", e), ("P", s)], gpu: gpu, mem: mem)
    }

    /// M5 Pro / Max / Ultra: Super ("P") + Performance ("M"), no efficiency cores.
    static func superPerf(_ brand: String, _ year: Int, s: Int, m: [Int], dies: Int = 1,
                          gpu: Int, mem: Int) -> SimSpec {
        let perDie = m.map { ("M", $0) } + [("P", s)]
        let clusters = Array(repeating: perDie, count: dies).flatMap { $0 }
        return make(brand, year, levels: [("Super", s * dies), ("Performance", m.reduce(0, +) * dies)],
                    clusters: clusters, gpu: gpu, mem: mem)
    }

    static func make(_ brand: String, _ year: Int, levels: [(String, Int)], clusters: [(String, Int)],
                     gpu: Int, mem: Int) -> SimSpec {
        let cpus = clusters.reduce(0) { $0 + $1.1 }
        let short = brand.replacingOccurrences(of: "Apple ", with: "")
        let id = short.lowercased().replacingOccurrences(of: " ", with: "-") + "-\(cpus)c-\(gpu)g"
        return SimSpec(id: id, brand: brand, config: "\(cpus)-core CPU · \(gpu)-core GPU", year: year,
                       levels: levels, clusters: clusters, gpu: gpu, memoryGB: mem)
    }

    /// Every Mac configuration of each chip, M1 (2020) through M6 (2026), plus the A18 Pro.
    static let all: [SimSpec] = [
        classic("Apple M1", 2020, e: [4], p: [4], gpu: 7, mem: 8),
        classic("Apple M1", 2020, e: [4], p: [4], gpu: 8, mem: 16),
        classic("Apple M1 Pro", 2021, e: [2], p: [3, 3], gpu: 14, mem: 16),
        classic("Apple M1 Pro", 2021, e: [2], p: [4, 4], gpu: 16, mem: 32),
        classic("Apple M1 Max", 2021, e: [2], p: [4, 4], gpu: 24, mem: 32),
        classic("Apple M1 Max", 2021, e: [2], p: [4, 4], gpu: 32, mem: 64),
        classic("Apple M1 Ultra", 2022, e: [2], p: [4, 4], dies: 2, gpu: 48, mem: 64),
        classic("Apple M1 Ultra", 2022, e: [2], p: [4, 4], dies: 2, gpu: 64, mem: 128),

        classic("Apple M2", 2022, e: [4], p: [4], gpu: 8, mem: 8),
        classic("Apple M2", 2022, e: [4], p: [4], gpu: 10, mem: 16),
        classic("Apple M2 Pro", 2023, e: [4], p: [3, 3], gpu: 16, mem: 16),
        classic("Apple M2 Pro", 2023, e: [4], p: [4, 4], gpu: 19, mem: 32),
        classic("Apple M2 Max", 2023, e: [4], p: [4, 4], gpu: 30, mem: 32),
        classic("Apple M2 Max", 2023, e: [4], p: [4, 4], gpu: 38, mem: 96),
        classic("Apple M2 Ultra", 2023, e: [4], p: [4, 4], dies: 2, gpu: 60, mem: 64),
        classic("Apple M2 Ultra", 2023, e: [4], p: [4, 4], dies: 2, gpu: 76, mem: 192),

        classic("Apple M3", 2023, e: [4], p: [4], gpu: 8, mem: 8),
        classic("Apple M3", 2023, e: [4], p: [4], gpu: 10, mem: 16),
        classic("Apple M3 Pro", 2023, e: [6], p: [5], gpu: 14, mem: 18),
        classic("Apple M3 Pro", 2023, e: [6], p: [6], gpu: 18, mem: 36),
        classic("Apple M3 Max", 2023, e: [4], p: [5, 5], gpu: 30, mem: 36),
        classic("Apple M3 Max", 2023, e: [4], p: [6, 6], gpu: 40, mem: 48),
        classic("Apple M3 Ultra", 2025, e: [4], p: [5, 5], dies: 2, gpu: 60, mem: 96),
        classic("Apple M3 Ultra", 2025, e: [4], p: [6, 6], dies: 2, gpu: 80, mem: 512),

        classic("Apple M4", 2024, e: [4], p: [4], gpu: 8, mem: 16),
        classic("Apple M4", 2024, e: [6], p: [4], gpu: 8, mem: 16),
        classic("Apple M4", 2024, e: [6], p: [4], gpu: 10, mem: 24),
        classic("Apple M4 Pro", 2024, e: [4], p: [4, 4], gpu: 16, mem: 24),
        classic("Apple M4 Pro", 2024, e: [4], p: [5, 5], gpu: 20, mem: 48),
        classic("Apple M4 Max", 2024, e: [4], p: [5, 5], gpu: 32, mem: 36),
        classic("Apple M4 Max", 2024, e: [4], p: [6, 6], gpu: 40, mem: 128),

        superEff("Apple M5", 2025, s: 4, e: 6, gpu: 8, mem: 16),
        superEff("Apple M5", 2025, s: 4, e: 6, gpu: 10, mem: 24),
        superPerf("Apple M5 Pro", 2026, s: 5, m: [5, 5], gpu: 16, mem: 24),
        superPerf("Apple M5 Pro", 2026, s: 6, m: [6, 6], gpu: 20, mem: 48),
        superPerf("Apple M5 Max", 2026, s: 6, m: [6, 6], gpu: 32, mem: 36),
        superPerf("Apple M5 Max", 2026, s: 6, m: [6, 6], gpu: 40, mem: 128),
        superPerf("Apple M5 Ultra", 2026, s: 5, m: [5, 5], dies: 2, gpu: 64, mem: 96),
        superPerf("Apple M5 Ultra", 2026, s: 6, m: [6, 6], dies: 2, gpu: 80, mem: 512),

        make("Apple M6", 2026, levels: [("Super", 2), ("Performance", 4), ("Efficiency", 6)],
             clusters: [("E", 6), ("M", 4), ("P", 2)], gpu: 12, mem: 16),

        // MacBook Neo (March 2026): the first Mac with an A-series chip.
        classic("Apple A18 Pro", 2026, e: [4], p: [2], gpu: 5, mem: 8),
    ]

    /// Inputs exactly as ChipInfo.detect() would collect them on that Mac.
    func chipInfo() -> ChipInfo {
        var map: [CPUClusterEntry] = []
        var cpu = 0
        for (cid, cluster) in clusters.enumerated() {
            for _ in 0..<cluster.1 {
                map.append(CPUClusterEntry(cpuIndex: cpu, clusterID: cid, clusterType: cluster.0))
                cpu += 1
            }
        }
        let perf = levels.enumerated().map { PerfLevel(index: $0.offset, name: $0.element.0, logicalCPUs: $0.element.1) }
        return ChipInfo.make(brand: brand, levels: perf, map: map, cpuCount: cpuCount, gpuCores: gpu,
                             memoryBytes: UInt64(memoryGB) << 30, gpuFreqsMHz: [])
    }
}

enum Simulate {
    /// Per-core loads of the sample scenario, repeating by CPU index.
    static let samplePattern: [Double] = [0.95, 0.70, 0.40, 0.15, 0.0, 0.05, 0.60, 0.25]

    static func sampleSnapshot(for chip: ChipInfo) -> Snapshot {
        var s = Snapshot()
        s.cores = (0..<chip.cpuCount).map { samplePattern[$0 % samplePattern.count] }
        s.gpu = 0.45
        s.gpuMHz = nil
        s.ane = 0.3
        s.aneEstimated = true
        s.aneTraffic = 4.2
        s.valid = true
        let total = Double(chip.memoryBytes)
        s.memory.total = total
        s.memory.wired = total * 0.12
        s.memory.app = total * 0.38
        s.memory.compressed = total * 0.06
        s.memory.cached = total * 0.25
        s.memory.pressure = .normal
        return s
    }

    @MainActor
    static func run(outDir: String) {
        _ = NSApplication.shared       // fonts and AppKit drawing for offscreen rendering
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir)
        try? fm.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("snaps"), withIntermediateDirectories: true)

        var entries: [[String: Any]] = []
        var failures = 0
        for spec in SimSpec.all {
            let chip = spec.chipInfo()
            let drawing = ChipLayout.build(for: chip)
            let snap = sampleSnapshot(for: chip)

            var entry = encode(spec: spec, chip: chip, drawing: drawing, snap: snap)

            // Menu bar icons as the screen draws them: 1× (external displays) and 2× (Retina).
            for scale in [1, 2] {
                try? fm.createDirectory(at: root.appendingPathComponent("icons\(scale)x"), withIntermediateDirectories: true)
                if let png = iconPNG(MenuBarIcon.make(for: chip), scale: CGFloat(scale)) {
                    try? png.write(to: root.appendingPathComponent("icons\(scale)x/\(spec.id).png"))
                }
            }
            if let png = iconPNG(MenuBarIcon.make(for: chip)) {
                try? png.write(to: root.appendingPathComponent("icons/\(spec.id).png"))
                entry["icon"] = "icons/\(spec.id).png"
            } else { failures += 1 }

            if let png = popoverPNG(chip: chip, drawing: drawing, snap: snap) {
                try? png.write(to: root.appendingPathComponent("snaps/\(spec.id).png"))
                entry["snapshot"] = "snaps/\(spec.id).png"
            }
            if let png = simplePNG(chip: chip, drawing: drawing, snap: snap) {
                try? png.write(to: root.appendingPathComponent("snaps/\(spec.id)_simple.png"))
                entry["simpleSnapshot"] = "snaps/\(spec.id)_simple.png"
            } else { failures += 1 }

            entries.append(entry)
            let tiers = chip.tiers.map { "\($0.cpuCount) \($0.name)" }.joined(separator: " + ")
            let name = "\(spec.brand) \(spec.cpuCount)C/\(spec.gpu)G"
            print(name.padding(toLength: 28, withPad: " ", startingAt: 0)
                  + chip.archetype.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0) + tiers)
        }

        let doc: [String: Any] = [
            "generatedBy": "SiliconMeter --simulate",
            "samplePattern": samplePattern,
            "sampleTime": 1.25,
            "chips": entries,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("chips.json"))
        }
        print("\n\(entries.count) chips written to \(root.path)" + (failures > 0 ? " (\(failures) images failed)" : ""))
        verifyLayers()
    }

    /// Checks that drawing from pre-rendered layers (the live popover) gives the same picture
    /// as drawing everything (snapshots): renders every chip both ways and compares pixels.
    @MainActor
    static func verifyLayers() {
        var worst = (diff: 0.0, id: "")
        var failed = 0
        for spec in SimSpec.all {
            let chip = spec.chipInfo()
            let drawing = ChipLayout.build(for: chip)
            let anim = AnimState()
            anim.jump(to: sampleSnapshot(for: chip))
            anim.settle(at: 1.25)
            let size = PopoverView.canvasSize(for: drawing)
            let renderer = DieRenderer(drawing: drawing, chip: chip)
            let cache = DieLayerCache()
            _ = cache.layers(for: renderer, size: size, scale: 2, state: anim)
            guard let layers = cache.layers(for: renderer, size: size, scale: 2, state: anim) else { failed += 1; continue }
            func image(_ l: DieLayers?) -> CGImage? {
                let r = ImageRenderer(content: Canvas { ctx, sz in
                    renderer.render(ctx, size: sz, state: anim, time: 1.25, layers: l)
                }.frame(width: size.width, height: size.height).background(Color.black))
                r.scale = 2
                return r.cgImage
            }
            guard let a = image(nil), let b = image(layers), let d = meanDifference(a, b) else { failed += 1; continue }
            if d > worst.diff { worst = (d, spec.id) }
        }
        print(String(format: "layers check: mean pixel difference worst %.4f (%@)%@", worst.diff, worst.id,
                     failed > 0 ? ", \(failed) failed" : ""))
    }

    private static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height,
              let pa = pixels(a), let pb = pixels(b) else { return nil }
        var total = 0.0
        for i in 0..<pa.count { total += abs(Double(pa[i]) - Double(pb[i])) }
        return total / Double(pa.count) / 255
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    // MARK: - JSON

    private static func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
    private static func r(_ v: CGFloat) -> Double { (Double(v) * 100_000).rounded() / 100_000 }
    private static func rect(_ c: CGRect) -> [Double] { [r(c.minX), r(c.minY), r(c.width), r(c.height)] }

    private static func encode(spec: SimSpec, chip: ChipInfo, drawing: ChipDrawing, snap: Snapshot) -> [String: Any] {
        let blocks: [[String: Any]] = drawing.blocks.map { b in
            var o: [String: Any] = ["r": rect(b.rect)]
            switch b.kind {
            case let .core(cpu, tier): o["k"] = "core"; o["cpu"] = cpu; o["tier"] = tier
            case let .clusterCache(cpus): o["k"] = "l2"; o["cpus"] = cpus
            case let .tierCache(tier): o["k"] = "cache"; o["tier"] = tier
            case let .gpuCore(i): o["k"] = "gpu"; o["i"] = i
            case let .npuCore(i): o["k"] = "npu"; o["i"] = i
            case let .slc(i): o["k"] = "slc"; o["i"] = i
            case .misc: o["k"] = "misc"
            case .filler: o["k"] = "filler"
            case let .logo(title, tag): o["k"] = "logo"; o["title"] = title; o["tag"] = opt(tag)
            }
            return o
        }
        let canvas = PopoverView.canvasSize(for: drawing)
        let content = PopoverView.contentSize(for: drawing, tiers: chip.tiers.count)
        let simple = PopoverMetrics.simple(for: drawing, tiers: chip.tiers.count)
        return [
            "id": spec.id,
            "brand": spec.brand,
            "config": spec.config,
            "year": spec.year,
            "input": [
                "perfLevels": spec.levels.map { ["name": $0.0, "cpus": $0.1] as [String: Any] },
                "deviceTree": spec.clusters.map { ["type": $0.0, "cpus": $0.1] as [String: Any] },
            ] as [String: Any],
            "chip": [
                "family": chip.family,
                "series": chip.series.rawValue,
                "generation": opt(chip.generation),
                "variant": chip.variant.rawValue,
                "archetype": chip.archetype.rawValue,
                "tag": opt(chip.tag),
                "cpuCount": chip.cpuCount,
                "gpuCores": chip.gpuCores,
                "npuCores": chip.npuCores,
                "memoryGB": spec.memoryGB,
                "mapSource": chip.mapSource,
                "tiers": chip.tiers.map { ["index": $0.index, "name": $0.name, "cpus": $0.cpuCount] as [String: Any] },
                "clusters": chip.clusters.map { ["id": $0.id, "tier": $0.tier, "cpus": $0.cpus] as [String: Any] },
            ] as [String: Any],
            "drawing": [
                "size": [r(drawing.size.width), r(drawing.size.height)],
                "dies": drawing.dies.map(rect),
                "packages": drawing.packages.map(rect),
                "traces": drawing.traces.map { [r($0.from.x), r($0.from.y), r($0.to.x), r($0.to.y)] },
                "bridges": drawing.bridges.map { ["r": rect($0.rect), "kind": $0.kind.rawValue] as [String: Any] },
                "bandwidth": drawing.bandwidth,
                "bandwidthKnown": drawing.bandwidthKnown,
                "pulsesPerLane": drawing.pulsesPerLane,
                "blocks": blocks,
            ] as [String: Any],
            "palette": paletteJSON(ChipCatalog.palette(chip)),
            "popover": [
                "canvas": [r(canvas.width), r(canvas.height)],
                "content": [r(content.width), r(content.height)],
                "panelWidth": r(PopoverView.panelWidth),
                "spacing": r(PopoverView.spacing),
                "margin": r(PopoverView.margin),
                "simpleCanvas": [r(simple.canvas.width), r(simple.canvas.height)],
                "simpleContent": [r(simple.content.width), r(simple.content.height)],
            ] as [String: Any],
            "sample": [
                "cores": snap.cores,
                "gpu": snap.gpu,
                "ane": opt(snap.ane),
                "aneEstimated": snap.aneEstimated,
                "aneTraffic": opt(snap.aneTraffic),
                "memory": [
                    "total": snap.memory.total, "wired": snap.memory.wired, "app": snap.memory.app,
                    "compressed": snap.memory.compressed, "cached": snap.memory.cached,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func paletteJSON(_ p: ChipPalette) -> [String: Any] {
        [
            "stops": p.stops.map { ["color": $0.0.hex, "at": $0.1] as [String: Any] },
            "start": [r(p.start.x), r(p.start.y)],
            "end": [r(p.end.x), r(p.end.y)],
            "spark": p.spark.hex,
            "ink": p.ink.hex,
            "accent": p.accent.hex,
        ]
    }

    // MARK: - Images

    private static func iconPNG(_ image: NSImage, scale: CGFloat = 4) -> Data? {
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    private static func popoverPNG(chip: ChipInfo, drawing: ChipDrawing, snap: Snapshot) -> Data? {
        let anim = AnimState()
        anim.jump(to: snap)
        anim.settle(at: 1.25)
        let canvas = PopoverView.canvasSize(for: drawing)
        let content = PopoverView.contentSize(for: drawing, tiers: chip.tiers.count)
        let view = HStack(alignment: .center, spacing: PopoverView.spacing) {
            SpecPanel(chip: chip, snapshot: snap, login: LoginItem())
                .frame(width: PopoverView.panelWidth)
                .frame(maxHeight: .infinity)
            Canvas { context, size in
                DieRenderer(drawing: drawing, chip: chip).render(context, size: size, state: anim, time: 1.25)
            }
            .frame(width: canvas.width, height: canvas.height)
        }
        .padding(PopoverView.margin)
        .frame(width: content.width, height: content.height)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    @MainActor
    private static func simplePNG(chip: ChipInfo, drawing: ChipDrawing, snap: Snapshot) -> Data? {
        let anim = AnimState()
        anim.jump(to: snap)
        anim.settle(at: 1.25)
        let m = PopoverMetrics.simple(for: drawing, tiers: chip.tiers.count)
        let prefs = Preferences(persist: false)
        prefs.simple = true
        let view = HStack(alignment: .center, spacing: m.spacing) {
            SimplePanel(chip: chip, snapshot: snap, prefs: prefs)
                .frame(width: m.panelWidth)
                .frame(maxHeight: .infinity)
            Canvas { context, size in
                DieRenderer(drawing: drawing, chip: chip).render(context, size: size, state: anim, time: 1.25)
            }
            .frame(width: m.canvas.width, height: m.canvas.height)
        }
        .padding(m.margin)
        .frame(width: m.content.width, height: m.content.height)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
