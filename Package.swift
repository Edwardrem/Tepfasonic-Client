// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tepfa",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TepfaCore", targets: ["TepfaCore"]),
        .library(name: "TepfaSSH", targets: ["TepfaSSH"]),
        .library(name: "TepfaTerminal", targets: ["TepfaTerminal"]),
        .library(name: "TepfaAgent", targets: ["TepfaAgent"]),
        .executable(name: "tepfasonic-mcp", targets: ["tepfasonic-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.2"),
    ],
    targets: [
        .target(name: "TepfaCore"),
        .target(
            name: "TepfaSSH",
            dependencies: [
                "TepfaCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(
            name: "TepfaTerminal",
            dependencies: [
                "TepfaCore",
                "TepfaSSH",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "TepfaAgent",
            dependencies: [
                "TepfaCore",
                "TepfaSSH",
                "TepfaTerminal",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "tepfasonic-mcp"),
        .testTarget(name: "TepfaCoreTests", dependencies: ["TepfaCore"]),
        .testTarget(name: "TepfaSSHTests", dependencies: ["TepfaSSH"]),
        .testTarget(name: "TepfaTerminalTests", dependencies: ["TepfaTerminal", "TepfaSSH", "TepfaCore"]),
        .testTarget(name: "TepfaAgentTests", dependencies: ["TepfaAgent", "TepfaTerminal", "TepfaSSH", "TepfaCore"]),
    ]
)
