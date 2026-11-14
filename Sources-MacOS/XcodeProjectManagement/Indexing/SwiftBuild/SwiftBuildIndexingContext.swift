import Foundation
import SwiftBuild

/// Settings and caches for the active indexing build context.
struct SwiftBuildIndexingContext {
    let buildContext: XcodeIndexingSelection?
    let version = UUID()
    let request: SWBBuildRequest
    var plans = SwiftBuildIndexingPlanCache()
    var arguments = SwiftBuildIndexingArgumentsCache()
    private(set) var preparationGeneration = UUID()

    init(snapshot: XcodeProjectSnapshot, buildContext: XcodeIndexingSelection?) {
        self.buildContext = buildContext
        self.request = Self.makeRequest(snapshot: snapshot, buildContext: buildContext)
    }

    mutating func invalidateInputs(preservingArguments: Bool) {
        preparationGeneration = UUID()
        if !preservingArguments { arguments.invalidate() }
    }

    private static func makeRequest(
        snapshot: XcodeProjectSnapshot, buildContext: XcodeIndexingSelection?
    ) -> SWBBuildRequest {
        let arena = snapshot.xcodeGlobalSettings.derivedDataPath.appendingPathComponent("Index.noindex")
        var request = SWBBuildRequest()
        request.parameters.configurationName = buildContext?.configuration ?? snapshot.configuration
        request.parameters.action = "indexbuild"
        request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)
        request.enableIndexBuildArena = true
        request.continueBuildingAfterErrors = true
        request.parameters.arenaInfo = SWBArenaInfo(
            derivedDataPath: snapshot.xcodeGlobalSettings.derivedDataPath.path,
            buildProductsPath: arena.appendingPathComponent("Build/Products").path,
            buildIntermediatesPath: arena.appendingPathComponent("Build/Intermediates.noindex").path,
            pchPath: arena.appendingPathComponent("Build/Intermediates.noindex/PrecompiledHeaders").path,
            indexRegularBuildProductsPath: snapshot.xcodeGlobalSettings.symRoot.path,
            indexRegularBuildIntermediatesPath: snapshot.xcodeGlobalSettings.objRoot.path,
            indexPCHPath: arena.appendingPathComponent("PrecompiledHeaders").path,
            indexDataStoreFolderPath: snapshot.xcodeGlobalSettings.indexStoreURL.path,
            indexEnableDataStore: true
        )
        let platforms = Set(snapshot.xcodeTargets.map(\.xcodeTargetPlatform.simulatorVariant.rawValue))
        let platform = buildContext?.platform
            ?? (platforms.count == 1 ? platforms.first! : "iphonesimulator")
        #if arch(arm64)
        let hostArchitecture = "arm64"
        #else
        let hostArchitecture = "x86_64"
        #endif
        let deviceArchitecture = platform == "watchos" ? "arm64_32" : "arm64"
        let architecture = buildContext?.architecture
            ?? (platform == "macosx" || platform.hasSuffix("simulator") ? hostArchitecture : deviceArchitecture)
        request.parameters.activeRunDestination = SWBRunDestinationInfo(
            platform: platform, sdk: platform, sdkVariant: nil, targetArchitecture: architecture,
            supportedArchitectures: [architecture], disableOnlyActiveArch: false
        )
        var overrides = SWBSettingsTable()
        overrides.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
        overrides.set(value: "NO", for: "INDEX_ENABLE_OPTIMIZATION_LEVEL_OVERRIDE")
        overrides.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
        request.parameters.overrides.commandLine = overrides
        return request
    }
}
