// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to
// build this package.

import PackageDescription

let multiPlatformTargets: [Target] = [
    .target(
        name: "JSONRPCConnection",
        dependencies: ["Logger"]
    ),
    .target(
        name: "Logger",
        dependencies: [
            .product(
                name: "SwiftyBeaver",
                package: "SwiftyBeaver"
            ),
        ]
    ),
    .target(
        name: "Support",
        dependencies: [
            "Logger",
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    .target(
        name: "BuildServerProtocol",
        dependencies: [
            "Logger"
        ]
    ),
    .target(
        name: "SwiftPMProjectManagerProvider",
        dependencies: [
            "Logger",
            "BuildServerProtocol",
        ]
    ),
    .executableTarget(
        name: "sourcekit-bsp",
        dependencies: [
            "BSPServer",
            "Logger",
        ]
    ),
    .testTarget(
        name: "SwiftPMProjectManagerProviderTests",
        dependencies: [
            "SwiftPMProjectManagerProvider"
        ]
    ),
    .testTarget(
        name: "BSPServerTests",
        dependencies: [
            "BSPServer",
            "JSONRPCConnection",
            "BuildServerProtocol",
        ]
    ),
]

#if os(macOS)
let bspServerTarget: Target = .target(
    name: "BSPServer",
    dependencies: [
        "Logger",
        "JSONRPCConnection",
        "SwiftPMProjectManagerProvider",
        "BuildServerProtocol",
        "Support",
        "XcodeProjectManagerProvider",
    ]
)
#else
let bspServerTarget: Target = .target(
    name: "BSPServer",
    dependencies: [
        "Logger",
        "JSONRPCConnection",
        "SwiftPMProjectManagerProvider",
        "BuildServerProtocol",
        "Support",
    ]
)
#endif

let multiPlatformProducts: [Product] = [
    .library(name: "Support", targets: ["Logger"]),
    .library(name: "JSONRPCConnection", targets: ["JSONRPCConnection"]),
    .library(name: "Logger", targets: ["Logger"]),
    .library(name: "BuildServerProtocol", targets: ["BuildServerProtocol"]),
    .library(
        name: "SwiftPMProjectManagerProvider",
        targets: ["SwiftPMProjectManagerProvider"]
    ),
    .library(name: "BSPServer", targets: ["BSPServer"]),
    .executable(
        name: "sourcekit-bsp",
        targets: ["sourcekit-bsp"]
    ),
]

#if os(macOS)
let macOnlyTargets: [Target] = [
    .target(
        name: "XcodeProjectManagement",
        dependencies: [
            "Logger",
            "BuildServerProtocol",
            "Support",
            .product(
                name: "XcodeProj",
                package: "XcodeProj"
            ),
        ],
        path: "Sources-MacOS/XcodeProjectManagement",
        resources: [
            .copy("README.md"),
        ],
        swiftSettings: [
            .define("MACOS_ONLY", .when(platforms: [.macOS]))
        ]
    ),
    .target(
        name: "XcodeProjectManagerProvider",
        dependencies: [
            "XcodeProjectManagement",
            "BuildServerProtocol"
        ],
        path: "Sources-MacOS/XcodeProjectManagerProvider",
        swiftSettings: [
            .define("MACOS_ONLY", .when(platforms: [.macOS]))
        ]
    ),
    .executableTarget(
        name: "XcodeProjectCLI",
        dependencies: [
            "Logger",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            "XcodeProjectManagerProvider",
        ],
        path: "Sources-MacOS/XcodeProjectCLI",
        swiftSettings: [
            .define("MACOS_ONLY", .when(platforms: [.macOS]))
        ]
    ),
    .testTarget(
        name: "XcodeProjectManagementTests",
        dependencies: [
            "XcodeProjectManagement"
        ],
        path: "Tests-MacOS/XcodeProjectManagementTests",
        resources: [
            .copy("README.md"),
            .copy("Resources")
        ]
    ),
    .testTarget(
        name: "XcodeProjectManagerProviderTests",
        dependencies: [
            "XcodeProjectManagerProvider"
        ],
        path: "Tests-MacOS/XcodeProjectManagerProviderTests",
    )
]

let macOnlyProducts: [Product] = [
    .library(
        name: "XcodeProjectManagerProvider",
        targets: ["XcodeProjectManagerProvider"]
    ),
    .library(
        name: "XcodeProjectManagement",
        targets: ["XcodeProjectManagement"]
    ),
    .executable(
        name: "XcodeProjectCLI",
        targets: ["XcodeProjectCLI"]
    ),
]

#endif

let targets: [Target] = {
    #if os(macOS)
    return multiPlatformTargets + [bspServerTarget] + macOnlyTargets
    #else
    return multiPlatformTargets + [bspServerTarget]
    #endif
}()

let products: [Product] = {
    #if os(macOS)
    return multiPlatformProducts + macOnlyProducts
    #else
    return multiPlatformProducts
    #endif
}()

let dependencies: [PackageDescription.Package.Dependency] = [
    .package(
        url: "https://github.com/SwiftyBeaver/SwiftyBeaver.git",
        from: "2.0.0"
    ),
    .package(
        url: "https://github.com/tuist/XcodeProj.git",
        .upToNextMajor(from: "8.12.0")
    ),
    .package(
        url: "https://github.com/apple/swift-argument-parser",
        from: "1.6.1"
    ),
    .package(
        url: "https://github.com/apple/swift-crypto.git",
        from: "3.0.0"
    )
]

let package = Package(
    name: "sourcekit-bsp",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
