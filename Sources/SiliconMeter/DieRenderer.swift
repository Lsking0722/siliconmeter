//
//  DieRenderer.swift
//  Draws a ChipDrawing into a SwiftUI Canvas, every frame, from smoothed live values.
//
//  Look: the die is a gradient-filled slab (mint → teal → petrol); every block is an ink
//  rectangle cut into it, so the silicon shows through as glowing lines. Idle blocks keep
//  only faint inner detail; working blocks light up in proportion to their load.
//
//  What is measured vs. staged:
//  - CPU cores: each core's own measured load.
//  - GPU cores: macOS reports one utilization for the whole GPU. Every core shows that
//    value with a fixed per-core bias; cells light in a stable order as load rises.
//  - Neural Engine: measured activity when IOReport reports it, otherwise dim.
//  - Memory packages: the measured breakdown (wired / app / compressed / cached / free).
//  - Wires and bridges: pulse speed follows overall activity; bandwidth is not measured.
//
import AppKit
import CoreText
import SwiftUI

enum Theme {
    static let ink = Color(red: 0.010, green: 0.022, blue: 0.026)
    static let mint = Color(red: 0.62, green: 0.89, blue: 0.80)
    static let teal = Color(red: 0.13, green: 0.68, blue: 0.69)
    static let petrol = Color(red: 0.04, green: 0.40, blue: 0.53)
    static let spark = Color(red: 0.86, green: 1.0, blue: 0.96)
    static let text = Color(white: 0.95)
    /// Labels and units. Brighter when "Increase contrast" is on (the system then gives views
    /// a high-contrast appearance), since the popover's glass lets the desktop through.
    static let secondary = Color(nsColor: NSColor(name: "SiliconMeterSecondary") { appearance in
        highContrast(appearance)
            ? NSColor(red: 0.78, green: 0.82, blue: 0.83, alpha: 1)
            : NSColor(red: 0.55, green: 0.60, blue: 0.61, alpha: 1)
    })

    static func highContrast(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua,
                                                .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
        return match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
    }
    static let warning = Color(red: 0.96, green: 0.76, blue: 0.31)
    static let critical = Color(red: 1.0, green: 0.42, blue: 0.37)

    static let gradient = Gradient(stops: [
        .init(color: mint, location: 0),
        .init(color: teal, location: 0.45),
        .init(color: petrol, location: 1),
    ])
}

/// Smoothed values the renderer draws from. Lives across frames; eased toward each new
/// snapshot so a once-a-second sample still animates continuously.
final class AnimState {
    var cores: [Double] = []
    var gpu = 0.0
    var ane = 0.0
    var aneKnown = false
    var wired = 0.0, app = 0.0, compressed = 0.0, cached = 0.0
    var pressure: Pressure = .normal
    private var lastTime: Double?

    // Phases advanced by elapsed time × the current rate, so a rate change only changes how
    // fast things move from where they are. (Phase = time × rate would jump whenever the
    // load changed, which made the scan lines dart around even at low load.)
    var scan: [Double] = []         // CPU scan line position per core, 0..<1
    var pulse: [Double] = []        // efficiency-core pulse angle per core, radians
    var trafficClock = 0.0          // memory lanes
    var fusionClock = 0.0           // Fusion bridge
    var ultraClock = 0.0            // UltraFusion
    var sweepClock = 0.0            // GPU dispatch sweep

    static func scanRate(_ load: Double) -> Double { 0.12 + 1.1 * load }      // sweeps per second
    static func pulseRate(_ load: Double) -> Double { 1.5 + 6 * load }        // radians per second
    static func sweepRate(_ gpu: Double) -> Double { 1 / (3.2 - 1.6 * gpu) }

    var traffic: Double { min(1, 0.5 * cpuAverage + 0.7 * gpu + 0.4 * ane) }

    private func seedPhases() {
        scan = cores.indices.map { (Double($0) * 0.173).truncatingRemainder(dividingBy: 1) }
        pulse = cores.indices.map { Double($0) * 0.291 * 6.283 }
    }

    private func advance(_ dt: Double) {
        if scan.count != cores.count { seedPhases() }
        for i in cores.indices {
            scan[i] = (scan[i] + dt * Self.scanRate(load(i))).truncatingRemainder(dividingBy: 1)
            pulse[i] = (pulse[i] + dt * Self.pulseRate(load(i))).truncatingRemainder(dividingBy: 2 * .pi)
        }
        let tr = traffic
        trafficClock += dt * (0.25 + 1.6 * tr)
        fusionClock += dt * (0.3 + 1.4 * tr)
        ultraClock += dt * (0.35 + 1.6 * tr)
        sweepClock += dt * Self.sweepRate(gpu)
    }

    func step(toward s: Snapshot, time: Double) {
        let dt = min(0.25, max(0, time - (lastTime ?? (time - 0.1))))
        lastTime = time
        let k = 1 - exp(-dt * 5)

        if s.valid {
            if cores.count != s.cores.count { cores = s.cores }
            for i in cores.indices { cores[i] += (s.cores[i] - cores[i]) * k }
        }
        // GPU residency swings a lot between 1 s samples (UI bursts), so it eases ~4× slower.
        gpu += (s.gpu - gpu) * (1 - exp(-dt * 1.2))
        aneKnown = s.ane != nil
        ane += ((s.ane ?? 0) - ane) * k

        let total = max(s.memory.total, 1)
        if s.memory.total > 0 {
            wired += (s.memory.wired / total - wired) * k
            app += (s.memory.app / total - app) * k
            compressed += (s.memory.compressed / total - compressed) * k
            cached += (s.memory.cached / total - cached) * k
        }
        pressure = s.memory.pressure
        advance(dt)
    }

    /// Sets every value at once (offscreen snapshots, which draw a single frame).
    func jump(to s: Snapshot) {
        cores = s.cores
        gpu = s.gpu
        aneKnown = s.ane != nil
        ane = s.ane ?? 0
        let total = max(s.memory.total, 1)
        wired = s.memory.wired / total
        app = s.memory.app / total
        compressed = s.memory.compressed / total
        cached = s.memory.cached / total
        pressure = s.memory.pressure
    }

    /// Phases as if the current rates had held for `time` seconds (offscreen snapshots).
    func settle(at time: Double) {
        seedPhases()
        for i in cores.indices {
            scan[i] = (scan[i] + time * Self.scanRate(load(i))).truncatingRemainder(dividingBy: 1)
            pulse[i] = pulse[i] + time * Self.pulseRate(load(i))
        }
        let tr = traffic
        trafficClock = time * (0.25 + 1.6 * tr)
        fusionClock = time * (0.3 + 1.4 * tr)
        ultraClock = time * (0.35 + 1.6 * tr)
        sweepClock = time * Self.sweepRate(gpu)
    }

    func load(_ cpu: Int) -> Double {
        cpu >= 0 && cpu < cores.count ? min(1, max(0, cores[cpu])) : 0
    }

    func average(_ cpus: [Int]) -> Double {
        guard !cpus.isEmpty else { return 0 }
        return cpus.reduce(0) { $0 + load($1) } / Double(cpus.count)
    }

