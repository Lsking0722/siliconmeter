//
//  Topology.swift
//  Detects the chip once at launch: name, variant, CPU tiers and clusters, GPU and
//  Neural Engine core counts, memory size. Everything here is sudoless.
//
//  The cluster map and DVFS-table reading follow SiliconScope (CPUClusterMap.swift,
//  CPUTopology.swift — MIT, (c) 2026 Kennt Kim / Calida Lab). The cluster-type letter
//  ranking (P > M > E, where M5 calls "P" a Super core and "M" a Performance core)
//  follows exelban/stats (MIT).
//
import Foundation
import IOKit

enum ChipVariant: String {
    case base, pro, max, ultra
}

/// M-series (Mac chips) or A-series (iPhone chips that also ship in Macs: A18 Pro in the
/// MacBook Neo, 2026). Generation numbers are per series, so M-only rules check this first.
enum ChipSeries: String {
    case m, a
}

/// The physical shape the chip is drawn as.
enum DieArchetype: String {
    case mono      // one square die: M1…M5 base
    case proMax    // one tall die: M1…M4 Pro / Max
    case ultra     // two Max dies side by side
    case fusion    // CPU die + GPU die stacked: M5 Pro / Max (Fusion Architecture)
    case fusionUltra // two fusion packages side by side, four dies: M5 Ultra
}

struct CoreCluster {
    let id: Int
    let tier: Int
    let cpus: [Int]          // host_processor_info indices
}

struct CoreTier {
    let index: Int           // 0 = fastest
    let name: String         // "Super", "Performance", "Efficiency" — as macOS reports it
    let cpuCount: Int
}

struct PerfLevel {
    let index: Int
    let name: String
    let logicalCPUs: Int

    static func all() -> [PerfLevel] {
        let n = Sys.int("hw.nperflevels")
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            PerfLevel(index: i,
                      name: Sys.string("hw.perflevel\(i).name") ?? (i == 0 ? "Performance" : "Efficiency"),
                      logicalCPUs: Sys.int("hw.perflevel\(i).logicalcpu"))
        }
    }
}

struct ChipInfo {
    let brand: String            // "Apple M4 Pro"
    let family: String           // "M4", "A18" (or "SoC" when the name has neither)
    let series: ChipSeries
    let generation: Int?         // 4 for M4, 18 for A18
    let variant: ChipVariant     // A-series chips are always .base (one die, Mac-wise)
    let tiers: [CoreTier]
    let clusters: [CoreCluster]
    let cpuCount: Int
    let gpuCores: Int
    let npuCores: Int
    let memoryBytes: UInt64
    let gpuFreqsMHz: [Double]
    let mapSource: String        // "device tree" or "fallback order"

    var archetype: DieArchetype {
        switch variant {
        case .base: return .mono
        case .ultra: return (mGeneration ?? 0) >= 5 ? .fusionUltra : .ultra
        case .pro, .max: return (mGeneration ?? 0) >= 5 ? .fusion : .proMax
        }
    }

    /// "PRO", "MAX", "ULTRA" or nil for the base chip. A-series: "PRO" for A18 Pro.
    var tag: String? {
        if series == .a { return brand.lowercased().contains("pro") ? "PRO" : nil }
        return variant == .base ? nil : variant.rawValue.uppercased()
    }

    /// Generation number for M-series rules; nil on A-series.
    var mGeneration: Int? { series == .m ? generation : nil }

    func clusters(ofTier tier: Int) -> [CoreCluster] {
        clusters.filter { $0.tier == tier }.sorted { $0.id < $1.id }
    }

    func cpus(ofTier tier: Int) -> [Int] {
        clusters(ofTier: tier).flatMap(\.cpus)
    }

    // MARK: - Detection

    /// Reads this Mac. Everything chip-specific goes through `make`, which `--simulate`
    /// also calls with the inputs of other chips.
    static func detect() -> ChipInfo {
        let levels = PerfLevel.all()
        return make(brand: Sys.string("machdep.cpu.brand_string") ?? "Apple Silicon",
                    levels: levels,
                    map: CPUClusterMap.read(),
                    cpuCount: max(Sys.int("hw.logicalcpu"), levels.reduce(0) { $0 + $1.logicalCPUs }),
                    gpuCores: gpuCoreCount(),
                    memoryBytes: Sys.uint64("hw.memsize"),
                    gpuFreqsMHz: readVoltageStates("voltage-states9"))
    }

    static func make(brand: String, levels: [PerfLevel], map: [CPUClusterEntry], cpuCount: Int,
                     gpuCores: Int, memoryBytes: UInt64, gpuFreqsMHz: [Double]) -> ChipInfo {
        let (family, generation, series) = parseFamily(brand)
        let variant = series == .a ? .base : parseVariant(brand)
        let (tiers, clusters, source) = detectClusters(levels: levels, map: map, cpuCount: cpuCount)
        return ChipInfo(
            brand: brand,
            family: family,
            series: series,
            generation: generation,
            variant: variant,
            tiers: tiers,
            clusters: clusters,
            cpuCount: cpuCount,
            gpuCores: gpuCores,
            npuCores: neuralEngineCores(variant: variant, generation: series == .m ? generation : nil),
            memoryBytes: memoryBytes,
            gpuFreqsMHz: gpuFreqsMHz,
            mapSource: source
        )
    }

    /// macOS does not expose the Neural Engine core count. Known: 16 cores per engine;
    /// Ultra chips carry two (M1–M3 Ultra 32, M5 Ultra 32); M6 is the first base chip with a
    /// dual 16-core Neural Engine.
    static func neuralEngineCores(variant: ChipVariant, generation: Int?) -> Int {
        if variant == .ultra { return 32 }
        if variant == .base, (generation ?? 0) >= 6 { return 32 }
        return 16
    }

