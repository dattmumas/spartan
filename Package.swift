// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Spartan",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SpartanCore",
            path: "Sources/SpartanCore"
        ),
        .executableTarget(
            name: "Spartan",
            dependencies: ["SpartanCore"],
            path: "Sources/Spartan"
        ),
        .executableTarget(
            name: "SpartanChecks",
            dependencies: ["SpartanCore"],
            path: "Sources/SpartanChecks"
        ),
    ]
)
