import SourceKitBSPProtocol
import XcodeProjectManagement

extension XcodeLanguageDialect {
    var asLanguage: Language? {
        switch self {
        case .c:
            .c
        case .cpp:
            .cpp
        case .objc:
            .objective_c
        case .objcCpp:
            .objective_cpp
        default:
            nil
        }
    }
}
