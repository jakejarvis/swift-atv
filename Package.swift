// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftATV",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        .library(
            name: "SwiftATV",
            targets: ["SwiftATV"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.1"),
    ],
    targets: [
        .target(
            name: "SwiftATV",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "SwiftATVTests",
            dependencies: ["SwiftATV"]
        ),
    ]
)
