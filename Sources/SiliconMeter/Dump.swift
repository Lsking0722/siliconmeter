//
//  Dump.swift
//  `SiliconMeter --dump` prints everything detection and sampling see on this Mac.
//  It exists to verify layouts on chips the author does not own: ask someone with that
//  Mac to run it and paste the output.
//
import CIOReport
import Foundation

enum Dump {
    static func run() {
        let chip = ChipInfo.detect()
        print("SiliconMeter diagnostic dump")
        print("─────────────────────────────")
        print("brand        : \(chip.brand)")
        print("family       : \(chip.family)  generation: \(chip.generation.map(String.init) ?? "?")  variant: \(chip.variant.rawValue)")
        print("archetype    : \(chip.archetype.rawValue)")
        print("cpu count    : \(chip.cpuCount)  (cluster map from \(chip.mapSource))")
        print("gpu cores    : \(chip.gpuCores)  dvfs steps: \(chip.gpuFreqsMHz.count)  max \(Int(chip.gpuFreqsMHz.max() ?? 0)) MHz")
        print("npu cores    : \(chip.npuCores) (assumed)")
        print("memory       : \(String(format: "%.0f", Double(chip.memoryBytes) / 1_073_741_824)) GB")
        print("")
        print("perf levels (sysctl, fastest first):")
        for level in PerfLevel.all() {
            print("  level \(level.index): \(level.name) × \(level.logicalCPUs)")
        }
        print("")
        print("device tree cpu nodes:")
        let map = CPUClusterMap.read()
        if map.isEmpty { print("  (none)") }
        for e in map {
            print("  cpu\(e.cpuIndex): cluster \(e.clusterID) type \"\(e.clusterType)\"")
        }
        print("")
        print("tiers → clusters:")
        for tier in chip.tiers {
            print("  tier \(tier.index) \(tier.name) × \(tier.cpuCount)")
            for c in chip.clusters(ofTier: tier.index) {
                print("    cluster \(c.id): cpus \(c.cpus.map(String.init).joined(separator: ","))")
            }
        }

        let sampler = SystemSampler(chip: chip)
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let s = sampler.sample()
        print("")
        print("live sample (1 s):")
        print("  ioreport   : \(sampler.ioReportAvailable ? "available" : "unavailable")")
        print("  cpu loads  : " + s.cores.map { String(format: "%.0f", $0 * 100) }.joined(separator: " "))
        print("  gpu        : \(String(format: "%.1f", s.gpu * 100))%  clock: \(s.gpuMHz.map { String(format: "%.0f MHz", $0) } ?? "n/a")")
        print("  neural eng : \(s.ane.map { String(format: "%.1f%%", $0 * 100) } ?? "not reported")"
              + (s.aneEstimated ? " (estimated)" : "")
              + (s.anePower.map { String(format: "  power %.3f W", $0) } ?? "  power: not reported")
              + (s.aneTraffic.map { String(format: "  traffic %.2f GB/s", $0) } ?? ""))
        let gb = 1_073_741_824.0
        let m = s.memory
        print(String(format: "  memory     : used %.1f GB (app %.1f, wired %.1f, compressed %.1f), cached %.1f, free %.1f",
                     m.used / gb, m.app / gb, m.wired / gb, m.compressed / gb, m.cached / gb, m.free / gb))
        print("  pressure   : \(m.pressure.rawValue)  swap: \(String(format: "%.2f", m.swapUsed / gb)) GB")
        probeNeuralEngine()
    }

    /// Every IOReport channel whose group, subgroup or name mentions the Neural Engine, with
    /// its format, unit and one second of change: what this Mac offers for measuring it.
    static func probeNeuralEngine() {
        print("")
        print("IOReport channels mentioning the Neural Engine (1 s delta):")
        guard let all = IOReportCopyAllChannels(0, 0)?.takeRetainedValue() else {
            print("  IOReportCopyAllChannels unavailable"); return
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, all, &subbed, 0, nil),
              let subscribed = subbed?.takeRetainedValue(),
              let a = IOReportCreateSamples(sub, subscribed, nil)?.takeRetainedValue() else {
            print("  subscription failed"); return
        }
        Thread.sleep(forTimeInterval: 1.0)
        guard let b = IOReportCreateSamples(sub, subscribed, nil)?.takeRetainedValue(),
              let delta = IOReportCreateSamplesDelta(a, b, nil)?.takeRetainedValue() else {
            print("  sampling failed"); return
        }
        var found = 0
        IOReportIterate(delta) { channel in
            let group = (IOReportChannelGetGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            let name = (IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
            let text = (group + " " + subgroup + " " + name).uppercased()
            guard text.range(of: #"(^|[^A-Z])ANE"#, options: .regularExpression) != nil
                    || text.contains("NEURAL") else { return 0 }
            found += 1
            let format = IOReportChannelGetFormat(channel)
            let unit = (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String?) ?? ""
            var detail = ""
            if format == 1 {
                detail = "value \(IOReportSimpleGetIntegerValue(channel, nil)) \(unit)"
            } else if format == 2 {
                let n = IOReportStateGetCount(channel)
                detail = (0..<max(0, n)).map { i in
                    let state = (IOReportStateGetNameForIndex(channel, i)?.takeUnretainedValue() as String?) ?? "?"
                    return "\(state)=\(IOReportStateGetResidency(channel, i))"
                }.joined(separator: " ")
            }
            print("  [\(group)] [\(subgroup)] \(name)  format \(format)  \(detail)")
            return 0
        }
        if found == 0 { print("  (none)") }
    }
}
