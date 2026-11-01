//
//  PathHash.swift
//  sourcekit-bsp
//
//  Created by wang.lun on 2025/08/23.
//

import CryptoKit
import Foundation

public enum PathHash {
    public static func derivedDataFullPath(for projectOrWorkspacePath: String) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        return base.appendingPathComponent(derivedDataFolderName(for: projectOrWorkspacePath))
    }

    static func hashStringForPath(_ projectOrWorkspacePath: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(projectOrWorkspacePath.utf8))
        let bytes = [UInt8](digest) // 16 bytes

        /// 2) 拆成两个 64 位块并做字节序翻转（等价于 C 里的 swap_uint64）
        func loadSwapped64(_ offset: Int) -> UInt64 {
            bytes.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt64.self).byteSwapped
            }
        }
        var left = loadSwapped64(0)
        var right = loadSwapped64(8)

        /// 3) 把 64 位整数转为 14 位 a–z（26 进制）
        func base26Letters(_ v: inout UInt64) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 14)
            for i in stride(from: 13, through: 0, by: -1) {
                out[i] = UInt8((v % 26) + 97) // 97 == Character("a").asciiValue!
                v /= 26
            }
            return out
        }
        let left14 = base26Letters(&left)
        let right14 = base26Letters(&right)

        return String(bytes: left14 + right14, encoding: .utf8)!
    }

    /// DerivedData folderName：<Name>-<28letters>
    private static func derivedDataFolderName(for projectOrWorkspacePath: String) -> String {
        let name = URL(fileURLWithPath: projectOrWorkspacePath)
            .deletingPathExtension().lastPathComponent
        return "\(name)-\(hashStringForPath(projectOrWorkspacePath))"
    }
}
