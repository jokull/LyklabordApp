import Foundation

/// Part of speech of a paradigm lemma group (`paradigms.bin` scope v1:
/// nouns + adjectives only — see data/is/PARADIGMS_FORMAT.md "Scope").
public enum ParadigmPOS: UInt8, Sendable, Equatable {
    case noun = 0
    case adjective = 1
}

/// Packed BÍN grammatical feature bundle — the `uint16` encoding produced by
/// `scripts/bin_morph.py` (`pack_noun_bundle` / `pack_adj_bundle`) and stored
/// per entry in `paradigms.bin`. This type is the single Swift home of the
/// bit layout (mirroring the format doc's instruction that the decode logic
/// live in exactly one place):
///
///     bit(s)  field         values
///     0-1     case          0=nf 1=þf 2=þgf 3=ef
///     2       number        0=et 1=ft
///     3       pos           0=noun 1=adjective
///     -- noun:      bit 4 definiteness (0=ngr 1=gr)
///     -- adjective: bits 4-5 gender (kk/kvk/hk), 6-7 degree (fst/mst/est),
///                   bit 8 strength (0=sb 1=vb)
public struct ParadigmBundle: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Grammatical-case names in bundle-code order (0-3). The same strings
    /// `lemmatizeWithMorph` and governors.json use.
    public static let caseNames = ["nf", "þf", "þgf", "ef"]

    /// Case code 0-3 (nf/þf/þgf/ef).
    public var caseCode: Int { Int(rawValue & 0x3) }
    public var caseName: String { Self.caseNames[caseCode] }
    /// false = singular (et), true = plural (ft).
    public var isPlural: Bool { (rawValue >> 2) & 0x1 == 1 }
    public var pos: ParadigmPOS { (rawValue >> 3) & 0x1 == 0 ? .noun : .adjective }

    /// Noun only: article-suffixed (definite) form.
    public var isDefinite: Bool { pos == .noun && (rawValue >> 4) & 0x1 == 1 }

    /// Adjective only: per-form agreement gender 0=kk 1=kvk 2=hk.
    public var adjectiveGenderCode: Int { Int((rawValue >> 4) & 0x3) }
    /// Adjective only: degree 0=fst(positive) 1=mst(comparative) 2=est(superlative).
    public var adjectiveDegreeCode: Int { Int((rawValue >> 6) & 0x3) }
    /// Adjective only: weak declension (vb) vs strong (sb).
    public var adjectiveIsWeak: Bool { (rawValue >> 8) & 0x1 == 1 }

    /// Convenience factory for a noun bundle (tests, wrong-form targets).
    public static func noun(caseCode: Int, plural: Bool = false, definite: Bool = false)
        -> ParadigmBundle
    {
        var raw = UInt16(caseCode & 0x3)
        if plural { raw |= 1 << 2 }
        if definite { raw |= 1 << 4 }
        return ParadigmBundle(rawValue: raw)
    }

    /// The same bundle with only the grammatical case replaced — the
    /// "swap the governed axis, keep every agreement axis" operation the
    /// wrong-form machinery needs (hestur no:nf:et:ngr → no:þgf:et:ngr).
    public func replacingCase(_ code: Int) -> ParadigmBundle {
        ParadigmBundle(rawValue: (rawValue & ~0x3) | UInt16(code & 0x3))
    }

    /// Human-readable rendering, byte-identical to `bin_morph.py`'s
    /// `bundle_to_string` (the string form used in governors.json and
    /// debug output): "no:þgf:et:gr", "lo:nf:et:kk:fst:sb".
    public var description: String {
        let number = isPlural ? "ft" : "et"
        if pos == .noun {
            return "no:\(caseName):\(number):\(isDefinite ? "gr" : "ngr")"
        }
        let gender = ["kk", "kvk", "hk", "?"][adjectiveGenderCode]
        let degree = ["fst", "mst", "est", "?"][adjectiveDegreeCode]
        return "lo:\(caseName):\(number):\(gender):\(degree):\(adjectiveIsWeak ? "vb" : "sb")"
    }
}

/// One (surface form, feature bundle) entry of a lemma group.
public struct ParadigmForm: Equatable, Sendable {
    public let form: String
    public let bundle: ParadigmBundle

    public init(form: String, bundle: ParadigmBundle) {
        self.form = form
        self.bundle = bundle
    }
}

/// One lemma group: the `(lemma, pos, gender)` paradigm unit of
/// `paradigms.bin` (gender is intrinsic for noun lemmas; the 0xFF sentinel
/// for adjectives, where gender is a per-form axis).
public struct ParadigmGroup: Equatable, Sendable {
    public let lemma: String
    public let pos: ParadigmPOS
    /// Noun: 0=kk 1=kvk 2=hk. Adjective: 0xFF (not a lemma property).
    public let genderCode: UInt8
    public let forms: [ParadigmForm]

