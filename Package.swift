// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BolBhAI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BolBhAICore", targets: ["BolBhAICore"]),
        .executable(name: "bolbhai-benchmark", targets: ["BolBhAIBenchmark"]),
        .executable(name: "BolBhAI", targets: ["BolBhAI"]),
        .executable(name: "bolbhai-checks", targets: ["BolBhAICoreChecks"])
    ],
    targets: [
        .target(name: "BolBhAICore"),
        .executableTarget(name: "BolBhAIBenchmark", dependencies: ["BolBhAICore"]),
        .executableTarget(name: "BolBhAI", dependencies: ["BolBhAICore"]),
        .executableTarget(name: "BolBhAICoreChecks", dependencies: ["BolBhAICore"], path: "Tests/BolBhAICoreTests")
    ]
)
