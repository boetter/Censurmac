import Foundation
import NaturalLanguage

// MARK: - Models

struct Substitution {
    let range: Range<String.Index>
    let original: String
    let replacement: String
}

struct EntityGroup: Identifiable, Hashable {
    let id = UUID()
    let originalText: String
    let replacement: String
    let type: EntityType
    let count: Int

    enum EntityType: String {
        case personName, organization, location, email, phone, cpr, address

        var label: String {
            switch self {
            case .personName:   return "Navn"
            case .organization: return "Organisation"
            case .location:     return "Sted"
            case .email:        return "Email"
            case .phone:        return "Telefon"
            case .cpr:          return "CPR-nummer"
            case .address:      return "Adresse"
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
            case .address:      return "house.fill"
            }
        }
    }

    static func == (lhs: EntityGroup, rhs: EntityGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Redactor

class GDPRRedactor {
    private let personLabels = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P"]

    // MARK: - Offentlig API

    /// Async: forsøger Ollama (lokal LLM) til semantiske entiteter.
    /// Regex bruges altid til email, telefon og CPR — de har klare mønstre.
    func findSubstitutions(in text: String) async -> [Substitution] {
        var nameMap: [String: String] = [:]
        var nameCount = 0
        var result: [Substitution] = []

        // -- Semantiske entiteter (navne, org, adresser) --
        let ollama = OllamaExtractor.shared
        if await ollama.isAvailable {
            if let entities = try? await ollama.extract(from: text) {
                result += substitutionsFromLLM(entities, in: text, nameMap: &nameMap, nameCount: &nameCount)
            }
        } else {
            // Fallback: Apple NaturalLanguage (fungerer dårligt for dansk, men er bedre end intet)
            result += nlpFallback(in: text, nameMap: &nameMap, nameCount: &nameCount)
        }

        // -- Regex (høj præcision, kræver ingen LLM) --
        result += regexMatches(in: text, type: .email,
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            replacement: "[email fjernet]")

        result += regexMatches(in: text, type: .phone,
            pattern: #"\b(?:(?:\+|00)45[\s\-]?)?(?:\d{2}[\s\-]?){3}\d{2}\b"#,
            replacement: "[tlf. fjernet]")

        result += regexMatches(in: text, type: .phone,
            pattern: #"\+(?!45)\d{1,3}[\s\-]\d{4,14}"#,
            replacement: "[tlf. fjernet]")

        result += regexMatches(in: text, type: .cpr,
            pattern: #"\b[0-3]\d[0-1]\d\d{2}[-–]?\d{4}\b"#,
            replacement: "[CPR fjernet]")

        return removeOverlaps(result)
    }

    func groupEntities(from substitutions: [Substitution]) -> [EntityGroup] {
        var groups: [String: (replacement: String, type: EntityGroup.EntityType, count: Int)] = [:]
        for sub in substitutions {
            if var g = groups[sub.original] {
                g.count += 1
                groups[sub.original] = g
            } else {
                let type = entityType(for: sub)
                groups[sub.original] = (sub.replacement, type, 1)
            }
        }
        return groups.map { original, info in
            EntityGroup(originalText: original, replacement: info.replacement, type: info.type, count: info.count)
        }.sorted { $0.type.rawValue < $1.type.rawValue }
    }

    func apply(_ substitutions: [Substitution], selectedOriginals: Set<String>, to text: String) -> String {
        let toApply = substitutions
            .filter { selectedOriginals.contains($0.original) }
            .sorted { $0.range.lowerBound > $1.range.lowerBound }

        var result = text
        for sub in toApply {
            result.replaceSubrange(sub.range, with: sub.replacement)
        }
        return result
    }

    // MARK: - LLM-resultater → Substitutions

    private func substitutionsFromLLM(_ entities: LLMEntities, in text: String,
                                       nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        var result: [Substitution] = []

        for name in entities.names where !name.isEmpty {
            let label = resolvePersonLabel(name, nameMap: &nameMap, nameCount: &nameCount)
            result += allOccurrences(of: name, in: text, replacement: label)
        }
        for org in entities.organizations where !org.isEmpty {
            result += allOccurrences(of: org, in: text, replacement: "[Organisation]")
        }
        for addr in entities.addresses where !addr.isEmpty {
            result += allOccurrences(of: addr, in: text, replacement: "[adresse fjernet]")
        }

        return result
    }

    /// Finder alle forekomster af en literal streng i teksten.
    private func allOccurrences(of substring: String, in text: String, replacement: String) -> [Substitution] {
        var result: [Substitution] = []
        var searchStart = text.startIndex
        while let range = text.range(of: substring, options: .literal, range: searchStart..<text.endIndex) {
            result.append(Substitution(range: range, original: substring, replacement: replacement))
            searchStart = range.upperBound
        }
        return result
    }

    // MARK: - NLP fallback (Apple NaturalLanguage)

    private func nlpFallback(in text: String, nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        var result: [Substitution] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.danish, range: text.startIndex..<text.endIndex)

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }
            let raw = String(text[range])
            guard raw.count > 1 else { return true }

            switch tag {
            case .personalName:
                let label = resolvePersonLabel(raw, nameMap: &nameMap, nameCount: &nameCount)
                result.append(Substitution(range: range, original: raw, replacement: label))
            case .organizationName:
                result.append(Substitution(range: range, original: raw, replacement: "[Organisation]"))
            case .placeName:
                result.append(Substitution(range: range, original: raw, replacement: "[Sted]"))
            default: break
            }
            return true
        }
        return result
    }

    // MARK: - Regex hjælper

    private func regexMatches(in text: String, type: EntityGroup.EntityType, pattern: String, replacement: String) -> [Substitution] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Substitution(range: range, original: String(text[range]), replacement: replacement)
        }
    }

    // MARK: - Overlap-fjernelse

    private func removeOverlaps(_ substitutions: [Substitution]) -> [Substitution] {
        let sorted = substitutions.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result: [Substitution] = []
        var lastEnd: String.Index? = nil
        for sub in sorted {
            if let end = lastEnd, sub.range.lowerBound < end { continue }
            result.append(sub)
            lastEnd = sub.range.upperBound
        }
        return result
    }

    // MARK: - Hjælpere

    private func resolvePersonLabel(_ raw: String, nameMap: inout [String: String], nameCount: inout Int) -> String {
        if let existing = nameMap[raw] { return existing }
        let label = "Person \(personLabels[nameCount % personLabels.count])"
        nameMap[raw] = label
        nameCount += 1
        return label
    }

    private func entityType(for sub: Substitution) -> EntityGroup.EntityType {
        if sub.replacement.hasPrefix("Person ")     { return .personName }
        if sub.replacement == "[Organisation]"      { return .organization }
        if sub.replacement == "[Sted]"              { return .location }
        if sub.replacement.contains("email")        { return .email }
        if sub.replacement.contains("tlf")          { return .phone }
        if sub.replacement.contains("CPR")          { return .cpr }
        if sub.replacement.contains("adresse")      { return .address }
        return .personName
    }
}
