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

    // Danske ord med stort begyndelsesbogstav som IKKE er navne
    private let nonNameWords: Set<String> = [
        // Ugedage
        "Mandag","Tirsdag","Onsdag","Torsdag","Fredag","Lørdag","Søndag",
        // Måneder
        "Januar","Februar","Marts","April","Maj","Juni",
        "Juli","August","September","Oktober","November","December",
        // Høflighedsfraser og hilsener
        "Kære","Hej","Til","Fra","Emne","Vedr","Vedrørende","Mvh","Hilsen",
        "Med","Venlig","Vh","Re","Fw","Fwd","Ang","Angående",
        // Steder og lande
        "Danmark","Sverige","Norge","Finland","Island","Tyskland","Europa",
        "Grønland","Færøerne","København","Aarhus","Odense","Aalborg",
        // Pronomiener og ord der kan stå med stort
        "De","Dem","Deres","Han","Hun","Vi","Jeg",
        // Dokumenttermer
        "Bilag","Sagsnr","Journalnr","Dato","Side","Note","Notat",
        "Aftale","Kontrakt","Brev","Rapport","Ansøgning","Klage",
        // Titler der IKKE er navne
        "Hr","Hr.","Fru","Fru.","Dr","Dr.","Prof","Prof.",
        // Institutioner (generiske)
        "Kommune","Region","Ministeriet","Styrelsen","Rådet","Nævnet",
        "Kontoret","Afdelingen","Enheden","Centret","Instituttet",
    ]

    // MARK: - Offentlig API

    func findSubstitutions(in text: String) -> [Substitution] {
        var nameMap: [String: String] = [:]
        var nameCount = 0
        var result: [Substitution] = []

        // 1. NLP-baseret (Apple NaturalLanguage — begrænset for dansk men giver et første lag)
        result += nlSubstitutions(in: text, nameMap: &nameMap, nameCount: &nameCount)

        // 2. Label-mønstre: "Navn: Peter Hansen", "Afsender: ..." osv.
        result += labeledFieldSubstitutions(in: text, nameMap: &nameMap, nameCount: &nameCount)

        // 3. Heuristik: kapitaliserede ordsekvenser EFTER et lille bogstav (midtsætning)
        //    Dansk kapitaliserer ikke substantiver, så det er næsten altid et egennavn.
        result += capitalizedMidSentenceSubstitutions(in: text, nameMap: &nameMap, nameCount: &nameCount)

        // 4. Regex: email
        result += regexSubstitutions(in: text, type: .email,
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            replacement: "[email fjernet]")

        // 5. Regex: danske telefonnumre (8 cifre, evt. med +45 foran)
        result += regexSubstitutions(in: text, type: .phone,
            pattern: #"\b(?:(?:\+|00)45[\s\-]?)?(?:\d{2}[\s\-]?){3}\d{2}\b"#,
            replacement: "[tlf. fjernet]")
        // Internationale numre
        result += regexSubstitutions(in: text, type: .phone,
            pattern: #"\+(?!45)\d{1,3}[\s\-]\d{4,14}"#,
            replacement: "[tlf. fjernet]")

        // 6. Regex: CPR-nummer
        result += regexSubstitutions(in: text, type: .cpr,
            pattern: #"\b[0-3]\d[0-1]\d\d{2}[-–]?\d{4}\b"#,
            replacement: "[CPR fjernet]")

        // 7. Danske adresser: "Rosenvej 12, 2100 København"
        result += addressSubstitutions(in: text)

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

    // MARK: - NLP (Apple NaturalLanguage)

    private func nlSubstitutions(in text: String, nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        var result: [Substitution] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        // Giv dansk sproghint så taggeren ikke gætter engelsk
        tagger.setLanguage(.danish, range: text.startIndex..<text.endIndex)

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let tag else { return true }
            let raw = String(text[range])
            guard raw.count > 1, !nonNameWords.contains(raw) else { return true }

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

    // MARK: - Heuristik 1: Label-felter

    /// Finder mønstre som "Navn: Peter Hansen", "Patient: ...", "Afsender: ..."
    private func labeledFieldSubstitutions(in text: String, nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        let labels = [
            "navn","patient","borger","klient","ansøger","afsender",
            "modtager","fra","til","kontakt","person","medarbejder",
            "sagspart","part","påklager","indklaget","rekvirent",
        ]
        let labelPattern = "(?i)(?:" + labels.joined(separator: "|") + #"):\s*([A-ZÆØÅ][a-zæøå]+(?:\s[A-ZÆØÅ][a-zæøå]+){1,3})"#
        return namedGroupMatches(pattern: labelPattern, group: 1, in: text, nameMap: &nameMap, nameCount: &nameCount)
    }

    // MARK: - Heuristik 2: Kapitaliserede ord midtsætning

    /// I dansk kapitaliseres substantiver IKKE. Derfor er et kapitaliseret ord midt i en
    /// sætning (efter lille bogstav + mellemrum) næsten altid et egennavn.
    /// Vi finder sekvenser på 1-3 sådanne ord, men kræver mindst 2 ord for entydig match
    /// (for at undgå falske positiver på enkeltord som "Staten", "Ministeriet" osv.)
    private func capitalizedMidSentenceSubstitutions(in text: String, nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        // Mønster: lille bogstav/komma/semikolon + ét mellemrum + 2-3 store ord
        // Capture group 1 = selve navnesekvensen
        let pattern = #"[a-zæøå,;:]\s([A-ZÆØÅ][a-zæøå]{1,}(?:\s[A-ZÆØÅ][a-zæøå]{1,}){1,2})(?=[\s.,;:!?\n]|$)"#
        return namedGroupMatches(pattern: pattern, group: 1, in: text, nameMap: &nameMap, nameCount: &nameCount)
    }

    // MARK: - Hjælper til capture-group matches

    private func namedGroupMatches(pattern: String, group: Int, in text: String,
                                    nameMap: inout [String: String], nameCount: inout Int) -> [Substitution] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        var result: [Substitution] = []

        for match in regex.matches(in: text, range: nsRange) {
            let groupRange = match.range(at: group)
            guard groupRange.location != NSNotFound,
                  let range = Range(groupRange, in: text) else { continue }
            let raw = String(text[range])
            // Spring over hvis alle ord er i listen over ikke-navne
            let words = raw.components(separatedBy: " ")
            if words.allSatisfy({ nonNameWords.contains($0) }) { continue }

            let label = resolvePersonLabel(raw, nameMap: &nameMap, nameCount: &nameCount)
            result.append(Substitution(range: range, original: raw, replacement: label))
        }
        return result
    }

    // MARK: - Adressegenkendelse

    private func addressSubstitutions(in text: String) -> [Substitution] {
        // Vejnavn der ender på et dansk suffiks + husnummer: "Rosenvej 12", "Nørregade 5A"
        let streetPattern = #"\b[A-ZÆØÅ][a-zæøå]+(?:vej|gade|alle|allé|stræde|plads|torv|boulevard|have|sti|vænge|park|bro|strand|bakke|ring)\s+\d+[A-Za-z]?\b"#
        // Postnummer + by alene: "2100 København", "8000 Aarhus C"
        let postalPattern = #"\b\d{4}\s+[A-ZÆØÅ][a-zæøå]+(?:\s[A-ZÆØÅ])?\b"#

        var result: [Substitution] = []
        result += regexSubstitutions(in: text, type: .address, pattern: streetPattern, replacement: "[adresse fjernet]")
        result += regexSubstitutions(in: text, type: .address, pattern: postalPattern, replacement: "[adresse fjernet]")
        return result
    }

    // MARK: - Regex hjælper

    private func regexSubstitutions(in text: String, type: EntityGroup.EntityType, pattern: String, replacement: String) -> [Substitution] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
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
