// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Solitaire",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SolitaireCore", targets: ["SolitaireCore"]),
        .executable(name: "Solitaire", targets: ["Solitaire"]),
    ],
    targets: [
        .target(name: "SolitaireCore"),
        .executableTarget(
            name: "Solitaire",
            dependencies: ["SolitaireCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .testTarget(name: "SolitaireCoreTests", dependencies: ["SolitaireCore"]),
    ]
)
