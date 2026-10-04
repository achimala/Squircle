import Foundation

struct HermesAttachment: Equatable {
    let reference: String
    let name: String
    let image: Bool

    static func parse(_ text: String) -> [Self] {
        var result: [Self] = []
        let patterns = [#"(?m)^@image:(?:\"([^\"]+)\"|([^\n]+))"#, #"(!?)\[([^\]]*)\]\(<?([^\n>]+?)>?\)"#, #"(?m)^(data:image/[^\s]+)$"#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                func group(_ n: Int) -> String { Range(match.range(at: n), in: text).map { String(text[$0]) } ?? "" }
                let ref = index == 0 ? (group(1).isEmpty ? group(2) : group(1)) : index == 1 ? group(3) : group(1)
                let isImage = index != 1 || group(1) == "!"
                guard isImage || ref.hasPrefix("/") || ref.hasPrefix("file://") || ref.hasPrefix("sandbox:/") else { continue }
                let name = index == 1 && !group(2).isEmpty ? group(2) : ref.hasPrefix("data:") ? "Image" : URL(fileURLWithPath: ref).lastPathComponent
                let attachment = Self(reference: ref, name: name, image: isImage)
                if !result.contains(where: { $0.reference == ref }) { result.append(attachment) }
            }
        }
        return result
    }

    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^@image:.*$|!\[[^\]]*\]\(<?[^\n>]+?>?\)|(?m)^data:image/[^\s]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
