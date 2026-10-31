import Foundation

public enum TemplateError: Error, Equatable {
    case unresolvedPlaceholder(String)
}

public enum TemplateEngine {
    /// `transform` is applied to each substituted *value* only — never to the literal
    /// text around it, so a file format's separators stay separators (see `pgpass`).
    public static func render(_ template: String, variables: [String: String],
                              transform: ((String) -> String)? = nil) throws -> String {
        var result = ""
        var i = template.startIndex

        while i < template.endIndex {
            // Look for "{{"
            if template[i] == "{",
               template.index(after: i) < template.endIndex,
               template[template.index(after: i)] == "{" {

                // Find closing "}}"
                let nameStart = template.index(i, offsetBy: 2)
                guard let closeRange = template.range(of: "}}", range: nameStart..<template.endIndex) else {
                    // No closing braces — emit literally
                    result.append(template[i])
                    i = template.index(after: i)
                    continue
                }

                let name = String(template[nameStart..<closeRange.lowerBound])
                guard let value = variables[name] else {
                    throw TemplateError.unresolvedPlaceholder(name)
                }
                result.append(transform?(value) ?? value)
                i = closeRange.upperBound
            } else {
                result.append(template[i])
                i = template.index(after: i)
            }
        }

        return result
    }
}
