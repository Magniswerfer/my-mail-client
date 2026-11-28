// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MailEngine",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MailEngine", targets: ["MailEngine"]),
        .executable(name: "tidings-probe", targets: ["tidings-probe"]),
        .executable(name: "tidings-bench", targets: ["tidings-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "MailEngine",
            dependencies: [
                .product(name: "IMAPCommands", package: "swift-nio-imap"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "tidings-probe",
            dependencies: [
                "MailEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // SPEC §15 budgets, checked in CI (docs/performance.md).
        .executableTarget(
            name: "tidings-bench",
            dependencies: [
                "MailEngine",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "MailEngineTests", dependencies: ["MailEngine"]),
    ]
)
