// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Linker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Linker", targets: ["Linker"]),
        .library(name: "LinkerCore", targets: ["LinkerCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "LinkerCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Linker", dependencies: ["LinkerCore"]),
        .executableTarget(name: "LinkerChecks", dependencies: ["LinkerCore"]),
    ]
)
