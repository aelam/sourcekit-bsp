import Foundation

struct SwiftFilesProvider: CompileArgProvider {
    func arguments(for context: ArgContext) -> [String] {
        guard context.compiler == .swift else { return [] }
        let primaryFileURL = context.fileURL

        // Provide the necessary arguments for Swift files
        let sourceItems = context.sourceItems

        guard !sourceItems.isEmpty else {
            return []
        }

        // Generate Swift File List
        var fileList: [String] = []
        for item in sourceItems {
            if item.itemKind == .file, item.path.pathExtension == "swift" {
                fileList.append(item.path.path)
            } else {
                let filePaths = (try? FileManager.default.contentsOfDirectory(
                    at: item.path,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                filePaths.filter { url in
                    url.pathExtension == "swift"
                }
                .forEach { file in
                    fileList.append(file.path)
                }
            }
        }

        if let primaryFileURL {
            var fileSet = Set(fileList)
            fileSet.remove(primaryFileURL.path)
            fileList = fileSet.sorted()
            fileList.insert(primaryFileURL.path, at: 0)
        }

        return fileList
    }
}