    /// Fixed geometry built once per rectangle (interposer fields).
    private var shapes: [String: Any] = [:]
    func cached<T>(_ key: String, make: () -> T) -> T {
        if let v = shapes[key] as? T { return v }
        if shapes.count > 32 { shapes.removeAll() }
        let v = make()
        shapes[key] = v
        return v
    }

    /// Chip-name outlines per block rectangle (built once; see DieRenderer.logo).
    private var logoPaths: [String: Path] = [:]
    func logoPath(title: String, tag: String?, in r: CGRect, make: () -> Path) -> Path {
        let key = "\(title)|\(tag ?? "")|\(r.minX),\(r.minY),\(r.width),\(r.height)"
        if let p = logoPaths[key] { return p }
        if logoPaths.count > 16 { logoPaths.removeAll() }      // sizes change only on resize
        let p = make()
        logoPaths[key] = p
        return p
    }

    /// Fixed scrambled order in which a GPU core's cells light up (cached; it never changes).
    private var gpuOrders: [Int: [Int]] = [:]
    func gpuOrder(_ index: Int, cells n: Int) -> [Int] {
        if let o = gpuOrders[index], o.count == n { return o }
        let o = (0..<n).sorted { hash01($0 * 31 + index * 7) < hash01($1 * 31 + index * 7) }
        gpuOrders[index] = o
        return o
    }

    var cpuAverage: Double {
        cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
    }
}

/// Collects the many small metal-shaded fills and strokes of one frame and draws them in a
/// few calls: one per opacity step (1/32) and line width. Everything inside a die is shaded
/// with the same gradient, and "over" with one colour is order-independent, so batching does
/// not change the picture.
///
/// The batches are drawn in plain white into an offscreen layer, and the gradient is laid
/// over that layer once (source-atop keeps each pixel's coverage and takes the gradient's
/// colour). Solid fills only touch the pixels they cover; gradient fills shade their whole
/// bounding box, which for a batch spanning the die meant shading every pixel dozens of
/// times a frame.
final class MetalBatch {
    private static let steps = 32.0
    private struct Key: Hashable { let level: Int; let width: Int }
    private var fills: [Int: Path] = [:]
    private var strokes: [Key: Path] = [:]
    private var sparks: [Key: Path] = [:]

    private static func level(_ alpha: Double) -> Int { Int((min(1, max(0, alpha)) * steps).rounded()) }

    func fill(_ path: Path, _ alpha: Double) {
        let l = Self.level(alpha)
        guard l > 0 else { return }
        fills[l, default: Path()].addPath(path)
    }

    func stroke(_ path: Path, _ alpha: Double, width: CGFloat) {
        let l = Self.level(alpha)
        guard l > 0 else { return }
        strokes[Key(level: l, width: Int((width * 100).rounded())), default: Path()].addPath(path)
    }

    /// Bright accent lines (scan lines, GPU sweeps); drawn after all the metal.
    func spark(_ path: Path, _ alpha: Double, width: CGFloat) {
        let l = Self.level(alpha)
        guard l > 0 else { return }
        sparks[Key(level: l, width: Int((width * 100).rounded())), default: Path()].addPath(path)
    }

    /// `metalImage`: the die gradient pre-rendered for this size (DieLayers); without it the
    /// gradient is computed here.
    func flush(_ ctx: GraphicsContext, metal: GraphicsContext.Shading, metalImage: Image? = nil,
               bounds: CGRect, spark: Color) {
        let fills = self.fills, strokes = self.strokes
        if let metalImage {
            // Pre-rendered gradient: paint with it directly (image shading, no offscreen pass).
            let shading = GraphicsContext.Shading.tiledImage(metalImage, origin: .zero,
                                                             sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1)
            var c = ctx
            for (l, path) in fills {
                c.opacity = Double(l) / Self.steps
                c.fill(path, with: shading)
            }
            for (key, path) in strokes {
                c.opacity = Double(key.level) / Self.steps
                c.stroke(path, with: shading, lineWidth: CGFloat(key.width) / 100)
            }
        } else if !fills.isEmpty || !strokes.isEmpty { ctx.drawLayer { layer in
            var c = layer
            for (l, path) in fills {
                c.opacity = Double(l) / Self.steps
                c.fill(path, with: .color(.white))
            }
            for (key, path) in strokes {
                c.opacity = Double(key.level) / Self.steps
                c.stroke(path, with: .color(.white), lineWidth: CGFloat(key.width) / 100)
            }
            c.opacity = 1
            c.blendMode = .sourceAtop
            c.fill(Path(bounds), with: metal)
        } }
        var c = ctx
        for (key, path) in sparks {
            c.opacity = Double(key.level) / Self.steps
            c.stroke(path, with: .color(spark), lineWidth: CGFloat(key.width) / 100)
        }
        self.fills.removeAll(keepingCapacity: true)
        self.strokes.removeAll(keepingCapacity: true)
        sparks.removeAll(keepingCapacity: true)
    }
}

/// What one call draws. The base is everything that never moves (slabs, ink, idle detail,
/// names, wires, interposer metal, package frames); it is rendered once per size into an
/// image (DieLayers). Live is only what changes: load-driven fills and the extra opacity
/// above the base, pulses, scan lines, glitter, memory cells.
enum DiePass { case base, live }

struct DieRenderer {
    let drawing: ChipDrawing
    let chip: ChipInfo

    /// Draws a frame. With pre-rendered `layers` for this size, the base is one image and only
    /// the live pass is computed; without (offscreen snapshots, or while the popover is
    /// resizing), both passes are drawn, which gives the same picture.
    func render(_ ctx: GraphicsContext, size: CGSize, state: AnimState, time t: Double, layers: DieLayers? = nil) {
        if let layers, layers.matches(size) {
            ctx.draw(layers.base, in: CGRect(origin: .zero, size: size))
            draw(.live, ctx, size: size, state: state, time: t, layers: layers)
        } else {
            draw(.base, ctx, size: size, state: state, time: t, layers: nil)
            draw(.live, ctx, size: size, state: state, time: t, layers: nil)
        }
    }

    /// The base pass alone (for DieLayers).
    func renderBase(_ ctx: GraphicsContext, size: CGSize, state: AnimState) {
        draw(.base, ctx, size: size, state: state, time: 0, layers: nil)
    }

