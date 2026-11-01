//
//  Model.swift
//  Plain values shared by the app and the widget extension: one sample of the Mac's load.
//  (Kept apart from Sampler.swift so the widget builds without the IOReport module.)
//
import Foundation

enum Pressure: String {
    case normal = "Normal", warning = "Warning", critical = "Critical"
}

struct MemoryState {
    var total: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var pressure: Pressure = .normal

    var used: Double { app + wired + compressed }
    var free: Double { max(0, total - app - wired - compressed - cached) }
}

struct Snapshot {
    var cores: [Double] = []      // 0…1, indexed by CPU number
    var gpu: Double = 0           // 0…1
    var gpuMHz: Double?
    var ane: Double?              // 0…1, nil when this Mac does not report it
    var anePower: Double?         // W, from IOReport "Energy Model" (nil when not reported)
    var aneEstimated = false      // `ane` derived from a proxy (bandwidth floor or power)
    var aneTraffic: Double?       // GB/s the engine moved through the fabric (nil when not reported)
    var memory = MemoryState()
    var valid = false             // false until two CPU samples exist
}
