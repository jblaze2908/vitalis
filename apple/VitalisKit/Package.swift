// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VitalisKit",
    platforms: [.iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "VitalisKit", targets: ["VitalisKit"]),
        .library(name: "VitalisUI", targets: ["VitalisUI"]),
    ],
    targets: [
        .target(name: "VitalisKit"),
        .target(name: "VitalisUI", resources: [.process("Fonts"), .copy("MuscleMap/LICENSE-react-native-body-highlighter.txt")]),
    ]
)