    struct Geometry {
        let s: CGFloat, ox: CGFloat, oy: CGFloat, W: CGFloat, H: CGFloat
        func R(_ r: CGRect) -> CGRect {
            CGRect(x: ox + r.minX * s, y: oy + r.minY * s, width: r.width * s, height: r.height * s)
        }
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * s, y: oy + p.y * s) }
    }

    func geometry(_ size: CGSize) -> Geometry {
        let pad: CGFloat = 4
        let s = min((size.width - pad * 2) / drawing.size.width,
                    (size.height - pad * 2) / drawing.size.height)
        return Geometry(s: s, ox: (size.width - drawing.size.width * s) / 2,
                        oy: (size.height - drawing.size.height * s) / 2,
                        W: drawing.size.width * s, H: drawing.size.height * s)
    }

    /// Gradient axis of the die metal, in canvas points.
    func metalAxis(_ g: Geometry) -> (CGPoint, CGPoint) {
        let pal = ChipCatalog.palette(chip)
        return (CGPoint(x: g.ox + pal.start.x * g.W, y: g.oy + pal.start.y * g.H),
                CGPoint(x: g.ox + pal.end.x * g.W, y: g.oy + pal.end.y * g.H))
    }

    private func draw(_ pass: DiePass, _ ctx: GraphicsContext, size: CGSize, state: AnimState, time t: Double,
                      layers: DieLayers?) {
        let g = geometry(size)
        let R = g.R, P = g.P
        let pal = ChipCatalog.palette(chip)
        let axis = metalAxis(g)
        let metal = GraphicsContext.Shading.linearGradient(
            Gradient(stops: pal.stops.map { .init(color: $0.0.color, location: CGFloat($0.1)) }),
            startPoint: axis.0, endPoint: axis.1)
        let hair = max(0.6, g.s * 0.0024)
        let traffic = state.traffic
        let base = pass == .base

        let kit = Kit(metal: metal, hair: hair, t: t, ink: pal.ink.color, spark: pal.spark.color, unit: g.s, st: state,
                      batch: MetalBatch(), pass: pass, layers: layers)

        // 1. Wires behind everything: die ↔ memory lanes, then the die-to-die bridges.
        drawTraces(ctx, kit, traffic: traffic, P: P)
        for bridge in drawing.bridges {
            drawInterposer(ctx, kit, R(bridge.rect), traffic: traffic, gold: bridge.kind == .ultraFusion)
        }

        // 2. Silicon slabs, then every block cut into them in one ink pass.
        if base {
            var slabs = Path()
            for die in drawing.dies { slabs.addRect(R(die)) }
            ctx.fill(slabs, with: metal)
            var holes = Path()
            for block in drawing.blocks { holes.addRect(R(block.rect)) }
            ctx.fill(holes, with: .color(kit.ink))
        }

        // 3. Block detail and activity.
        let tierAverages = base ? [] : chip.tiers.map { state.average(chip.cpus(ofTier: $0.index)) }
        for block in drawing.blocks {
            let r = R(block.rect)
            switch block.kind {
            case let .core(cpu, tier):
                let load = state.load(cpu)
                if chip.tiers.count > 1 && tier < chip.tiers.count - 1 {
                    bigCore(ctx, kit, r, load: load, phase: cpu < state.scan.count ? state.scan[cpu] : 0)
                } else {
                    smallCore(ctx, kit, r, load: load, angle: cpu < state.pulse.count ? state.pulse[cpu] : 0)
                }
            case let .clusterCache(cpus):
                hatch(ctx, kit, r, vertical: true, spacing: max(1.8, r.height * 0.45),
                      base: 0.22, alpha: base ? 0.22 : 0.22 + 0.6 * state.average(cpus))
            case let .tierCache(tier):
                let avg = tier < tierAverages.count ? tierAverages[tier] : 0
                cacheArray(ctx, kit, r, alpha: 0.22 + 0.45 * avg)
            case let .gpuCore(i):
                // One measured value for the whole GPU; a fixed per-core bias (±12%) keeps
                // the array from looking uniform without adding motion of its own.
                let bias = 0.88 + 0.24 * hash01(i * 97 + 13)
                gpuCore(ctx, kit, r, load: min(1, state.gpu * bias), index: i)
            case let .npuCore(i):
                npuCore(ctx, kit, r, load: state.aneKnown ? state.ane : nil, index: i)
            case let .slc(i):
                let wave = base ? 0 : pow(max(0, cos(t * 2.2 - Double(i) * 0.7)), 4)
                slcBank(ctx, kit, r, alpha: 0.2 + 0.7 * traffic * wave)
            case .misc:
                if base { miscBlock(ctx, kit, r) }
            case .filler:
                if base { hatch(ctx, kit, r, vertical: false, spacing: max(2, r.height / 6), base: 0.12, alpha: 0.12) }
            case let .logo(title, tag):
                if base { logo(ctx, kit, r, title: title, tag: tag) }
            }
        }

        kit.batch.flush(ctx, metal: metal, metalImage: layers?.metal, bounds: CGRect(origin: .zero, size: size),
                        spark: kit.spark)

        // 4. Unified memory packages.
        drawMemory(ctx, kit, state: state, R: R, bounds: CGRect(origin: .zero, size: size))
    }

    /// Extra opacity that, laid over `base` in the same colour, adds up to `target`.
    private static func extra(_ base: Double, _ target: Double) -> Double {
        target <= base ? 0 : 1 - (1 - target) / (1 - base)
    }

    // MARK: - Drawing kit

    struct Kit {
        let metal: GraphicsContext.Shading
        let hair: CGFloat
        let t: Double
        let ink: Color
        let spark: Color
        let unit: CGFloat       // points per drawing unit (one die width)
        let st: AnimState
        let batch: MetalBatch   // block detail, drawn in a few calls after the loop
        let pass: DiePass
        let layers: DieLayers?
        var base: Bool { pass == .base }
    }

    private func with(_ ctx: GraphicsContext, opacity: Double) -> GraphicsContext {
        var c = ctx
        c.opacity = max(0, min(1, opacity))
        return c
    }

    // MARK: - CPU cores

    /// Top-tier core: two tall pipelines that fill with load, a scan line whose speed follows load.
    private func bigCore(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, load L: Double, phase: Double) {
        let p = max(1.2, r.width * 0.1)
        let band = CGRect(x: r.minX + p, y: r.minY + p, width: r.width - 2 * p, height: r.height * 0.11)
        let colTop = band.maxY + p * 0.8
        let colBottom = r.maxY - p
        let colW = (r.width - 3 * p) / 2
        guard colW > 0, colBottom > colTop else { return }
        let cols = [
            CGRect(x: r.minX + p, y: colTop, width: colW, height: colBottom - colTop),
            CGRect(x: r.minX + 2 * p + colW, y: colTop, width: colW, height: colBottom - colTop),
        ]

        if !k.base {
            if L > 0.65 { k.batch.fill(Path(r), (L - 0.65) * 0.4) }
            if L > 0.005 {
                for c in cols {
                    let h = c.height * CGFloat(L)
                    k.batch.fill(Path(CGRect(x: c.minX, y: c.maxY - h, width: c.width, height: h)), 0.18 + 0.5 * L)
                }
            }
            if L > 0.03 {
                let y = colBottom - CGFloat(phase) * (colBottom - colTop)
                var scan = Path()
                scan.move(to: CGPoint(x: r.minX + p * 0.5, y: y))
                scan.addLine(to: CGPoint(x: r.maxX - p * 0.5, y: y))
                k.batch.spark(scan, min(1, 0.3 + L), width: k.hair * 1.6)
            }
            guard L > 0.016 else { return }      // detail brightens by L over its 0.26 base
        }

        var detail = Path()
        detail.addRect(CGRect(x: band.minX, y: band.minY, width: band.width * 0.45, height: band.height))
        detail.addRect(CGRect(x: band.minX + band.width * 0.55, y: band.minY, width: band.width * 0.45, height: band.height))
        for c in cols {
            detail.addRect(c)
            for j in 1...3 {
                let x = c.minX + c.width * CGFloat(j) / 4
                detail.move(to: CGPoint(x: x, y: c.minY))
                detail.addLine(to: CGPoint(x: x, y: c.maxY))
            }
        }
        k.batch.stroke(detail, k.base ? 0.26 : Self.extra(0.26, 0.26 + 0.74 * L), width: k.hair)
    }

    /// Lower-tier core: fills from the bottom, its center pulses faster as load rises.
    private func smallCore(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, load L: Double, angle: Double) {
        let side = min(r.width, r.height)
        let inner = r.insetBy(dx: max(1, side * 0.12), dy: max(1, side * 0.12))
        guard inner.width > 0, inner.height > 0 else { return }

        let c = side * 0.34
        let center = CGRect(x: r.midX - c / 2, y: r.midY - c / 2, width: c, height: c)
        if !k.base {
            if L > 0.005 {
                let h = inner.height * CGFloat(L)
                k.batch.fill(Path(CGRect(x: inner.minX, y: inner.maxY - h, width: inner.width, height: h)), 0.15 + 0.4 * L)
            }
            if L > 0.02 {
                let pulse = 0.55 + 0.45 * sin(angle)
                k.batch.fill(Path(center.insetBy(dx: k.hair, dy: k.hair)), L * pulse)
            }
            guard L > 0.016 else { return }
        }
        let tick = side * 0.18
        var detail = Path()
        detail.addRect(center)
        for (x, y, dx, dy) in [(inner.minX, inner.minY, 1.0, 1.0), (inner.maxX, inner.minY, -1.0, 1.0),
                               (inner.minX, inner.maxY, 1.0, -1.0), (inner.maxX, inner.maxY, -1.0, -1.0)] {
            detail.move(to: CGPoint(x: x + tick * CGFloat(dx), y: y))
            detail.addLine(to: CGPoint(x: x, y: y))
            detail.addLine(to: CGPoint(x: x, y: y + tick * CGFloat(dy)))
        }
        k.batch.stroke(detail, k.base ? 0.3 : Self.extra(0.3, 0.3 + 0.7 * L), width: k.hair)
    }

    // MARK: - GPU / Neural Engine / caches

    /// GPU core. macOS reports one utilization for the whole GPU, so each core shows that value
    /// with a fixed bias plus a slow drift, its lit cells shimmer gently, and a faint dispatch
    /// sweep passes down the core every few seconds while it works. Enough motion to read as
    /// alive without the flicker of fast random changes.
    private func gpuCore(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, load L0: Double, index: Int) {
        let L = min(1, L0 * (1 + 0.08 * sin(k.t * 0.55 + Double(index) * 1.31)))
        let p = max(1, r.width * 0.08)
        let inner = r.insetBy(dx: p, dy: p)
        let cg = max(0.8, r.width * 0.04)
        // The same cell design at every size: 3 × 6 cells while they stay at least 2.2 pt,
        // otherwise 2 × 4 or 2 × 3 (Simple mode, an Ultra at 50 %), so small cores keep their
        // lit cells instead of turning into noise. Only a core too small even for that
        // (under 6 pt) is drawn as one cell whose brightness follows the load.
        func fits(_ c: Int, _ rr: Int) -> Bool {
            (inner.width - cg * CGFloat(c - 1)) / CGFloat(c) >= 2.2 &&
                (inner.height - cg * CGFloat(rr - 1)) / CGFloat(rr) >= 2.2
        }
        let choice = [(3, 6), (2, 4), (2, 3)].first { fits($0.0, $0.1) }
        guard min(r.width, r.height) >= 6, let grid = choice else {
            guard inner.width > 0, inner.height > 0 else { return }
            if k.base { k.batch.stroke(Path(inner), 0.25, width: k.hair); return }
            if L > 0.01 { k.batch.fill(Path(inner.insetBy(dx: k.hair, dy: k.hair)), 0.15 + 0.6 * L) }
            return
        }
        let (cols, rows) = grid
        let n = cols * rows
        let cw = (inner.width - cg * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (inner.height - cg * CGFloat(rows - 1)) / CGFloat(rows)
        guard cw > 0, ch > 0 else { return }
        func cell(_ i: Int) -> CGRect {
            CGRect(x: inner.minX + CGFloat(i % cols) * (cw + cg),
                   y: inner.minY + CGFloat(i / cols) * (ch + cg), width: cw, height: ch)
        }

        if k.base || L > 0.05 {
            var outline = Path()
            for i in 0..<n { outline.addRect(cell(i)) }
            k.batch.stroke(outline, k.base ? 0.2 : Self.extra(0.2, 0.2 + 0.35 * L), width: k.hair)
        }
        guard !k.base else { return }
        if L > 0.6 { k.batch.fill(Path(r), (L - 0.6) * 0.35) }

        // Cells light in a fixed scrambled order per core, so the count only follows the load;
        // the boundary cell fades in with the fractional part. Lit cells fall into three
        // shimmer groups that breathe out of phase.
        let level = L * Double(n)
        let full = min(n, Int(level))
        let partial = level - Double(full)
        if level > 0.01 {
            let order = k.st.gpuOrder(index, cells: n)
            var groups = [Path(), Path(), Path()]
            for j in 0..<full { groups[j % 3].addRect(cell(order[j])) }
            for g in 0..<3 {
                let breathe = 0.5 + 0.5 * sin(k.t * 1.3 + Double(index) * 0.8 + Double(g) * 2.1)
                k.batch.fill(groups[g], 0.55 + 0.3 * breathe)
            }
            if full < n && partial > 0.01 {
                k.batch.fill(Path(cell(order[full])), 0.75 * partial)
            }
        }

        // Dispatch sweep.
        if L > 0.03 {
            let ph = (k.st.sweepClock + hash01(index * 5 + 1)).truncatingRemainder(dividingBy: 1)
            let y = inner.minY + inner.height * CGFloat(ph)
            var sweep = Path()
            sweep.move(to: CGPoint(x: inner.minX, y: y))
            sweep.addLine(to: CGPoint(x: inner.maxX, y: y))
            k.batch.spark(sweep, (0.15 + 0.45 * L) * (1 - 0.4 * ph), width: k.hair * 1.2)
        }
    }

    private func npuCore(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, load: Double?, index: Int) {
        let side = min(r.width, r.height)
        let inner = r.insetBy(dx: side * 0.16, dy: side * 0.16)
        let dot = CGRect(x: r.midX - side * 0.12, y: r.midY - side * 0.12, width: side * 0.24, height: side * 0.24)
        var detail = Path()
        detail.addRect(inner)
        detail.addRect(dot)
        let L = load ?? 0
        if k.base { k.batch.stroke(detail, 0.18, width: k.hair); return }
        if load != nil { k.batch.stroke(detail, Self.extra(0.18, 0.28 + 0.6 * L), width: k.hair) }
        if L > 0.02 {
            let pulse = 0.5 + 0.5 * sin(k.t * 3 + Double(index) * 0.9)
            k.batch.fill(Path(inner.insetBy(dx: k.hair, dy: k.hair)), L * (0.4 + 0.6 * pulse))
        }
    }

    private func slcBank(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, alpha: Double) {
        let a = k.base ? 0.2 : Self.extra(0.2, alpha)
        guard a > 0.016 else { return }
        var lines = Path()
        let inset = r.insetBy(dx: max(1, r.width * 0.08), dy: max(1, r.height * 0.2))
        for j in 0...2 {
            let y = inset.minY + inset.height * CGFloat(j) / 2
            lines.move(to: CGPoint(x: inset.minX, y: y))
            lines.addLine(to: CGPoint(x: inset.maxX, y: y))
        }
        k.batch.stroke(lines, a, width: k.hair)
    }

    private func cacheArray(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, alpha: Double) {
        let a = k.base ? 0.22 : Self.extra(0.22, alpha)
        guard a > 0.016 else { return }
        var p = Path()
        let cols = max(2, Int(r.width / max(6, r.height * 0.5)))
        let cells = ChipLayoutGrid.cells(r.insetBy(dx: 1.5, dy: 1.5), cols: cols, rows: 2, gap: 1.5)
        for c in cells {
            p.addRect(c)
            let step = max(1.6, c.width / 6)
            var x = c.minX + step
            while x < c.maxX - 0.5 {
                p.move(to: CGPoint(x: x, y: c.minY))
                p.addLine(to: CGPoint(x: x, y: c.maxY))
                x += step
            }
        }
        k.batch.stroke(p, a, width: k.hair * 0.8)
    }

    private func miscBlock(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect) {
        let side = min(r.width, r.height)
        var p = Path()
        p.addRect(r.insetBy(dx: side * 0.15, dy: side * 0.15))
        let sq = side * 0.22
        p.addRect(CGRect(x: r.midX - sq * 1.4, y: r.midY - sq / 2, width: sq, height: sq))
        p.addRect(CGRect(x: r.midX + sq * 0.4, y: r.midY - sq / 2, width: sq, height: sq))
        k.batch.stroke(p, 0.3, width: k.hair)
    }

    private func hatch(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, vertical: Bool, spacing: CGFloat,
                       base: Double, alpha: Double) {
        let a = k.base ? base : Self.extra(base, alpha)
        guard a > 0.016 else { return }
        var p = Path()
        let inner = r.insetBy(dx: 1, dy: 1)
        if vertical {
            var x = inner.minX + spacing / 2
            while x < inner.maxX {
                p.move(to: CGPoint(x: x, y: inner.minY)); p.addLine(to: CGPoint(x: x, y: inner.maxY)); x += spacing
            }
        } else {
            var y = inner.minY + spacing / 2
            while y < inner.maxY {
                p.move(to: CGPoint(x: inner.minX, y: y)); p.addLine(to: CGPoint(x: inner.maxX, y: y)); y += spacing
            }
        }
        k.batch.stroke(p, a, width: k.hair * 0.8)
    }

    /// Chip name set in the same metal as the die, like the keynote illustrations.
    /// The name is turned into glyph outlines once and cached: resolving, measuring and
    /// drawing styled text every frame was half the cost of a frame.
    private func logo(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, title: String, tag: String?) {
        let path = k.st.logoPath(title: title, tag: tag, in: r) { Self.logoPath(title: title, tag: tag, in: r) }
        ctx.fill(path, with: k.metal)
    }

    static func logoPath(title: String, tag: String?, in r: CGRect) -> Path {
        var size = min(r.height * 0.7, r.width * (tag == nil ? 0.42 : 0.3))
        let x = r.minX + r.width * 0.07
        let room = r.width * 0.86
        func parts(_ size: CGFloat) -> (GlyphLine, GlyphLine?) {
            (GlyphLine(title, font: .systemFont(ofSize: size, weight: .semibold)),
             tag.map { GlyphLine($0, font: .systemFont(ofSize: size * 0.42, weight: .medium), kern: size * 0.04) })
        }
        var (t, g) = parts(size)
        let width = t.width + (g.map { size * 0.2 + $0.width } ?? 0)
        if width > room {                // long names ("ULTRA", "A18 PRO") shrink to fit their block
            size *= room / width
            (t, g) = parts(size)
        }
        var path = t.placed(leadingX: x, centerY: r.midY)
        if let g {
            path.addPath(g.placed(leadingX: x + t.width + size * 0.2, centerY: r.midY + size * 0.17))
        }
        return path
    }

    // MARK: - Wires

    /// Memory lanes between the dies and the memory packages. Their number was set from the
    /// chip's published bandwidth (ChipLayout); here the pulses per lane and their speed
    /// follow it too, so an Ultra visibly moves far more data than a base chip.
    private func drawTraces(_ ctx: GraphicsContext, _ k: Kit, traffic: Double, P: (CGPoint) -> CGPoint) {
        guard !drawing.traces.isEmpty else { return }
        if k.base {
            var wires = Path()
            for tr in drawing.traces { wires.move(to: P(tr.from)); wires.addLine(to: P(tr.to)) }
            with(ctx, opacity: 0.35).stroke(wires, with: k.metal, lineWidth: k.hair)
            return
        }

        var pulses = Path()
        let perLane = max(1, drawing.pulsesPerLane)
        let clock = k.st.trafficClock * (0.75 + 0.5 * min(1, drawing.bandwidth / 800))
        for (i, tr) in drawing.traces.enumerated() {
            let a = P(tr.from), b = P(tr.to)
            let vertical = abs(b.y - a.y) >= abs(b.x - a.x)
            for j in 0..<perLane {
                var phase = (clock + Double(i) * 0.37 + Double(j) / Double(perLane))
                    .truncatingRemainder(dividingBy: 1)
                if i % 2 == 1 { phase = 1 - phase }      // alternate read / write direction
                let x = a.x + (b.x - a.x) * CGFloat(phase), y = a.y + (b.y - a.y) * CGFloat(phase)
                pulses.addRect(vertical ? CGRect(x: x - k.hair, y: y - 2, width: k.hair * 2, height: 4)
                                        : CGRect(x: x - 2, y: y - k.hair, width: 4, height: k.hair * 2))
            }
        }
        with(ctx, opacity: 0.25 + 0.7 * traffic).fill(pulses, with: .color(k.spark))
    }

    /// Lane positions across a seam, `pitch` points apart, along its long side.
    private func lanes(_ r: CGRect, pitch: CGFloat) -> [CGFloat] {
        let horizontal = r.width >= r.height
        let length = horizontal ? r.width : r.height
        let origin = horizontal ? r.minX : r.minY
        let n = max(1, Int(length / pitch))
        let used = CGFloat(n) * pitch
        return (0..<n).map { origin + (length - used) / 2 + pitch * (CGFloat($0) + 0.5) }
    }

    /// Path of lanes crossing the seam (perpendicular to its long side).
    private func lanePath(_ r: CGRect, _ positions: [CGFloat]) -> Path {
        var p = Path()
        let horizontal = r.width >= r.height
        for v in positions {
            if horizontal { p.move(to: CGPoint(x: v, y: r.minY)); p.addLine(to: CGPoint(x: v, y: r.maxY)) }
            else { p.move(to: CGPoint(x: r.minX, y: v)); p.addLine(to: CGPoint(x: r.maxX, y: v)) }
        }
        return p
    }

    /// Point `phase` (0…1) of the way across the seam on lane `v`.
    private func across(_ r: CGRect, _ v: CGFloat, _ phase: Double) -> CGPoint {
        r.width >= r.height ? CGPoint(x: v, y: r.minY + r.height * CGFloat(phase))
                            : CGPoint(x: r.minX + r.width * CGFloat(phase), y: v)
    }

    /// UltraFusion (gold) and Fusion (M5 Pro/Max CPU ↔ GPU die, in the chip's own palette,
    /// drifting slowly): the interposer joining two dies across their entire facing edge.
    /// Layers, back to front: a substrate shaded for depth across the seam; a micro-bump
    /// field of lanes 0.75 pt apart (every fourth one heavier); rows of bond pads along both
    /// die edges; double rails; a specular line down the middle; a glitter of patches and pads
    /// that brighten and fade independently; and comet-tailed pulses in both directions, more
    /// and faster as the chip works harder.
    ///
    /// Base pass: substrate, dark rails and (gold) the metal field. Live pass: everything that
    /// moves, plus the Fusion metal, whose colours drift; with DieLayers that is a cached
    /// white mask tinted by sliding a pre-rendered palette strip under it.
    private func drawInterposer(_ ctx: GraphicsContext, _ k: Kit, _ r: CGRect, traffic: Double, gold isGold: Bool) {
        let horizontal = r.width >= r.height
        let len = horizontal ? r.width : r.height
        let thick = horizontal ? r.height : r.width
        // a = along the seam, b = across it.
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: r.minX + a, y: r.minY + b) : CGPoint(x: r.minX + b, y: r.minY + a)
        }
        func box(_ a: CGFloat, _ b: CGFloat, _ la: CGFloat, _ lb: CGFloat) -> CGRect {
            horizontal ? CGRect(x: r.minX + a, y: r.minY + b, width: la, height: lb)
                       : CGRect(x: r.minX + b, y: r.minY + a, width: lb, height: la)
        }
        let pal = ChipCatalog.palette(chip)
        let deepest = pal.stops.map { $0.0 }.min { ($0.r + $0.g + $0.b) < ($1.r + $1.g + $1.b) }!
        let spark: Color = isGold ? ChipCatalog.goldSpark.color : pal.spark.color
        let sparkRGB: RGB = isGold ? ChipCatalog.goldSpark : pal.spark
        let secondSpark: Color = isGold ? RGB(0xFFC867).color : pal.accent.mix(.white, 0.35).color
        let padZone = min(thick * 0.18, 3)
        let pitch: CGFloat = 0.75
        let count = max(1, Int(len / pitch))
        let offset = (len - CGFloat(count) * pitch) / 2 + pitch / 2
        let padPitch: CGFloat = 1.6, pad: CGFloat = min(0.95, padZone * 0.4)

        /// The metal field (lanes, pads, bright rails): geometry is fixed per rectangle.
        struct Field { var fine = Path(), heavy = Path(), pads = Path(), bright = Path() }
        func field() -> Field {
            var f = Field()
            for i in 0..<count {
                let a = offset + CGFloat(i) * pitch
                if i % 4 == 0 { f.heavy.move(to: pt(a, padZone)); f.heavy.addLine(to: pt(a, thick - padZone)) }
                else { f.fine.move(to: pt(a, padZone)); f.fine.addLine(to: pt(a, thick - padZone)) }
            }
            var a = padPitch / 2
            while a < len - pad {
                f.pads.addRect(box(a - pad / 2, padZone * 0.3, pad, pad))
                f.pads.addRect(box(a - pad / 2, thick - padZone * 0.3 - pad, pad, pad))
                a += padPitch
            }
            f.bright.move(to: pt(0, 0.35)); f.bright.addLine(to: pt(len, 0.35))
            f.bright.move(to: pt(0, thick - 0.35)); f.bright.addLine(to: pt(len, thick - 0.35))
            return f
        }
        func paint(_ c: GraphicsContext, _ f: Field, _ shading: GraphicsContext.Shading) {
            with(c, opacity: 0.55).stroke(f.fine, with: shading, lineWidth: 0.3)
            with(c, opacity: 0.95).stroke(f.heavy, with: shading, lineWidth: 0.45)
            c.fill(f.pads, with: shading)
            c.stroke(f.bright, with: shading, lineWidth: 0.7)
        }

        if k.base {
            // 1. Substrate, darker at both die edges.
            let edge = isGold ? RGB(0x0E0903) : deepest.mix(.black, 0.92)
            let mid = isGold ? RGB(0x3A2A10) : deepest.mix(.black, 0.62)
            let depth = Gradient(stops: [.init(color: edge.color, location: 0), .init(color: mid.color, location: 0.5),
                                         .init(color: edge.color, location: 1)])
            ctx.fill(Path(r), with: .linearGradient(depth, startPoint: pt(0, 0), endPoint: pt(0, thick)))
            // 2–4. Gold metal field (it never changes colour), dark rails.
            if isGold {
                let gold = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: ChipCatalog.gold.map { .init(color: $0.0.color, location: CGFloat($0.1)) }),
                    startPoint: pt(0, thick / 2), endPoint: pt(len, thick / 2))
                paint(ctx, field(), gold)
            }
            var dark = Path()
            dark.move(to: pt(0, padZone)); dark.addLine(to: pt(len, padZone))
            dark.move(to: pt(0, thick - padZone)); dark.addLine(to: pt(len, thick - padZone))
            let railDark = isGold ? RGB(0x6E4A12) : deepest.mix(.black, 0.4)
            with(ctx, opacity: 0.6).stroke(dark, with: .color(railDark.color), lineWidth: 0.4)
            return
        }

        // Fusion metal field in the drifting palette.
        if !isGold {
            let phase = k.t * 0.03
            let f = k.st.cached("field|\(r.minX),\(r.minY),\(r.width),\(r.height)") { () -> Field in field() }
            if let layers = k.layers, horizontal {
                // A pre-rendered palette strip, tiled along the seam and slid by the phase.
                let cycle = len / 0.6                       // the seam shows 0.6 of the palette loop
                let strip = layers.paletteStrip(pal, cycle: cycle)
                let shift = CGFloat(phase - floor(phase)) * cycle
                paint(ctx, f, .tiledImage(strip, origin: CGPoint(x: r.minX - shift, y: r.minY),
                                          sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1))
            } else {
                let stops = (0...6).map { i in
                    Gradient.Stop(color: pal.cyclic(Double(i) / 6 * 0.6 + phase).color, location: CGFloat(i) / 6)
                }
                paint(ctx, f, .linearGradient(Gradient(stops: stops), startPoint: pt(0, thick / 2), endPoint: pt(len, thick / 2)))
            }
        }

        // 5. Specular centre line.
        var centre = Path()
        centre.move(to: pt(0, thick / 2)); centre.addLine(to: pt(len, thick / 2))
        with(ctx, opacity: 0.18 + 0.12 * traffic).stroke(centre, with: .color(spark), lineWidth: thick * 0.08)

        // 6. Glitter. The seam is split into soft, overlapping patches whose brightness drifts
        // slowly and independently (cubed, so most stay calm and a few brighten at a time), and
        // individual bond pads catch the light now and then. Nothing travels along the seam.
        let patch: CGFloat = 6
        let patches = max(1, Int(len / patch))
        var clipped = ctx
        clipped.clip(to: Path(r))
        let shineImage = horizontal ? k.layers?.shine(sparkRGB) : nil
        let spark0 = spark.opacity(0)
        let shine = Gradient(stops: [.init(color: spark0, location: 0), .init(color: spark, location: 0.5),
                                     .init(color: spark0, location: 1)])
        for i in 0..<patches {
            let rate = 0.35 + 0.8 * hash01(i * 17 + 5)
            let wave = 0.5 + 0.5 * sin(k.t * rate + hash01(i * 29 + 11) * 6.283)
            let strength = pow(wave, 3) * (0.22 + 0.25 * traffic)
            guard strength > 0.02 else { continue }
            let c = (CGFloat(i) + 0.5) * len / CGFloat(patches)
            let half = patch * 1.1
            if let shineImage {
                with(clipped, opacity: strength).draw(shineImage, in: box(c - half, 0, half * 2, thick))
            } else {
                with(clipped, opacity: strength).fill(Path(box(c - half, 0, half * 2, thick)),
                                                      with: .linearGradient(shine, startPoint: pt(c - half, 0), endPoint: pt(c + half, 0)))
            }
        }
        var glints = [Path(), Path(), Path()]
        var padIndex = 0
        var a = padPitch / 2
        while a < len - pad {
            for b in [padZone * 0.3, thick - padZone * 0.3 - pad] {
                let v = pow(0.5 + 0.5 * sin(k.t * (0.6 + 0.9 * hash01(padIndex)) + hash01(padIndex * 7 + 3) * 6.283), 12)
                if v > 0.2 {
                    glints[v > 0.7 ? 2 : (v > 0.45 ? 1 : 0)].addRect(box(a - pad / 2 - 0.2, b - 0.2, pad + 0.4, pad + 0.4))
                }
                padIndex += 1
            }
            a += padPitch
        }
        for (g, alpha) in zip(glints, [0.3, 0.6, 0.95]) {
            with(ctx, opacity: alpha).fill(g, with: .color(spark))
        }

        // 7. Comet-tailed pulses, both ways.
        let clock = isGold ? k.st.ultraClock : k.st.fusionClock
        let perLane = 1 + Int(traffic * 2.5)
        let span = thick - padZone * 2
        var heads = [Path(), Path()], tails = [Path(), Path()], glow = Path()
        for i in stride(from: 0, to: count, by: 3) {
            let lane = offset + CGFloat(i) * pitch
            let down = (i / 3) % 2 == 0
            for j in 0..<perLane {
                var ph = (clock * (0.8 + 0.4 * hash01(i)) + hash01(i * 13 + j * 7) + Double(j) / Double(perLane))
                    .truncatingRemainder(dividingBy: 1)
                if !down { ph = 1 - ph }
                let b = padZone + span * CGFloat(ph)
                let dir: CGFloat = down ? -1 : 1           // tail trails behind the head
                let side = down ? 0 : 1
                heads[side].addRect(box(lane - 0.4, b - 1.1, 0.8, 2.2))
                tails[side].addRect(box(lane - 0.3, min(b, b + dir * 4.5), 0.6, 4.5))
                glow.addRect(box(lane - 1.1, b - 1.8, 2.2, 3.6))
            }
        }
        let alpha = 0.45 + 0.55 * traffic
        with(ctx, opacity: 0.08 + 0.2 * traffic).fill(glow, with: .color(spark))
        with(ctx, opacity: alpha * 0.35).fill(tails[0], with: .color(spark))
        with(ctx, opacity: alpha * 0.35).fill(tails[1], with: .color(secondSpark))
        with(ctx, opacity: alpha).fill(heads[0], with: .color(spark))
        with(ctx, opacity: alpha).fill(heads[1], with: .color(secondSpark))
    }


    // MARK: - Memory

    /// Unified memory packages. The frame matches the die's own border (the same 0.027-unit
    /// margin), and cells run five across the package's short side, so side-mounted Ultra
    /// packages look like the ones under a base chip.
    private func drawMemory(_ ctx: GraphicsContext, _ k: Kit, state: AnimState, R: (CGRect) -> CGRect, bounds: CGRect) {
        let packages = drawing.packages.map(R)
        guard let first = packages.first else { return }

        let frame = max(1, 0.027 * k.unit)
        if k.base {
            var slab = Path(), ink = Path()
            for r in packages { slab.addRect(r); ink.addRect(r.insetBy(dx: frame, dy: frame)) }
            ctx.fill(slab, with: k.metal)
            ctx.fill(ink, with: .color(k.ink))
            return
        }
        let inner0 = first.insetBy(dx: frame, dy: frame)
        let vertical = inner0.height > inner0.width
        let short = min(inner0.width, inner0.height), long = max(inner0.width, inner0.height)
        // Five cells across the short side; fewer when that would make them tinier than 4 pt.
        let cellGap: CGFloat = max(1, short * 0.035)
        let across = [5, 4, 3].first { (short - cellGap * CGFloat($0 + 1)) / CGFloat($0) >= 4 } ?? 3
        let cell = (short - cellGap * CGFloat(across + 1)) / CGFloat(across)
        guard cell > 0 else { return }
        let alongCount = max(1, Int((long - cellGap) / (cell + cellGap)))
        let perPackage = alongCount * across
        let totalCells = Double(perPackage * packages.count)

        // Cumulative thresholds, in cells, filled column by column across all packages.
        let wiredEnd = state.wired * totalCells
        let appEnd = wiredEnd + state.app * totalCells
        let compEnd = appEnd + state.compressed * totalCells
        let cachedEnd = compEnd + state.cached * totalCells

        var wired = Path(), app = Path(), comp = Path(), compMarks = Path(), cached = Path(), free = Path()

        for (pi, r) in packages.enumerated() {
            let inner = r.insetBy(dx: frame, dy: frame)
            let usedLong = CGFloat(alongCount) * cell + CGFloat(alongCount - 1) * cellGap
            let l0 = (vertical ? inner.minY : inner.minX) + ((vertical ? inner.height : inner.width) - usedLong) / 2
            let s0 = (vertical ? inner.minX : inner.minY) + cellGap
            for c in 0..<alongCount {
                for a in 0..<across {
                    let index = Double(pi * perPackage + c * across + a) + 0.5
                    let l = l0 + CGFloat(c) * (cell + cellGap), s = s0 + CGFloat(a) * (cell + cellGap)
                    let rect = vertical ? CGRect(x: s, y: l, width: cell, height: cell)
                                        : CGRect(x: l, y: s, width: cell, height: cell)
                    if index < wiredEnd { wired.addRect(rect) }
                    else if index < appEnd { app.addRect(rect) }
                    else if index < compEnd {
                        comp.addRect(rect)
                        compMarks.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        compMarks.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    }
                    else if index < cachedEnd { cached.addRect(rect) }
                    else { free.addRect(rect) }
                }
            }
        }

        let cells = MetalBatch()
        cells.fill(wired, 1)
        cells.fill(app, 0.78)
        cells.fill(comp, 0.4)
        cells.fill(cached, 0.16)
        cells.stroke(free, 0.2, width: k.hair * 0.8)
        cells.flush(ctx, metal: k.metal, metalImage: k.layers?.metal, bounds: bounds, spark: k.spark)
        with(ctx, opacity: 0.35).fill(wired, with: .color(k.spark))
        ctx.stroke(compMarks, with: .color(k.ink), lineWidth: k.hair)

        if state.pressure != .normal {
            let color = state.pressure == .critical ? Theme.critical : Theme.warning
            var outline = Path()
            for r in packages { outline.addRect(r.insetBy(dx: frame / 2, dy: frame / 2)) }
            with(ctx, opacity: 0.45 + 0.35 * sin(k.t * 4)).stroke(outline, with: .color(color), lineWidth: frame)
        }
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Deterministic pseudo-random value in 0..<1.
func hash01(_ n: Int) -> Double {
    let x = sin(Double(n) * 12.9898) * 43758.5453
    return x - floor(x)
}

enum ChipLayoutGrid {
    static func cells(_ r: CGRect, cols: Int, rows: Int, gap: CGFloat) -> [CGRect] {
        let cw = (r.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (r.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cw > 0, ch > 0 else { return [] }
        var out: [CGRect] = []
        for j in 0..<rows {
            for i in 0..<cols {
                out.append(CGRect(x: r.minX + CGFloat(i) * (cw + gap), y: r.minY + CGFloat(j) * (ch + gap),
                                  width: cw, height: ch))
            }
        }
        return out
    }
}

/// One line of text as glyph outlines (y pointing down, baseline at 0), with its metrics.
struct GlyphLine {
    let path: CGPath
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(_ string: String, font: NSFont, kern: CGFloat = 0) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .kern: kern])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        self.ascent = ascent
        self.descent = descent
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attributes[NSAttributedString.Key.font] as? NSFont) ?? font
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont as CTFont, glyphs[i], nil) else { continue }
                // Core Text is y-up; flip into the canvas's y-down space.
                path.addPath(outline, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                                    tx: positions[i].x, ty: -positions[i].y))
            }
        }
        self.path = path
    }

    /// Placed like `draw(_:at:anchor: .leading)`: left edge at x, vertically centred on y.
    func placed(leadingX x: CGFloat, centerY y: CGFloat) -> Path {
        let baseline = y + (ascent - descent) / 2
        return Path(path).applying(CGAffineTransform(translationX: x, y: baseline))
    }
}

