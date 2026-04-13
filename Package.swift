// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-atv",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        .library(
            name: "SwiftATV",
            targets: ["SwiftATV"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.1"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftATV",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            exclude: [
                "swift-protobuf-config.json",
                "Protocols/MRP/Protobuf",
            ]
        ),
        .testTarget(
            name: "SwiftATVTests",
            dependencies: ["SwiftATV"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
