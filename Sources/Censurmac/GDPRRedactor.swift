import Foundation
import NaturalLanguage

// MARK: - Model

struct RedactionEntity: Identifiable, Hashable {
    let id = UUID()
    let originalText: String
    let replacement: String
    let type: EntityType

    enum EntityType: String, CaseIterable {
        case personName, organization, location, email, phone, cpr

        var label: String {
            switch self {
            case .personName:   return "Navn"
            case .organization: return "Organisation"
            case .location:     return "Sted"
            case .email:        return "Email"
            case .phone:        return "Telefon"
            case .cpr:          return "CPR-nummer"
            }
        }

        var icon: String {
            switch self {
            case .personName:   return "person.fill"
            case .organization: return "building.2.fill"
            case .location:     return "mappin.fill"
            case .email:        return "envelope.fill"
            case .phone:        return "phone.fill"
            case .cpr:          return "number.circle.fill"
            }
        }
    }

    static func == (lhs: RedactionEntity, rhs: RedactionEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Detector

class GDPRRedactor {
    private let personLabels = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P"]

    func findEntities(in text: String) -> [RedactionEntity] {
        var nameMap: [String: String] = [:]
        var nameCount = 0

        var all: [RedactionEntity] = []
        all += namedEntities(in: text, nameMap: &nameMap, nameCount: &nameCount)
        all += regexEntities(in: text)
        return deduplicated(all, in: text)
    }

    // MARK: Named entities via Apple NL framework

    private func namedEntities(in text: String, nameMap: inout [String: String], nameCount: inout Int) -> [RedactionEntity] {
        var result: [RedactionEntity] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }
            let raw = String(text[range])
            guard raw.count > 1 else { return true }

            switch tag {
            case .personalName:
                let label: String
                if let existing = nameMap[raw] {
                    label = existing
                } else {
                    label = "Person \(personLabels[nameCount % personLabels.count])"
                    nameMap[raw] = label
                    nameCount += 1
                }
                result.append(RedactionEntity(originalText: raw, replacement: label, type: .personName))

            case .organizationName:
                result.append(RedactionEntity(originalText: raw, replacement: "[Organisation]", type: .organization))

            case .placeName:
                result.append(RedactionEntity(originalText: raw, replacement: "[Sted]", type: .location))

            default: break
            }
            return true
        }
        return result
    }

    // MARK: Regex-based detection

    private func regexEntities(in text: String) -> [RedactionEntity] {
        var result: [RedactionEntity] = []

        // Email
        result += matches(
            in: text,
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            type: .email,
            replacement: "[email fjernet]"
        )

        // Danish phone: 8 digits optionally grouped, with optional +45 prefix
        result += matches(
            in: text,
            pattern: #"(?:(?:\+|00)45[\s\-]?)?(?:\d{2}[\s\-]?){3}\d{2}"#,
            type: .phone,
            replacement: "[tlf. fjernet]"
        )

        // International phone (+XX ...)
        result += matches(
            in: text,
            pattern: #"\+(?!45)\d{1,3}[\s\-]\d{4,14}"#,
            type: .phone,
            replacement: "[tlf. fjernet]"
        )

        // CPR: DDMMYY-XXXX or DDMMYYXXXX (Danish social security)
        result += matches(
            in: text,
            pattern: #"\b[0-3]\d[0-1]\d\d{2}[-–]?\d{4}\b"#,
            type: .cpr,
            replacement: "[CPR fjernet]"
        )

        return result
    }

    private func matches(in text: String, pattern: String, type: RedactionEntity.EntityType, replacement: String) -> [RedactionEntity] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return RedactionEntity(originalText: String(text[range]), replacement: replacement, type: type)
        }
    }

    // MARK: Deduplication (remove overlapping / identical entities)

    private func deduplicated(_ entities: [RedactionEntity], in text: String) -> [RedactionEntity] {
        // Group by originalText first to avoid processing same string multiple times
        var seen = Set<String>()
        var unique: [RedactionEntity] = []
        for e in entities {
            if seen.insert(e.originalText.lowercased()).inserted {
                unique.append(e)
            }
        }
        return unique
    }
}