// MARK: - Pre-rendered layers

/// Everything about one die picture that does not change from frame to frame, rendered once
/// for a canvas size and screen scale: the base pass as an image, the die gradient as an
/// image (the live pass tints its white masks with it instead of computing the gradient),
/// palette strips for the Fusion seams and the glitter highlight.
final class DieLayers {
    let size: CGSize
    let scale: CGFloat
    let base: Image
    let metal: Image
    private var strips: [Int: Image] = [:]
    private var shines: [String: Image] = [:]

    init(size: CGSize, scale: CGFloat, base: Image, metal: Image) {
        self.size = size; self.scale = scale; self.base = base; self.metal = metal
    }

    func matches(_ s: CGSize) -> Bool {
        abs(s.width - size.width) < 0.5 && abs(s.height - size.height) < 0.5
    }

    /// Two loops of the palette, `cycle` points per loop, as a one-pixel-high image (tiles
    /// seamlessly: the palette loop runs forward and back).
    func paletteStrip(_ pal: ChipPalette, cycle: CGFloat) -> Image {
        let key = Int((cycle * 10).rounded())
        if let i = strips[key] { return i }
        let width = max(2, Int((cycle * 2 * scale).rounded(.up)))
        let image = Self.row(width: width) { x in
            let c = pal.cyclic(Double(x) / Double(cycle * scale))
            return (c, 1)
        }.map { Image(decorative: $0, scale: scale) } ?? Image(systemName: "square")
        strips[key] = image
        return image
    }

