// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentWorkspaceKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AgentWorkspaceKit", targets: ["AgentWorkspaceKit"])],
    targets: [
        .target(name: "AgentWorkspaceKit"),
        .testTarget(name: "AgentWorkspaceKitTests", dependencies: ["AgentWorkspaceKit"], resources: [.copy("Fixtures")])
    ]
)
