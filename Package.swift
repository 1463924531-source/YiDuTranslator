// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "YiDuTranslator",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "YiDuTranslator", targets: ["TranslatorApp"]),
        .library(name: "TranslatorCore", targets: ["TranslatorCore"])
    ],
    targets: [
        .target(name: "TranslatorCore"),
        .executableTarget(name: "TranslatorApp", dependencies: ["TranslatorCore"]),
        .testTarget(name: "TranslatorCoreTests", dependencies: ["TranslatorCore"])
    ]
)
