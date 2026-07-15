import Foundation

/// Icelandic word class (part-of-speech) tags, as used by BÍN / lemma-is.
public enum WordClass: String, Sendable, CaseIterable {
    case noun = "no"
    case verb = "so"
    case adjective = "lo"
    case adverb = "ao"
    case preposition = "fs"
    case pronoun = "fn"
    case conjunction = "st"
    case numeral = "to"
    case article = "gr"
    case interjection = "uh"
}

/// A lemma together with its word class.
public struct LemmaWithPOS: Equatable, Sendable {
    public let lemma: String
    /// Raw POS code string ("no", "so", ...). Empty string when the code is
    /// outside the known table (mirrors the TS `?? ""` fallback).
    public let pos: String
}

/// Grammatical morph features (only populated by version 2 binaries).
public struct MorphFeatures: Equatable, Sendable {
    public let grammaticalCase: String?  // "nf" | "þf" | "þgf" | "ef"
    public let gender: String?           // "kk" | "kvk" | "hk"
    public let number: String?           // "et" | "ft"

    public var isEmpty: Bool {
        grammaticalCase == nil && gender == nil && number == nil
    }
}

/// A lemma with word class and optional morph features.
public struct LemmaWithMorph: Equatable, Sendable {
    public let lemma: String
    public let pos: String
    public let morph: MorphFeatures?
}

public enum BinaryLemmatizerError: Error, CustomStringConvertible {
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidMagic(let m):
            return "Invalid binary format: expected magic 0x4c454d41, got 0x\(String(m, radix: 16))"
        case .unsupportedVersion(let v):
            return "Unsupported version: \(v)"
        case .truncated(let expected, let actual):
            return "Truncated binary: need \(expected) bytes, file has \(actual)"
        }
    }
}

/// Binary-format Icelandic lemmatizer.
///
/// Swift port of lemma-is `src/binary-lemmatizer.ts`, reading the `.bin`
/// artifact produced by `scripts/build-binary.py` (format versions 1 and 2).
///
/// Memory strategy: the file is memory-mapped (`Data(contentsOf:options:.alwaysMapped)`)
/// and *never* parsed into Swift collections. The initializer only reads the
/// 32-byte header and computes section offsets; every lookup does lazy,
/// offset-based reads straight out of the mapped buffer via binary search.
/// File-backed clean pages don't count against the iOS keyboard-extension
/// jetsam limit, so resident cost is only the pages actually touched.
///
/// Known divergences from the TypeScript reader (documented, not observable
/// for the shipped Icelandic data):
///  - String ordering in the binary search compares raw UTF-8 bytes, which is
///    Unicode code-point order — identical to the Python writer's `sorted()`.
///    JS `<` compares UTF-16 code units, which differs from code-point order
///    only for astral (non-BMP) characters; all BÍN data is BMP.
///  - Word equality is exact byte equality, matching JS `===` (code-unit
///    equality). We deliberately avoid Swift `String ==`, which would apply
///    Unicode canonical equivalence (NFC == NFD) that JS does not.
///  - Lowercasing uses Swift `lowercased()` (Unicode full case mapping,
///    locale-independent), the same algorithm as JS `toLowerCase()`.
public final class BinaryLemmatizer {

    private static let magic: UInt32 = 0x4C45_4D41  // "LEMA" little-endian

    // POS code table — must match build-binary.py POS_TO_CODE.
    private static let codeToPOS: [String] = [
        "no", "so", "lo", "ao", "fs", "fn", "st", "to", "gr", "uh",
    ]
    // 0=none, 1=nf, 2=þf, 3=þgf, 4=ef
    private static let codeToCase: [String?] = [nil, "nf", "þf", "þgf", "ef", nil, nil, nil]
    // 0=none, 1=kk, 2=kvk, 3=hk
    private static let codeToGender: [String?] = [nil, "kk", "kvk", "hk"]
    // 0=et/none, 1=ft
    private static let codeToNumber: [String?] = ["et", "ft"]

    /// The memory-mapped file. Kept alive for the lifetime of the lemmatizer;
    /// all reads go through `withUnsafeBytes` against this single buffer.
    private let data: Data

    public let version: Int
    public let lemmaCount: Int
    public let wordFormCount: Int
    public let entryCount: Int
    public let bigramCount: Int

