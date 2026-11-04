import Foundation

struct SDKStatCacheProvider: CompileArgProvider, Sendable {
    func arguments(for context: ArgContext) -> [String] {
        guard
            let buildVersion = context.buildSettings["SDK_BUILD_VERSION"],
            let sdkPath = context.buildSettings["SDKROOT_PATH"],
            let platformName = context.buildSettings["PLATFORM_NAME"],
            let sdkVersion = sdkBundleVersion(from: sdkPath)
        else {
            return []
        }

        let sdkStatCachesDir = context.derivedDataPath
            .deletingLastPathComponent()
            .appendingPathComponent("SDKStatCaches.noindex")

        let filePrefix = "\(platformName)\(sdkVersion)-\(buildVersion)-"
        let fileSuffix = "\(sdkPath.md5()).sdkstatcache"
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: sdkStatCachesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            let name = url.lastPathComponent
            let isRegularFile = try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile
            return name.hasPrefix(filePrefix) &&
                name.hasSuffix(fileSuffix) &&
                isRegularFile == true
        } ?? []

        guard candidates.count == 1, let sdkStatCache = candidates.first else {
            return []
        }

        if context.compiler == .clang {
            return [
                "-ivfsstatcache",
                sdkStatCache.path
            ]
        } else {
            return [
                "-Xcc", "-ivfsstatcache",
                "-Xcc", sdkStatCache.path
            ]
        }
    }

    private func sdkBundleVersion(from sdkPath: String) -> String? {
        let sdkName = URL(fileURLWithPath: sdkPath)
            .deletingPathExtension()
            .lastPathComponent
        guard let versionStart = sdkName.firstIndex(where: { $0.isNumber }) else {
            return nil
        }
        return String(sdkName[versionStart...])
    }
}
