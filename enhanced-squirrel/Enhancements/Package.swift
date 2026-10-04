// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "EnhancementCore", targets: ["EnhancementCore"])]
var targets: [Target] = [.target(name: "EnhancementCore"),
    .testTarget(name: "EnhancementCoreTests", dependencies: ["EnhancementCore"],resources:[.process("Fixtures")])]
#if os(macOS)
products += [.library(name: "EnhancementIPC", targets: ["EnhancementIPC"]),
             .library(name: "EnhancementUI", targets: ["EnhancementUI"]),
             .executable(name: "SquirrelVoiceHelper", targets: ["VoiceHelper"])]
targets += [.target(name: "EnhancementIPC", dependencies: ["EnhancementCore"]),
            .target(name: "EnhancementUI", dependencies: ["EnhancementCore", "EnhancementIPC"]),
            .executableTarget(name: "VoiceHelper", dependencies: ["EnhancementCore", "EnhancementIPC", "EnhancementUI"])]
#endif
let package = Package(name: "SquirrelEnhancements", platforms: [.macOS(.v13)], products: products, targets: targets)