    /// "Apple M4 Pro" → ("M4", 4, .m); "Apple A18 Pro" → ("A18", 18, .a).
    static func parseFamily(_ brand: String) -> (String, Int?, ChipSeries) {
        guard let r = brand.range(of: #"\b[MA][0-9]+"#, options: .regularExpression) else { return ("SoC", nil, .m) }
        let token = String(brand[r])
        return (token, Int(token.dropFirst()), token.hasPrefix("A") ? .a : .m)
    }

    static func parseVariant(_ brand: String) -> ChipVariant {
        let b = brand.lowercased()
        if b.contains("ultra") { return .ultra }
        if b.contains("max") { return .max }
        if b.contains("pro") { return .pro }
        return .base
    }

    /// Lower rank = faster tier. "P" is the top tier on every generation (Performance on
    /// M1–M4, Super from M5); "M" is the mid Performance tier of M5 Pro/Max/Ultra and M6;
    /// "E" is Efficiency.
    private static func rank(_ clusterType: String) -> Int {
        switch clusterType.uppercased() {
        case "P": return 0
        case "M": return 1
        case "E": return 2
        default: return 1
        }
    }

    private static func defaultName(_ clusterType: String) -> String {
        switch clusterType.uppercased() {
        case "E": return "Efficiency"
        default: return "Performance"
        }
    }

    private static func detectClusters(levels: [PerfLevel], map: [CPUClusterEntry], cpuCount: Int)
        -> ([CoreTier], [CoreCluster], String) {

        // 1. Device tree: every cpuN node carries its cluster type and cluster id.
        if !map.isEmpty, map.allSatisfy({ !$0.clusterType.isEmpty }) {
            var tiers: [CoreTier] = []
            var clusters: [CoreCluster] = []
            let ranks = Set(map.map { rank($0.clusterType) }).sorted()
            for (ti, r) in ranks.enumerated() {
                let members = map.filter { rank($0.clusterType) == r }
                let name = ti < levels.count ? levels[ti].name : defaultName(members[0].clusterType)
                tiers.append(CoreTier(index: ti, name: name, cpuCount: members.count))
                let byCluster = Dictionary(grouping: members, by: { $0.clusterID })
                for cid in byCluster.keys.sorted() {
                    let cpus = byCluster[cid]!.map(\.cpuIndex).sorted()
                    clusters.append(CoreCluster(id: cid, tier: ti, cpus: cpus))
                }
            }
            return (tiers, clusters, "device tree")
        }

        // 2. Perf levels only: the slower tier is enumerated first (measured on M1 Max).
        if !levels.isEmpty {
            var next = 0
            var cpusByLevel: [Int: [Int]] = [:]
            for level in levels.reversed() {
                cpusByLevel[level.index] = Array(next..<(next + level.logicalCPUs))
                next += level.logicalCPUs
            }
            let tiers = levels.map { CoreTier(index: $0.index, name: $0.name, cpuCount: $0.logicalCPUs) }
            let clusters = levels.map { CoreCluster(id: $0.index, tier: $0.index, cpus: cpusByLevel[$0.index] ?? []) }
            return (tiers, clusters, "fallback order")
        }

        // 3. Nothing known: one tier with every CPU.
        return ([CoreTier(index: 0, name: "Performance", cpuCount: cpuCount)],
                [CoreCluster(id: 0, tier: 0, cpus: Array(0..<cpuCount))],
                "fallback order")
    }

    // MARK: - GPU

    static func gpuCoreCount() -> Int {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var result = 0
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            if let value = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                result = max(result, value.intValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    /// DVFS table (MHz, ascending) from AppleARMIODevice. "voltage-states9" is the GPU.
    static func readVoltageStates(_ key: String) -> [Double] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var freqs: [Double] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            if let data = IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let words = raw.bindMemory(to: UInt32.self)
                    var i = 0
                    while i < words.count {
                        if words[i] != 0 { freqs.append(Double(words[i]) / 1_000_000.0) }
                        i += 2   // (frequency, voltage) pairs
                    }
                }
                IOObjectRelease(entry)
                break
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        // Some generations store KHz instead of Hz; real DVFS tops are hundreds of MHz.
        if let peak = freqs.max(), peak > 0, peak < 100 { freqs = freqs.map { $0 * 1000 } }
        return freqs
    }
}

// MARK: - Device-tree CPU map

struct CPUClusterEntry {
    let cpuIndex: Int
    let clusterID: Int
    let clusterType: String
}

enum CPUClusterMap {
    /// Every `cpuN` node under IOPlatformDevice, ascending by index. Empty when absent.
    static func read() -> [CPUClusterEntry] {
        var entries: [CPUClusterEntry] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            var nameBuf = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS {
                let name = String(cString: nameBuf)
                if name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)) {
                    var props: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let dict = props?.takeRetainedValue() as NSDictionary? {
                        entries.append(CPUClusterEntry(
                            cpuIndex: index,
                            clusterID: intValue(dict["logical-cluster-id"]) ?? -1,
                            clusterType: stringValue(dict["cluster-type"]) ?? ""))
                    }
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return entries.sorted { $0.cpuIndex < $1.cpuIndex }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Data, d.count >= 4 {
            return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let d = any as? Data {
            let text = String(decoding: d, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

// MARK: - sysctl

enum Sys {
    static func int(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    static func uint64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
