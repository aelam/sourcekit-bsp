//
//  BuildSettingKey.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/26.
//

import Foundation
import XcodeProj

enum BuildSettingKey: String, CaseIterable {
    // MARK: - CLANG

    case clangAnalyzerNumberObjectConversion =
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION" // YES_AGGRESSIVE;
    case clangAnalyzerNonnull = "CLANG_ANALYZER_NONNULL"
    case clangCXXLanuageStandard = "CLANG_CXX_LANGUAGE_STANDARD" // = "gnu++14";
    case clangEnableObjWeak = "CLANG_ENABLE_OBJC_WEAK" // = YES;
    case clangEnableModules = "CLANG_ENABLE_MODULES" // = YES;
    case clangEnableObjArc = "CLANG_ENABLE_OBJC_ARC" // = YES;

    // MARK: - CLANG WARN

    case clangWarnConstantConversion = "CLANG_WARN_CONSTANT_CONVERSION"
    case clangWarnDuplicateMethodMatch = "CLANG_WARN__DUPLICATE_METHOD_MATCH"
    case clangWarnEmptyBody = "CLANG_WARN_EMPTY_BODY"
    case clangWarnEnumConversion = "CLANG_WARN_ENUM_CONVERSION"
    case clangWarnInifiniteRecursion = "CLANG_WARN_INFINITE_RECURSION"
    case clangWarnNonLiteralNullConversion = "CLANG_WARN_NON_LITERAL_NULL_CONVERSION"
    case clangWarnObjCRootClass = "CLANG_WARN_OBJC_ROOT_CLASS"
    case clangWarnObjCImplicitRetainSelf = "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF"
    case clangWarnQuotedIncludeInFrameworkHeader = "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER"
    case clangWarnStrictProtoptypes = "CLANG_WARN_STRICT_PROTOTYPES"
    case clangWarnSuspiciousMove = "CLANG_WARN_SUSPICIOUS_MOVE"
    case clangWarnUngardedAvailability = "CLANG_WARN_UNGUARDED_AVAILABILITY"
    case clangWarnDocumentationComments = "CLANG_WARN_DOCUMENTATION_COMMENTS"
    case clangWarnBlockCaptureAutoreleasing = "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING"
    case clangWarnRangeLoopAnalysis = "CLANG_WARN_RANGE_LOOP_ANALYSIS"

    // MARK: - GCC

    case gccCLanguageStandard = "GCC_C_LANGUAGE_STANDARD" // = gnu11;
    case gccNoCommonBlocks = "GCC_NO_COMMON_BLOCKS"

    // MARK: - GCC warning

    case gccWarn64to32BitConversion = "GCC_WARN_64_TO_32_BIT_CONVERSION"
    case gccWarnAboutReturnType = "GCC_WARN_ABOUT_RETURN_TYPE"
    case gccWarnDeprecatedObjcImplementation = "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS"
    case gccWarnUnitializedAutos = "GCC_WARN_UNINITIALIZED_AUTOS"
    case gccWarnUndeclaredSelector = "GCC_WARN_UNDECLARED_SELECTOR"
    case gccWarnUnusedFunction = "GCC_WARN_UNUSED_FUNCTION"
    case gccWarnUnusedVariable = "GCC_WARN_UNUSED_VARIABLE"

    // MARK: - SDK

    case deploymentTargetSettingName =
        "DEPLOYMENT_TARGET_SETTING_NAME" // "IPHONEOS_DEPLOYMENT_TARGET"
    case iPhoneDeploymentTarget = "IPHONEOS_DEPLOYMENT_TARGET" // 18.5
    case archs = "ARCHS" // = $(inherited) arm64

    // MARK: - toolchain

    // /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain;
    case toolchainDir = "TOOLCHAIN_DIR"
    case toolchains = "TOOLCHAINS" // "com.apple.dt.toolchain.XcodeDefault";

    // MARK: - swift

