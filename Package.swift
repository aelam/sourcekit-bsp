// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to
// build this package.

import Foundation
import PackageDescription

#if os(macOS)
let swiftBuildEnabled = ProcessInfo.processInfo.environment["SOURCEKIT_BSP_SWIFT_BUILD"] == "1"
#else
let swiftBuildEnabled = false
#endif

let swiftBuildDependencies: [Target.Dependency] = swiftBuildEnabled ? [
    .product(
        name: "SwiftBuild", package: "swift-build"
    ),
] : []

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
        name: "SourceKitBSPProtocol",
        dependencies: [
            "Logger"
        ],
        path: "Sources/BuildServerProtocol"
    ),
    .target(
        name: "SwiftPMProjectManagerProvider",
        dependencies: [
            "Logger",
            "SourceKitBSPProtocol",
            "Support",
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
            "BSPServer"
        ]
    ),
]

#if os(macOS)
let sourceKitBSPTarget: Target = .executableTarget(
    name: "sourcekit-bsp",
    dependencies: [
        "BSPServer",
        "Logger",
        "XcodeProjectManagerProvider",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ] + (swiftBuildEnabled ? [.product(name: "SWBBuildServiceBundle", package: "swift-build")] : [])
)

let bspServerTarget: Target = .target(
    name: "BSPServer",
    dependencies: [
        "Logger",
        "JSONRPCConnection",
        "SwiftPMProjectManagerProvider",
        "SourceKitBSPProtocol",
        "Support",
        "XcodeProjectManagerProvider",
        "XcodeProjectManagement",
    ]
)
#else
let sourceKitBSPTarget: Target = .executableTarget(
    name: "sourcekit-bsp",
    dependencies: [
        "BSPServer",
        "Logger",
    ]
)

let bspServerTarget: Target = .target(
    name: "BSPServer",
    dependencies: [
        "Logger",
        "JSONRPCConnection",
        "SwiftPMProjectManagerProvider",
        "SourceKitBSPProtocol",
        "Support",
    ]
)
#endif

let multiPlatformProducts: [Product] = [
    .library(name: "Support", targets: ["Logger"]),
    .library(name: "JSONRPCConnection", targets: ["JSONRPCConnection"]),
    .library(name: "Logger", targets: ["Logger"]),
    .library(name: "SourceKitBSPProtocol", targets: ["SourceKitBSPProtocol"]),
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
            "SourceKitBSPProtocol",
            "Support",
            .product(
                name: "XcodeProj",
                package: "XcodeProj"
            ),
        ] + swiftBuildDependencies,
        path: "Sources-MacOS/XcodeProjectManagement",
        resources: [
            .copy("README.md"),
        ],
        swiftSettings: [
            .define("MACOS_ONLY", .when(platforms: [.macOS]))
        ] + (swiftBuildEnabled ? [.define("SWIFT_BUILD_INDEXING")] : [])
    ),
    .target(
        name: "XcodeProjectManagerProvider",
        dependencies: [
            "XcodeProjectManagement",
            "SourceKitBSPProtocol"
        ],
        path: "Sources-MacOS/XcodeProjectManagerProvider",
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
            .copy("Resources/DemoProjects"),
            .copy("Resources/TestScheme.xcscheme")
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
]

#endif

let targets: [Target] = {
    #if os(macOS)
    return multiPlatformTargets + [bspServerTarget, sourceKitBSPTarget] + macOnlyTargets
    #else
    return multiPlatformTargets + [bspServerTarget, sourceKitBSPTarget]
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
] + (swiftBuildEnabled ? [
    .package(
        url: "https://github.com/swiftlang/swift-build.git",
        revision: "2d847030c63961cb1cf8cbb6ad2bc7245fdfeb09"
    ),
] : [])

let package = Package(
    name: "sourcekit-bsp",
    platforms: [.macOS(swiftBuildEnabled ? .v15 : .v13)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
