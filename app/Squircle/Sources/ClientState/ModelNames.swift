import Foundation

/// How T3's provider models are named and ordered in Squircle's menus.
enum ModelNames {
    /// Models the picker offers, one section per provider: short names
    /// ("Opus 5.5", not "Claude Opus 5.5"), newest version first and, within
    /// a version, larger models first.
    static func menu(_ providers: [JSONValue]) -> [(title: String, choices: [(selection: JSONValue, name: String)])] {
        providers.map { provider in
            let maker = provider["displayName"].string ?? ""
            let choices = provider["models"].array.enumerated().compactMap { index, option -> (JSONValue, String, Int)? in
                guard let slug = option["slug"].string, let instance = provider["instanceId"].string else { return nil }
                return (["instanceId": .string(instance), "model": .string(slug)], short(option["name"].string ?? slug, maker: maker), index)
            }.sorted { a, b in
                let x = rank(a.1 + " " + (a.0["model"].string ?? "")), y = rank(b.1 + " " + (b.0["model"].string ?? ""))
                if x.version != y.version { return x.version > y.version }
                if x.size != y.size { return x.size > y.size }
                return a.2 < b.2
            }.map { (selection: $0.0, name: $0.1) }
            return (maker, choices)
        }
    }
    /// "Claude Opus 5.5" from provider "Claude" → "Opus 5.5".
    static func short(_ name: String, maker: String) -> String {
        guard !maker.isEmpty, name.lowercased().hasPrefix(maker.lowercased() + " ") else { return name }
        return String(name.dropFirst(maker.count + 1))
    }
    /// Version number in a model name and a rough size from its family word.
    static func rank(_ text: String) -> (version: Double, size: Int) {
        let lower = text.lowercased()
        var version = 0.0
        if let range = lower.range(of: #"\d+(?:[.\-]\d+)?"#, options: .regularExpression) {
            version = Double(lower[range].replacingOccurrences(of: "-", with: ".")) ?? 0
        }
        let sizes: [(String, Int)] = [("fable", 5), ("opus", 4), ("sol", 4), ("sonnet", 3), ("astra", 3), ("luna", 2),
                                      ("haiku", 1), ("flash", 1), ("mini", 1), ("nano", 0)]
        let size = sizes.first { lower.contains($0.0) }?.1 ?? 2
        return (version, size)
    }
}