    /// A soft horizontal highlight: transparent → colour → transparent.
    func shine(_ color: RGB) -> Image {
        let key = color.hex
        if let i = shines[key] { return i }
        let image = Self.row(width: 64) { x in
            (color, 1 - abs(Double(x) / 63 * 2 - 1))
        }.map { Image(decorative: $0, scale: 1) } ?? Image(systemName: "square")
        shines[key] = image
        return image
    }

    private static func row(width: Int, _ pixel: (Int) -> (RGB, Double)) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let (c, a) = pixel(x)
            let alpha = max(0, min(1, a))
            bytes[x * 4] = UInt8((max(0, min(1, c.r)) * alpha * 255).rounded())
            bytes[x * 4 + 1] = UInt8((max(0, min(1, c.g)) * alpha * 255).rounded())
            bytes[x * 4 + 2] = UInt8((max(0, min(1, c.b)) * alpha * 255).rounded())
            bytes[x * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The die gradient over the whole canvas, as DieRenderer's metal shading draws it.
    static func metalImage(_ renderer: DieRenderer, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pal = ChipCatalog.palette(renderer.chip)
        let colors = pal.stops.map { stop -> CGColor in
            let comps: [CGFloat] = [CGFloat(stop.0.r), CGFloat(stop.0.g), CGFloat(stop.0.b), 1]
            return CGColor(colorSpace: space, components: comps) ?? CGColor(gray: 0.5, alpha: 1)
        } as CFArray
        var locations = pal.stops.map { CGFloat($0.1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: &locations) else { return nil }
        // Canvas points, y down.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        let axis = renderer.metalAxis(renderer.geometry(size))
        cg.drawLinearGradient(gradient, start: axis.0, end: axis.1,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return cg.makeImage()
    }
}

/// Holds the current DieLayers and rebuilds them when the canvas size settles: while the
/// popover is resizing the size changes every frame, so nothing is built until two frames
/// in a row ask for the same size.
final class DieLayerCache {
    private var current: DieLayers?
    private var pending: CGSize?

    @MainActor
    func layers(for renderer: DieRenderer, size: CGSize, scale: CGFloat, state: AnimState) -> DieLayers? {
        if let c = current, c.matches(size), c.scale == scale { return c }
        guard let p = pending, abs(p.width - size.width) < 0.5, abs(p.height - size.height) < 0.5 else {
            pending = size
            return nil
        }
        pending = nil
        let view = Canvas { ctx, sz in renderer.renderBase(ctx, size: sz, state: state) }
            .frame(width: size.width, height: size.height)
        let imageRenderer = ImageRenderer(content: view)
        imageRenderer.scale = scale
        guard let base = imageRenderer.cgImage,
              let metal = DieLayers.metalImage(renderer, size: size, scale: scale) else { return nil }
        current = DieLayers(size: size, scale: scale, base: Image(decorative: base, scale: scale),
                            metal: Image(decorative: metal, scale: scale))
        return current
    }
}