    case swiftVersion = "SWIFT_VERSION" // 5.0
    case swiftCompilationMode = "SWIFT_COMPILATION_MODE" // "wholemodule"
    case swiftObjCBridgingHeader =
        "SWIFT_OBJC_BRIDGING_HEADER" // World/World1-Bridging-Header.h

    case enableModuleVerifier = "ENABLE_MODULE_VERIFIER"
    case alwaysSearchUserPaths = "ALWAYS_SEARCH_USER_PATHS" // NO
    case ldRunPathSearchPaths =
        "LD_RUNPATH_SEARCH_PATHS" // = ( "$(inherited)",
    /// "@executable_path/Frameworks",
    /// "@executable_path/../../Frameworks",);
    case productBundleIdentifier =
        "PRODUCT_BUNDLE_IDENTIFIER" // = com.example.app.shareextension;

    /// Dynamic/implicit
    case batchMode = "BATCH_MODE"
    // -target arm64-apple-ios18.5 ← ARCHS + SDKROOT +
    // IPHONEOS_DEPLOYMENT_TARGET
    case targetTriple = "TARGET_TRIPLE"
    case enforceExclusivityFlag =
        "ENFORCE_EXCLUSIVITY_FLAG" // -enforce-exclusivity=checked if -Onone
    case enableTestability = "ENABLE_TESTABILITY" // -enable-testing

    /// -DDEBUG
    case swiftActiveCompilationConditions = "SWIFT_ACTIVE_COMPILATION_CONDITIONS"

    case configuration = "CONFIGURATION" // = Debug | Release

    /// ${derivedDataPath}/Build/Products/Debug-iphoneos
    case configurationBuildDir = "CONFIGURATION_BUILD_DIR"

    /// ${derivedDataPath}/Build/Intermediates.noindex/<ProjectName>.build/<Configuration>-<SDK>/<TargetName>.build
    case configurationTempDir = "CONFIGURATION_TEMP_DIR"

    // BUILT_PRODUCTS_DIR
    case builtProductsDir = "BUILT_PRODUCTS_DIR"
    case buildVariants = "BUILD_VARIANTS" // normal
    case buildRoot = "BUILD_ROOT" // ${derivedDataPath}/Build/Products

    case platformName = "PLATFORM_NAME" // iphoneos

    // MARK: - product

    case productName = "PRODUCT_NAME"
    case targetName = "TARGET_NAME"

    case productModuleName = "PRODUCT_MODULE_NAME" //
    // ${derivedDataPath}/Build/Intermediates.noindex/${PROJECT}.build/DerivedSources
    case projectDerivedFileDir = "PROJECT_DERIVED_FILE_DIR"
    case project = "PROJECT"

    case projectDir = "PROJECT_DIR"
    /// ${derivedDataPath}/Build/Intermediates.noindex/${PROJECT}.build",
    case projectTempDir = "PROJECT_TEMP_DIR"
    /// ${derivedDataPath}/Build/Intermediates.noindex"
    case projectTempRoot = "PROJECT_TEMP_ROOT"

    // MARK: - SDK

    /// -sdk /.../iPhoneOS18.5.sdk
    case sdkRoot = "SDKROOT" // = iphoneos;
    /// ${derivedDataPath}/Build/Products
    case symRoot = "SYMROOT"

    // MARK: - SDK_STAT_CACHE

    case sdkStatCacheEnable = "SDK_STAT_CACHE_ENABLE"
    /// "${HOME}/Library/Developer/Xcode/DerivedData"
    case sdkStatCacheDir = "SDK_STAT_CACHE_DIR"
    /// ${sdkStatCacheDir}/SDKStatCaches.noindex/{sdkRoot}{iPhoneDeploymentTarget}-22F76-7fa4eea80a99bbfdc046826b63ec4baf.sdkstatcache
    case sdkStatCachePath = "SDK_STAT_CACHE_PATH"
}
