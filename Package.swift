// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Within",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Within", targets: ["WithinApp"])],
    dependencies: [.package(path: "Vendor/FluidAudio", traits: [])],
    targets: [
        .target(name: "WithinAudioBuffer", publicHeadersPath: "include"),
        .target(name: "WithinCore", dependencies: ["WithinAudioBuffer"]),
        .executableTarget(name: "WithinApp", dependencies: ["WithinCore", .product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")]),
        .testTarget(name: "WithinCoreTests", dependencies: ["WithinCore"])
    ],
    swiftLanguageModes: [.v5]
)
