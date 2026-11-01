import Foundation

struct IndexStoreProvider: CompileArgProvider {
    func arguments(for context: ArgContext) -> [String] {
        let indexStorePath = XcodeGlobalSettings(derivedDataPath: context.derivedDataPath).indexStoreURL
        return ["-index-store-path", indexStorePath.path]
    }
}
