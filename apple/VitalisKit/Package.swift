// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VitalisKit",
    platforms: [.iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "VitalisKit", targets: ["VitalisKit"])],
    targets: [.target(name: "VitalisKit")]
)
