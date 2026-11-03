import Foundation
import NaturalLanguage
import WhisperKit

struct LocalWhisperTokenizer: WhisperTokenizer {
    let underlying: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ underlying: TokenizerWrapper) throws {
        self.underlying = underlying
        specialTokens = try Self.makeSpecialTokens(lookup: underlying.convertTokenToId)
        allLanguageTokens = Set(Constants.languages.values.compactMap {
            underlying.convertTokenToId("<|\($0)|>")
        })
    }

    static func makeSpecialTokens(lookup: (String) -> Int?) throws -> SpecialTokens {
        func id(_ token: String) throws -> Int {
            guard let value = lookup(token) else {
                throw LocalModelError.invalidTokenizer(token)
            }
            return value
        }
        // Pre-v3 OpenAI tokenizers call this token nocaptions. Its numeric ID
        // also differs for English-only vocabularies; do not use a base-model
        // fallback ID for a missing spelling.
        let noSpeech = try lookup("<|nospeech|>") ?? id("<|nocaptions|>")
        return try SpecialTokens(
            endToken: id("<|endoftext|>"),
            englishToken: id("<|en|>"),
            noSpeechToken: noSpeech,
            noTimestampsToken: id("<|notimestamps|>"),
            specialTokenBegin: id("<|endoftext|>"),
            startOfPreviousToken: id("<|startofprev|>"),
            startOfTranscriptToken: id("<|startoftranscript|>"),
            timeTokenBegin: id("<|0.00|>"),
            transcribeToken: id("<|transcribe|>"),
            translateToken: id("<|translate|>"),
            whitespaceToken: id("Ġ")
        )
    }

    func encode(text: String) -> [Int] { underlying.encode(text: text) }
    func decode(tokens: [Int]) -> String { underlying.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { underlying.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { underlying.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let usesSpaces = !["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        var words: [String] = []
        var groups: [[Int]] = []
        var pending: [Int] = []
        func append(_ text: String, tokens: [Int]) {
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if !usesSpaces || words.isEmpty || text.hasPrefix(" ") || punctuation || tokens.contains(where: { $0 >= specialTokens.specialTokenBegin }) {
                words.append(text)
                groups.append(tokens)
            } else {
                words[words.count - 1] += text
                groups[groups.count - 1] += tokens
            }
        }
        for token in tokenIds {
            pending.append(token)
            let text = decode(tokens: pending)
            // A Unicode scalar may span multiple BPE tokens. Delay incomplete
            // byte sequences; retain any literal replacement character at EOF.
            if !text.contains("\u{fffd}") {
                append(text, tokens: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty { append(decode(tokens: pending), tokens: pending) }
        return (words, groups)
    }
}
