// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouteWeaver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RouteWeaver", targets: ["RouteWeaver"]),
        .executable(name: "RouteWeaverHelper", targets: ["RouteHelper"]),
        .library(name: "RouteCore", targets: ["RouteCore"])
    ],
    targets: [
        .target(name: "RouteCore"),
        .target(name: "RouteDNS", dependencies: ["RouteCore"]),
        .target(name: "CRouteSocket", publicHeadersPath: "include"),
        .target(name: "CRouteStatistics", publicHeadersPath: "include"),
        .target(name: "RouteIPC"),
        .executableTarget(name: "RouteHelper", dependencies: ["RouteCore", "CRouteSocket", "RouteIPC", "RouteDNS"]),
        .executableTarget(name: "RouteWeaver", dependencies: ["RouteCore", "RouteIPC", "CRouteSocket", "CRouteStatistics"], resources: [.copy("Resources/cn-ipv4.txt")]),
        .testTarget(name: "RouteCoreTests", dependencies: ["RouteCore"]),
        .testTarget(name: "RouteDNSTests", dependencies: ["RouteDNS"]),
        .testTarget(name: "RouteAppTests", dependencies: ["RouteWeaver"]),
        .testTarget(name: "RouteHelperTests", dependencies: ["RouteHelper"]),
        .testTarget(name: "RouteIPCTests", dependencies: ["RouteIPC"])
    ],
    swiftLanguageModes: [.v5]
)
