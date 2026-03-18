import Foundation

// MARK: - LLM output model

struct LLMEntities: Codable {
    var names: [String]
    var organizations: [String]
    var addresses: [String]

    static let empty = LLMEntities(names: [], organizations: [], addresses: [])
}

// MARK: - Extractor

/// Kalder en lokal Ollama-instans (http://localhost:11434) og beder den
/// identificere personhenførbare oplysninger i dansk tekst.
/// Al inferens sker lokalt — ingen data sendes til internettet.
actor OllamaExtractor {

    static let shared = OllamaExtractor()

    private let baseURL = URL(string: "http://localhost:11434")!

    /// Modeller sorteret efter hvad der virker bedst til opgaven (lille → stor)
    private let preferredModels = [
        "llama3.2:3b", "llama3.2", "llama3.1:8b", "llama3.1",
        "phi3:mini", "phi3", "phi4:mini", "phi4",
        "mistral", "qwen2.5:3b", "qwen2.5", "gemma3:4b", "gemma3",
    ]

    private(set) var isAvailable = false
    private(set) var modelName: String?

    // MARK: - Tilgængelighed

    func checkAvailability() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3

        guard let (data, _) = try? await URLSession.shared.data(for: req) else {
            isAvailable = false
            return
        }

        struct Tags: Codable {
            struct Model: Codable { let name: String }
            let models: [Model]
        }

        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            isAvailable = false
            return
        }

        let installed = tags.models.map(\.name)

        // Forsøg foretrukne modeller i rækkefølge
        for pref in preferredModels {
            let baseName = String(pref.split(separator: ":").first ?? Substring(pref))
            if let found = installed.first(where: { $0.hasPrefix(baseName) }) {
                modelName = found
                isAvailable = true
                return
            }
        }

        // Brug første tilgængelige model hvis ingen foretrukne er installeret
        modelName = installed.first
        isAvailable = modelName != nil
    }

    // MARK: - Ekstraktion

    func extract(from text: String) async throws -> LLMEntities {
        guard let model = modelName else { throw OllamaError.noModel }

        // Kortere tekster er hurtigere og undgår context overflow
        let maxChars = 4000
        let input = text.count > maxChars ? String(text.prefix(maxChars)) : text

        let systemPrompt = """
        Du er en præcis GDPR-detektor specialiseret i dansk tekst.
        Din opgave: find alle personhenførbare oplysninger og returner dem som JSON.

        OUTPUT FORMAT — returner KUN dette JSON, ingen anden tekst:
        {"names":[],"organizations":[],"addresses":[]}

        REGLER:
        - names: fulde personnavne (fornavn + efternavn). Ikke titler alene. Kun faktiske navne.
        - organizations: virksomheder, myndigheder, foreninger med specifikt navn
        - addresses: vejadresser med husnummer (fx "Rosenvej 12") og/eller postnummer+by (fx "2100 København")
        - Alle værdier skal være PRÆCISE kopier af tekststykker fra inputteksten
        - Årstal ("2023", "1999") er ALDRIG adresser
        - Enkeltord der ikke er navne (fx "trænet", "Danmark" uden kontekst) medtages ikke
        - Svar KUN med JSON. Ingen forklaringer, ingen markdown, ingen ` ``` `.
        """

        let userContent = "Find personhenførbare oplysninger i denne tekst:\n\n\(input)"

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.0],  // Deterministisk output
        ]

        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: req)

        struct ChatResponse: Codable {
            struct Message: Codable { let content: String }
            let message: Message?
        }

        guard
            let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = resp.message?.content,
            let jsonData = content.data(using: .utf8),
            let entities = try? JSONDecoder().decode(LLMEntities.self, from: jsonData)
        else {
            return .empty
        }

        return entities
    }
}

// MARK: - Fejltyper

enum OllamaError: LocalizedError {
    case noModel

    var errorDescription: String? {
        "Ingen Ollama-model fundet. Installér Ollama (ollama.com) og kør fx: ollama pull llama3.2:3b"
    }
}