    // Byte offsets of each section from the start of the file.
    private let stringPoolOffset: Int
    private let stringPoolSize: Int
    private let lemmaOffsetsOffset: Int
    private let lemmaLengthsOffset: Int
    private let wordOffsetsOffset: Int
    private let wordLengthsOffset: Int
    private let entryOffsetsOffset: Int
    private let entriesOffset: Int
    private let bigramW1OffsetsOffset: Int
    private let bigramW1LengthsOffset: Int
    private let bigramW2OffsetsOffset: Int
    private let bigramW2LengthsOffset: Int
    private let bigramFreqsOffset: Int

    /// Memory-map a `.bin` file. Preferred entry point on iOS/macOS.
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    /// Wrap an already-loaded buffer (mirrors TS `loadFromBuffer`).
    public init(data: Data) throws {
        self.data = data

        guard data.count >= 32 else {
            throw BinaryLemmatizerError.truncated(expected: 32, actual: data.count)
        }

        func u32(_ byteOffset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
            }
        }

        let magic = u32(0)
        guard magic == Self.magic else {
            throw BinaryLemmatizerError.invalidMagic(magic)
        }

        let versionRaw = u32(4)
        guard versionRaw == 1 || versionRaw == 2 else {
            throw BinaryLemmatizerError.unsupportedVersion(versionRaw)
        }
        self.version = Int(versionRaw)

        self.stringPoolSize = Int(u32(8))
        self.lemmaCount = Int(u32(12))
        self.wordFormCount = Int(u32(16))
        self.entryCount = Int(u32(20))
        self.bigramCount = Int(u32(24))
        // u32 at 28 is reserved

        // Section layout — must match build-binary.py / binary-lemmatizer.ts.
        var offset = 32

        stringPoolOffset = offset
        offset += stringPoolSize  // writer pads the pool itself to 4 bytes

        lemmaOffsetsOffset = offset
        offset += lemmaCount * 4

        lemmaLengthsOffset = offset
        offset += lemmaCount
        offset = (offset + 3) & ~3

        wordOffsetsOffset = offset
        offset += wordFormCount * 4

        wordLengthsOffset = offset
        offset += wordFormCount
        offset = (offset + 3) & ~3

        entryOffsetsOffset = offset
        offset += (wordFormCount + 1) * 4

        entriesOffset = offset
        offset += entryCount * 4

        bigramW1OffsetsOffset = offset
        offset += bigramCount * 4

        bigramW1LengthsOffset = offset
        offset += bigramCount
        offset = (offset + 3) & ~3

        bigramW2OffsetsOffset = offset
        offset += bigramCount * 4

        bigramW2LengthsOffset = offset
        offset += bigramCount
        offset = (offset + 3) & ~3

        bigramFreqsOffset = offset
        offset += bigramCount * 4