    public init(lemma: String, pos: ParadigmPOS, genderCode: UInt8, forms: [ParadigmForm]) {
        self.lemma = lemma
        self.pos = pos
        self.genderCode = genderCode
        self.forms = forms
    }
}

/// One analysis of a surface form: which lemma group it belongs to and with
/// which feature bundle.
public struct ParadigmAnalysis: Equatable, Sendable {
    public let lemma: String
    public let pos: ParadigmPOS
    /// Same encoding as `ParadigmGroup.genderCode`.
    public let genderCode: UInt8
    public let bundle: ParadigmBundle

    public init(lemma: String, pos: ParadigmPOS, genderCode: UInt8, bundle: ParadigmBundle) {
        self.lemma = lemma
        self.pos = pos
        self.genderCode = genderCode
        self.bundle = bundle
    }
}

public enum ParadigmsReaderError: Error, CustomStringConvertible {
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidMagic(let m):
            return "Invalid paradigms format: expected magic 0x50415231, got 0x\(String(m, radix: 16))"
        case .unsupportedVersion(let v):
            return "Unsupported paradigms version: \(v)"
        case .truncated(let expected, let actual):
            return "Truncated paradigms binary: need \(expected) bytes, file has \(actual)"
        }
    }
}

/// Reader for `data/is/paradigms.bin` — the GENERATION direction of BÍN
/// morphology (lemma → every form + feature bundle) built by
/// `scripts/build-paradigms.py`; format contract in
/// `data/is/PARADIGMS_FORMAT.md`.
///
/// Same memory strategy as `BinaryLemmatizer`: the file is memory-mapped
/// (`.alwaysMapped`) and never parsed into Swift collections. The
/// initializer reads the 32-byte header and computes the five section
/// offsets; every lookup is a binary search over the sorted lemma-group /
/// surface-form tables plus a bounded scan, straight off the mapped buffer.
/// File-backed clean pages don't count against the keyboard-extension
/// jetsam limit, so resident cost is only the pages actually touched.
///
/// All strings in the artifact are lowercased at build time
/// (`bin_morph.iter_bin_rows` lowers both lemma and form), so lookups
/// lowercase their input, mirroring `BinaryLemmatizer`.
public final class ParadigmsReader {

    /// Bytes 'P','A','R','1' on disk, read as a little-endian u32.
    private static let magic: UInt32 = 0x5041_5231

    private let data: Data

    public let version: Int
    public let groupCount: Int
    public let entryCount: Int
    public let formCount: Int
    public let minLemmaFreq: Int

    // Section byte offsets from the start of the file.
    private let stringPoolOffset: Int
    private let groupTableOffset: Int
    private let entriesOffset: Int
    private let formTableOffset: Int
    private let permutationOffset: Int

    private static let groupRecordSize = 16
    private static let entryRecordSize = 12
    private static let formRecordSize = 16

    /// Memory-map a `paradigms.bin`. Preferred entry point on iOS/macOS.
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    /// Wrap an already-loaded buffer (tests, in-memory fixtures).
    public init(data: Data) throws {
        self.data = data

        guard data.count >= 32 else {
            throw ParadigmsReaderError.truncated(expected: 32, actual: data.count)
        }

        func u32(_ byteOffset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
            }
        }

        let magic = u32(0)
        guard magic == Self.magic else {
            throw ParadigmsReaderError.invalidMagic(magic)
        }
        let versionRaw = u32(4)
        guard versionRaw == 1 else {
            throw ParadigmsReaderError.unsupportedVersion(versionRaw)
        }
        self.version = Int(versionRaw)

        let stringPoolSize = Int(u32(8))  // already padded to 4 by the writer
        self.groupCount = Int(u32(12))
        self.entryCount = Int(u32(16))
        self.formCount = Int(u32(20))
        self.minLemmaFreq = Int(u32(24))
        // u32 at 28 is reserved (must be 0; tolerated either way)

        var offset = 32
        stringPoolOffset = offset
        offset += stringPoolSize
        groupTableOffset = offset
        offset += groupCount * Self.groupRecordSize
        entriesOffset = offset
        offset += entryCount * Self.entryRecordSize
        formTableOffset = offset
        offset += formCount * Self.formRecordSize
        permutationOffset = offset
        offset += entryCount * 4

