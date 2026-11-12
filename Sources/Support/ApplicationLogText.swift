import Foundation

public enum ApplicationLogText {
    public static func forBuildLog(_ text: String, standardError: Bool) -> String {
        var message = text
        if standardError,
           let range = text.range(
               of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3,9}(?:[+-]\d{4})? (?=[^\s\[]+\[\d+:[^\]]+\] )"#,
               options: .regularExpression
           ) {
            message = String(text[range.upperBound...])
        }
        if message.hasSuffix("\n") { message.removeLast() }
        return message
    }
}