        guard data.count >= offset else {
            throw BinaryLemmatizerError.truncated(expected: offset, actual: data.count)
        }
    }

    // MARK: - Public API

    /// Look up possible lemmas for a word form.
    ///
    /// Results are in stored order (the writer sorts by corpus frequency,
    /// most common first) with duplicate lemmas removed. Unknown words return
    /// `[normalizedWord]`, matching the TypeScript behavior.
    public func lemmatize(_ word: String, wordClass: WordClass? = nil) -> [String] {
        let normalized = word.lowercased()
        let key = Array(normalized.utf8)

        return withBuffer { buf in
            guard let idx = findWord(key, in: buf) else { return [normalized] }

            let start = Int(readU32(buf, at: entryOffsetsOffset + idx * 4))
            let end = Int(readU32(buf, at: entryOffsetsOffset + (idx + 1) * 4))

            var seen = Set<String>()
            var result: [String] = []
            result.reserveCapacity(min(end - start, 4))

            for i in start..<end {
                let entry = readU32(buf, at: entriesOffset + i * 4)
                let (lemmaIdx, posCode, _, _, _) = unpackEntry(entry)

                if let wanted = wordClass {
                    let pos = posCode < Self.codeToPOS.count ? Self.codeToPOS[Int(posCode)] : ""
                    if pos != wanted.rawValue { continue }
                }

                let lemma = lemmaString(at: Int(lemmaIdx), in: buf)
                if seen.insert(lemma).inserted {
                    result.append(lemma)
                }
            }

            return result.isEmpty ? [normalized] : result
        }
    }

    /// Look up lemmas with their word class (POS) tags.
    /// Unknown words return `[]`, matching the TypeScript behavior.
    public func lemmatizeWithPOS(_ word: String) -> [LemmaWithPOS] {
        let normalized = word.lowercased()
        let key = Array(normalized.utf8)

        return withBuffer { buf in
            guard let idx = findWord(key, in: buf) else { return [] }

            let start = Int(readU32(buf, at: entryOffsetsOffset + idx * 4))
            let end = Int(readU32(buf, at: entryOffsetsOffset + (idx + 1) * 4))

            var seen = Set<String>()
            var result: [LemmaWithPOS] = []

            for i in start..<end {
                let entry = readU32(buf, at: entriesOffset + i * 4)
                let (lemmaIdx, posCode, _, _, _) = unpackEntry(entry)
                let lemma = lemmaString(at: Int(lemmaIdx), in: buf)
                let pos = posCode < Self.codeToPOS.count ? Self.codeToPOS[Int(posCode)] : ""
                if seen.insert("\(lemma):\(pos)").inserted {
                    result.append(LemmaWithPOS(lemma: lemma, pos: pos))
                }
            }

            return result
        }
    }

    /// Look up lemmas with word class and morphological features.
    /// Morph data is only meaningful with version 2 binaries; version 1
    /// entries always yield `morph == nil`. No deduplication (matches TS).
    public func lemmatizeWithMorph(_ word: String) -> [LemmaWithMorph] {
        let normalized = word.lowercased()
        let key = Array(normalized.utf8)

        return withBuffer { buf in
            guard let idx = findWord(key, in: buf) else { return [] }

            let start = Int(readU32(buf, at: entryOffsetsOffset + idx * 4))
            let end = Int(readU32(buf, at: entryOffsetsOffset + (idx + 1) * 4))

            var result: [LemmaWithMorph] = []
            for i in start..<end {
                let entry = readU32(buf, at: entriesOffset + i * 4)
                let (lemmaIdx, posCode, caseCode, genderCode, numberCode) = unpackEntry(entry)

                let caseVal = Int(caseCode) < Self.codeToCase.count ? Self.codeToCase[Int(caseCode)] : nil
                let genderVal = Int(genderCode) < Self.codeToGender.count ? Self.codeToGender[Int(genderCode)] : nil
                let numberVal = Int(numberCode) < Self.codeToNumber.count ? Self.codeToNumber[Int(numberCode)] : nil
                // TS builds `morph` from truthy values only; "et" (code 0) is
                // truthy in TS, so it is kept — mirror that exactly.
                let morph = MorphFeatures(
                    grammaticalCase: caseVal,
                    gender: genderVal,
                    number: numberVal
                )

                result.append(
                    LemmaWithMorph(
                        lemma: lemmaString(at: Int(lemmaIdx), in: buf),
                        pos: posCode < Self.codeToPOS.count ? Self.codeToPOS[Int(posCode)] : "",
                        morph: morph.isEmpty ? nil : morph
                    ))
            }
            return result
        }
    }

    /// Whether a word form exists in the database.
    public func isKnown(_ word: String) -> Bool {
        let key = Array(word.lowercased().utf8)
        return withBuffer { buf in findWord(key, in: buf) != nil }
    }

    /// Bigram frequency, or 0 if not found (or the binary has no bigrams).
    public func bigramFreq(_ word1: String, _ word2: String) -> UInt32 {
        let k1 = Array(word1.lowercased().utf8)
        let k2 = Array(word2.lowercased().utf8)
        return withBuffer { buf in
            guard let idx = findBigram(k1, k2, in: buf) else { return 0 }
            return readU32(buf, at: bigramFreqsOffset + idx * 4)
        }
    }

    /// Whether morphological features are available (version 2+).
    public var hasMorphFeatures: Bool { version >= 2 }

    /// Raw buffer size in bytes (approximate *virtual* footprint; resident
    /// dirty memory stays near zero because the buffer is file-backed).
    public var bufferSize: Int { data.count }

    /// All unique lemmas. NOTE: materializes every lemma string — do not call
    /// from the keyboard extension hot path.
    public func allLemmas() -> [String] {
        withBuffer { buf in
            (0..<lemmaCount).map { lemmaString(at: $0, in: buf) }
        }
    }

    // MARK: - Internals (all operate on the mapped raw buffer)

    @inline(__always)
    private func withBuffer<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        data.withUnsafeBytes(body)
    }

    @inline(__always)
    private func readU32(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt32 {
        buf.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
    }

    @inline(__always)
    private func readU8(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt8 {
        buf[byteOffset]
    }

    /// Decode a string from the pool.
    @inline(__always)
    private func poolString(_ buf: UnsafeRawBufferPointer, offset: Int, length: Int) -> String {
        let start = stringPoolOffset + offset
        let bytes = UnsafeRawBufferPointer(rebasing: buf[start..<start + length])
        // Matches TextDecoder("utf-8") default: invalid sequences → U+FFFD.
        return String(decoding: bytes, as: UTF8.self)
    }

    @inline(__always)
    private func lemmaString(at index: Int, in buf: UnsafeRawBufferPointer) -> String {
        let offset = Int(readU32(buf, at: lemmaOffsetsOffset + index * 4))
        let length = Int(readU8(buf, at: lemmaLengthsOffset + index))
        return poolString(buf, offset: offset, length: length)
    }

    /// Lexicographic comparison of `key` against a pool string, by raw UTF-8
    /// bytes (== Unicode code-point order == the Python writer's sort order).
    @inline(__always)
    private func compareKey(
        _ key: [UInt8], poolOffset: Int, poolLength: Int, in buf: UnsafeRawBufferPointer
    ) -> Int {
        let base = stringPoolOffset + poolOffset
        let n = min(key.count, poolLength)
        var i = 0
        while i < n {
            let a = key[i]
            let b = buf[base + i]
            if a != b { return a < b ? -1 : 1 }
            i += 1
        }
        if key.count == poolLength { return 0 }
        return key.count < poolLength ? -1 : 1
    }

    /// Binary search over the alphabetically sorted word index.
    private func findWord(_ key: [UInt8], in buf: UnsafeRawBufferPointer) -> Int? {
        var left = 0
        var right = wordFormCount - 1
        while left <= right {
            let mid = (left + right) >> 1
            let offset = Int(readU32(buf, at: wordOffsetsOffset + mid * 4))
            let length = Int(readU8(buf, at: wordLengthsOffset + mid))
            switch compareKey(key, poolOffset: offset, poolLength: length, in: buf) {
            case 0: return mid
            case let c where c > 0: left = mid + 1
            default: right = mid - 1
            }
        }
        return nil
    }

    /// Binary search over the (word1, word2)-sorted bigram index.
    private func findBigram(_ k1: [UInt8], _ k2: [UInt8], in buf: UnsafeRawBufferPointer) -> Int? {
        var left = 0
        var right = bigramCount - 1
        while left <= right {
            let mid = (left + right) >> 1
            let o1 = Int(readU32(buf, at: bigramW1OffsetsOffset + mid * 4))
            let l1 = Int(readU8(buf, at: bigramW1LengthsOffset + mid))
            var c = compareKey(k1, poolOffset: o1, poolLength: l1, in: buf)
            if c == 0 {
                let o2 = Int(readU32(buf, at: bigramW2OffsetsOffset + mid * 4))
                let l2 = Int(readU8(buf, at: bigramW2LengthsOffset + mid))
                c = compareKey(k2, poolOffset: o2, poolLength: l2, in: buf)
                if c == 0 { return mid }
            }
            if c > 0 { left = mid + 1 } else { right = mid - 1 }
        }
        return nil
    }

    /// Unpack a packed entry.
    /// Version 1: bits 0-3 = pos, bits 4-23 = lemmaIdx.
    /// Version 2: bits 0-3 = pos, 4-6 = case, 7-8 = gender, 9 = number, 10-29 = lemmaIdx.
    @inline(__always)
    private func unpackEntry(_ entry: UInt32) -> (
        lemmaIdx: UInt32, posCode: UInt32, caseCode: UInt32, genderCode: UInt32, numberCode: UInt32
    ) {
        if version == 1 {
            return (entry >> 4, entry & 0xF, 0, 0, 0)
        }
        return (
            entry >> 10,
            entry & 0xF,
            (entry >> 4) & 0x7,
            (entry >> 7) & 0x3,
            (entry >> 9) & 0x1
        )
    }
}