        guard data.count >= offset else {
            throw ParadigmsReaderError.truncated(expected: offset, actual: data.count)
        }
    }

    // MARK: - Public API

    /// Access pattern (a) of the format doc: every lemma group whose lemma
    /// string equals `lemma` (lowercased), each with its full form table.
    /// Usually one group; occasionally more (noun/adjective spelling
    /// collision, or two noun genders). Unknown lemma → [].
    public func groups(ofLemma lemma: String) -> [ParadigmGroup] {
        let key = Array(lemma.lowercased().utf8)
        return withBuffer { buf in
            var index = lowerBoundGroup(key, in: buf)
            var result: [ParadigmGroup] = []
            while index < groupCount {
                let record = groupRecord(index, in: buf)
                guard
                    compareKey(key, poolOffset: record.lemmaOffset, poolLength: record.lemmaLen, in: buf)
                        == 0
                else { break }
                var forms: [ParadigmForm] = []
                forms.reserveCapacity(record.entryCount)
                for entryIndex in record.entryStart..<(record.entryStart + record.entryCount) {
                    let entry = entryRecord(entryIndex, in: buf)
                    forms.append(
                        ParadigmForm(
                            form: poolString(buf, offset: entry.formOffset, length: entry.formLen),
                            bundle: ParadigmBundle(rawValue: entry.bundle)
                        )
                    )
                }
                result.append(
                    ParadigmGroup(
                        lemma: poolString(buf, offset: record.lemmaOffset, length: record.lemmaLen),
                        pos: record.pos == 0 ? .noun : .adjective,
                        genderCode: record.gender,
                        forms: forms
                    )
                )
                index += 1
            }
            return result
        }
    }

    /// Access pattern (b): every (lemma group, feature bundle) analysis of a
    /// surface form (lowercased), across all lemma groups. Unknown form → [].
    public func analyses(ofForm form: String) -> [ParadigmAnalysis] {
        let key = Array(form.lowercased().utf8)
        return withBuffer { buf in
            let index = lowerBoundForm(key, in: buf)
            guard index < formCount else { return [] }
            let record = formRecord(index, in: buf)
            guard
                compareKey(key, poolOffset: record.formOffset, poolLength: record.formLen, in: buf)
                    == 0
            else { return [] }
            var result: [ParadigmAnalysis] = []
            result.reserveCapacity(record.permCount)
            for permIndex in record.permStart..<(record.permStart + record.permCount) {
                let entryIndex = Int(
                    readU32(buf, at: permutationOffset + permIndex * 4))
                let entry = entryRecord(entryIndex, in: buf)
                let group = groupRecord(entry.groupIndex, in: buf)
                result.append(
                    ParadigmAnalysis(
                        lemma: poolString(buf, offset: group.lemmaOffset, length: group.lemmaLen),
                        pos: group.pos == 0 ? .noun : .adjective,
                        genderCode: group.gender,
                        bundle: ParadigmBundle(rawValue: entry.bundle)
                    )
                )
            }
            return result
        }
    }

    /// Scoring hot path: the distinct feature bundles across a surface
    /// form's analyses, reading only the packed u16s — no lemma/form
    /// strings are materialized (this runs once per correction candidate
    /// per keystroke).
    public func bundles(ofForm form: String) -> [ParadigmBundle] {
        let key = Array(form.lowercased().utf8)
        return withBuffer { buf in
            let index = lowerBoundForm(key, in: buf)
            guard index < formCount else { return [] }
            let record = formRecord(index, in: buf)
            guard
                compareKey(key, poolOffset: record.formOffset, poolLength: record.formLen, in: buf)
                    == 0
            else { return [] }
            var bundles: [ParadigmBundle] = []
            bundles.reserveCapacity(record.permCount)
            for permIndex in record.permStart..<(record.permStart + record.permCount) {
                let entryIndex = Int(readU32(buf, at: permutationOffset + permIndex * 4))
                let raw = readU16(buf, at: entriesOffset + entryIndex * Self.entryRecordSize + 9)
                let bundle = ParadigmBundle(rawValue: raw)
                if !bundles.contains(bundle) { bundles.append(bundle) }
            }
            return bundles
        }
    }

    /// The distinct grammatical-case codes (0=nf 1=þf 2=þgf 3=ef) across a
    /// surface form's analyses, bundles-only read like `bundles(ofForm:)`.
    public func caseCodes(ofForm form: String) -> [Int] {
        let key = Array(form.lowercased().utf8)
        return withBuffer { buf in
            let index = lowerBoundForm(key, in: buf)
            guard index < formCount else { return [] }
            let record = formRecord(index, in: buf)
            guard
                compareKey(key, poolOffset: record.formOffset, poolLength: record.formLen, in: buf)
                    == 0
            else { return [] }
            var seen = (false, false, false, false)
            for permIndex in record.permStart..<(record.permStart + record.permCount) {
                let entryIndex = Int(readU32(buf, at: permutationOffset + permIndex * 4))
                let bundle = readU16(buf, at: entriesOffset + entryIndex * Self.entryRecordSize + 9)
                switch bundle & 0x3 {
                case 0: seen.0 = true
                case 1: seen.1 = true
                case 2: seen.2 = true
                default: seen.3 = true
                }
            }
            var codes: [Int] = []
            if seen.0 { codes.append(0) }
            if seen.1 { codes.append(1) }
            if seen.2 { codes.append(2) }
            if seen.3 { codes.append(3) }
            return codes
        }
    }

    /// Whether the surface form exists in the paradigm tables at all.
    public func isKnownForm(_ form: String) -> Bool {
        let key = Array(form.lowercased().utf8)
        return withBuffer { buf in
            let index = lowerBoundForm(key, in: buf)
            guard index < formCount else { return false }
            let record = formRecord(index, in: buf)
            return compareKey(key, poolOffset: record.formOffset, poolLength: record.formLen, in: buf)
                == 0
        }
    }

    /// Raw mapped size in bytes (virtual; resident stays near zero — the
    /// buffer is file-backed).
    public var bufferSize: Int { data.count }

    // MARK: - Record decoding

    private struct GroupRecord {
        let lemmaOffset: Int
        let lemmaLen: Int
        let pos: UInt8
        let gender: UInt8
        let entryStart: Int
        let entryCount: Int
    }

    private struct EntryRecord {
        let groupIndex: Int
        let formOffset: Int
        let formLen: Int
        let bundle: UInt16
    }

    private struct FormRecord {
        let formOffset: Int
        let formLen: Int
        let permStart: Int
        let permCount: Int
    }

    @inline(__always)
    private func withBuffer<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        data.withUnsafeBytes(body)
    }

    @inline(__always)
    private func readU32(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt32 {
        buf.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
    }

    @inline(__always)
    private func readU16(_ buf: UnsafeRawBufferPointer, at byteOffset: Int) -> UInt16 {
        buf.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self).littleEndian
    }

    @inline(__always)
    private func groupRecord(_ index: Int, in buf: UnsafeRawBufferPointer) -> GroupRecord {
        let base = groupTableOffset + index * Self.groupRecordSize
        return GroupRecord(
            lemmaOffset: Int(readU32(buf, at: base)),
            lemmaLen: Int(buf[base + 4]),
            pos: buf[base + 5],
            gender: buf[base + 6],
            // base + 7 is pad
            entryStart: Int(readU32(buf, at: base + 8)),
            entryCount: Int(readU32(buf, at: base + 12))
        )
    }

    @inline(__always)
    private func entryRecord(_ index: Int, in buf: UnsafeRawBufferPointer) -> EntryRecord {
        let base = entriesOffset + index * Self.entryRecordSize
        return EntryRecord(
            groupIndex: Int(readU32(buf, at: base)),
            formOffset: Int(readU32(buf, at: base + 4)),
            formLen: Int(buf[base + 8]),
            bundle: readU16(buf, at: base + 9)  // unaligned by design (12-byte record)
        )
    }

    @inline(__always)
    private func formRecord(_ index: Int, in buf: UnsafeRawBufferPointer) -> FormRecord {
        let base = formTableOffset + index * Self.formRecordSize
        return FormRecord(
            formOffset: Int(readU32(buf, at: base)),
            formLen: Int(buf[base + 4]),
            // base + 5..7 are pad
            permStart: Int(readU32(buf, at: base + 8)),
            permCount: Int(readU32(buf, at: base + 12))
        )
    }

    @inline(__always)
    private func poolString(_ buf: UnsafeRawBufferPointer, offset: Int, length: Int) -> String {
        let start = stringPoolOffset + offset
        let bytes = UnsafeRawBufferPointer(rebasing: buf[start..<start + length])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Raw-UTF-8-byte comparison of `key` against a pool string (Unicode
    /// code-point order — identical to the Python writer's `.encode('utf-8')`
    /// sort keys).
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

    /// First group index whose lemma is >= key (lemma bytes are the primary
    /// sort key, so all groups for one lemma form a contiguous run here).
    private func lowerBoundGroup(_ key: [UInt8], in buf: UnsafeRawBufferPointer) -> Int {
        var low = 0
        var high = groupCount
        while low < high {
            let mid = (low + high) >> 1
            let record = groupRecord(mid, in: buf)
            if compareKey(key, poolOffset: record.lemmaOffset, poolLength: record.lemmaLen, in: buf)
                > 0
            {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// First form-table index whose form is >= key (forms are unique, so
    /// this is a plain binary search with an equality check at the caller).
    private func lowerBoundForm(_ key: [UInt8], in buf: UnsafeRawBufferPointer) -> Int {
        var low = 0
        var high = formCount
        while low < high {
            let mid = (low + high) >> 1
            let record = formRecord(mid, in: buf)
            if compareKey(key, poolOffset: record.formOffset, poolLength: record.formLen, in: buf)
                > 0
            {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
