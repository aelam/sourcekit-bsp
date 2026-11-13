import SourceKitBSPProtocol
import XcodeProjectManagement

extension Language {
    init?(xcodeLanguageDialect: XcodeLanguageDialect?, fileExtension: String) {
        switch xcodeLanguageDialect {
        case .c:
            self = .c
        case .cpp:
            self = .cpp
        case .swift:
            self = .swift
        case .objc:
            self = .objective_c
        case .objcCpp:
            self = .objective_cpp
        case .metal:
            return nil
        case .interfaceBuilder:
            self = .xml
        case .other, .none:
            guard let language = Self.detectLanguageFromExtension(fileExtension) else {
                return nil
            }
            self = language
        }
    }

    private static func detectLanguageFromExtension(_ ext: String) -> Language? {
        switch ext.lowercased() {
        case "swift":
            .swift
        case "c":
            .c
        case "cpp", "cc", "cxx", "c++":
            .cpp
        case "m":
            .objective_c
        case "mm":
            .objective_cpp
        case "h", "hpp", "hxx", "h++":
            .c // Could be C or C++, default to C
        default:
            nil
        }
    }
}
