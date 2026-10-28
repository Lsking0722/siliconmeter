// swift-tools-version:5.9
//
// SiliconMeter — Apple Silicon menu bar monitor drawn as a live die diagram.
//
// IOReport is a private framework with no SDK stub, so the executable links with
// `-undefined dynamic_lookup` and the symbols resolve at runtime from the dyld shared
// cache (same approach as SiliconScope, MIT). This rules out the Mac App Store; fine for
// personal / GitHub distribution.
//
import PackageDescription

let package = Package(
    name: "SiliconMeter",
    platforms: [.macOS(.v13)],
    targets: [
        // Private IOReport declarations exposed to Swift.
        .target(name: "CIOReport"),

        .executableTarget(
            name: "SiliconMeter",
            dependencies: ["CIOReport"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
