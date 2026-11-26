// swift-tools-version: 6.2
import PackageDescription

// The always-on push server (ADR 0007): MailEngine on Linux, one IMAP IDLE per account, APNs
// for new mail, server-side snooze wake-ups and send-later. A separate package so the apps'
// dependency graph never pulls in server libraries.
let package = Package(
    name: "PushServer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "tidings-server", targets: ["tidings-server"]),
    ],
    dependencies: [
        .package(path: "../MailEngine"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(
            name: "TidingsPush",
            dependencies: [
                .product(name: "MailEngine", package: "MailEngine"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(name: "tidings-server", dependencies: ["TidingsPush"]),
        .testTarget(
            name: "TidingsPushTests",
            dependencies: [
                "TidingsPush",
                .product(name: "MailEngine", package: "MailEngine"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "APNSTestServer", package: "APNSwift"),
            ]
        ),
    ]
)
