import Foundation

public enum EventLogError: Error, Equatable, CustomStringConvertible {
    /// A word failed `EventLog.isLearnableWord` validation (empty, too long,
    /// contains whitespace/control characters, contains emoji/pictographs,
    /// or contains no letter at all). Pure-emoji and punctuation-only tokens
    /// are rejected by design: they are not vocabulary and would only inflate
    /// the personal store.
    case invalidContent(String)
    case ioError(String)

    public var description: String {
        switch self {
        case .invalidContent(let detail): return "Invalid event content: \(detail)"
        case .ioError(let detail): return "Event log I/O error: \(detail)"
        }
    }
}

/// Append-only, crash-safe learning event log.
///
/// Lives in the App Group container. The **keyboard extension is the only
/// writer** (append), the **containing app is the only compactor**
/// (read + truncate). The package takes a plain `URL` and performs no
/// coordination itself — see "Cross-process coordination" below.
///
/// ## On-disk format (schema version 1)
///
/// UTF-8 text, one record per `\n`-terminated line, tab-separated fields.
/// Field values escape `\` `\t` `\n` `\r` as `\\` `\t` `\n` `\r` (two-char
/// backslash sequences), so a real tab/newline never appears inside a field
/// and line/field framing is trivially recoverable.
///
/// ```
/// #gen<TAB><UUID>                                  ← generation header (first line)
/// 1<TAB><day><TAB>wc<TAB><word><TAB><prev|empty><TAB><is|en|un>
/// 1<TAB><day><TAB>sa<TAB><typed><TAB><accepted>
/// 1<TAB><day><TAB>cr<TAB><original><TAB><applied>
/// 1<TAB><day><TAB>wt<TAB><word>
/// 1<TAB><day><TAB>ts<TAB><keyChar><TAB><dx><TAB><dy>
/// <torn fragment><TAB><TAB>\#torn                  ← healed torn tail (skipped)
/// ```
///
/// - The leading `1` is the per-line schema version; readers skip lines with
///   an unknown version, so future versions can mix records in one file.
/// - `<day>` is the coarse UTC `DayBucket` — the only temporal field
///   (privacy invariant: nothing finer than a day is ever written).
/// - The `#gen` header carries a random UUID minted whenever the file is
///   (re)created. Together with a byte offset it forms `ConsumedMarker`,
///   which lets the compactor prove "I already consumed bytes [0, offset)
///   *of this incarnation of the file*" across truncations and crashes.
///
/// ## Crash-safety guarantees
///
/// - **Appends** use a single `write(2)` on an `O_APPEND` descriptor with
///   the whole batch (one or more full lines) in one buffer. On APFS an
///   `O_APPEND` write of this size is not interleaved with other appends,
///   and a crash mid-write can only produce a torn suffix at EOF — never a
///   hole in the middle of the file.
/// - **Readers tolerate a torn final line**: only `\n`-terminated lines are
///   parsed; trailing unterminated bytes are ignored and excluded from the
///   returned `ConsumedMarker`.
/// - **Appends self-heal a torn tail**: before appending, the writer checks
///   the current last byte and, if it isn't a `\n`, terminates the fragment
///   with `tornMark` + `\n`. The mark is a trailing field that `escape`
///   can never produce (a lone backslash), so readers skip the whole line
///   (counted in `ReadResult.skippedLines`) — a cut inside a free-text last
///   field ("Þórsmörk" → "Þórs") can never heal into a *different*, valid
///   record, and the fragment cannot corrupt the next record either. The
///   at-most-one-event loss window is a deliberate trade — no fsync per
///   keystroke. The mark only ever appears on torn lines, so files written
///   by builds that healed with a bare `\n` decode exactly as before.
/// - **Headerless files are adopted before consumption**
///   (`adoptIfHeaderless`): a file whose header is missing or garbled gets
///   a fresh generation header by atomic rewrite as the compactor's first
///   step, so the compactor never records a `.none` marker with a non-zero
///   offset — an offset can neither be honoured against a *different*
///   headerless file nor be lost to a crash between save and truncate.
///   (An empty file or a still-torn header line yields `(.none, 0)`:
///   nothing consumed, nothing to honour — inert.)
/// - **Truncation** (`truncate(consumedUpTo:)`) rewrites the file atomically
///   (write-temp-then-rename) with a *new* generation UUID, keeping every
///   byte after the consumed offset. A compactor that crashes at any point
///   either re-reads only unconsumed events (generation mismatch resets the
///   offset to the header) or resumes from its stored marker — events are
///   never double-consumed and never lost. See
///   `PersonalModel.compactAndSave(applying:to:)` for the required ordering.
///
/// ## Cross-process coordination (App Group)
///
/// The App Group container is accessed by two processes. Callers on BOTH
/// sides must wrap every `append` / `read` / `truncate` in file coordination
/// (use `CoordinatedFileAccess`) so a truncation can never interleave with
/// an append. Two hard rules at the call boundary:
///
/// 1. Never hold a file descriptor for this URL across coordination blocks
///    (this type never does — every call opens and closes).
/// 2. Keep the extension's coordinated blocks short and synchronous: batch
///    events in memory and flush at word boundaries / lifecycle events, not
///    per keystroke. (Apple warns that long-held coordination in a suspended
///    extension can deadlock the coordinating app.)
public struct EventLog {
    public let url: URL

    /// Injectable day source (tests); defaults to the current UTC day bucket.
    public var dayProvider: () -> Int32

    public init(url: URL, dayProvider: @escaping () -> Int32 = { DayBucket.current() }) {
        self.url = url
        self.dayProvider = dayProvider
    }

    // MARK: - Consumed marker

    /// Position of the compactor's read frontier: "all complete lines of the
    /// file incarnation identified by `generation`, up to byte `offset`,
    /// have been merged into the personal model." Stored inside the
    /// `PersonalModel` file so consumption survives crashes exactly once.
    public struct ConsumedMarker: Codable, Equatable, Sendable {
        public let generation: UUID
        public let offset: UInt64

        public init(generation: UUID, offset: UInt64) {
            self.generation = generation
            self.offset = offset
        }

        /// Marker for a missing/empty log file.
        public static let none = ConsumedMarker(
            generation: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            offset: 0
        )
    }

    public struct ReadResult {
        public let events: [LoggedEvent]
        /// Marker positioned after the last complete line (feed this back
        /// into `read(after:)` / store it in the model as the consume-up-to
        /// point).
        public let endMarker: ConsumedMarker
        /// Complete lines that failed to parse (unknown schema version,
        /// healed torn fragments, hand-edited garbage). Skipped lines ARE
        /// covered by `endMarker` — they are consumed, just not applied.
        public let skippedLines: Int
    }

    // MARK: - Validation

    /// Whether a token is allowed into the learning log as a word.
    ///
    /// Rules: non-empty, at most `maxWordLength` characters, no whitespace or
    /// control characters (a "word" is a single token by definition), no
    /// extended-pictographic scalars (emoji are not vocabulary), and at least
    /// one letter (rejects digit-only and punctuation-only tokens).
    /// Non-ASCII letters — ð þ æ ö á é í ó ú ý and friends — are of course
    /// fine; this keyboard exists for them.
    public static let maxWordLength = 64

    public static func isLearnableWord(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= maxWordLength else { return false }
        var hasLetter = false
        for scalar in word.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            // U+FFFD is what `String(decoding:)` substitutes for a broken
            // UTF-8 sequence — a decoding artefact, never vocabulary.
            if scalar == "\u{FFFD}" { return false }
            // Emoji/pictograph rejection: `isEmoji` alone is true for ASCII
            // digits, so require a scalar beyond the basic ranges (0x203C is
            // the first emoji-capable scalar above ASCII/Latin).
            if scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value >= 0x203C) {
                return false
            }
            if CharacterSet.letters.contains(scalar) { hasLetter = true }
        }
        return hasLetter
    }

    /// Whether a touch offset pair is allowed into the log. Offsets are
    /// normalized to the key cell (±0.5 at its edges), so anything beyond
    /// `maxTouchOffset` key widths is garbage, and NaN/±inf would poison the
    /// per-key Welford aggregates (`TouchKeyStats`) and make the model file
    /// unencodable. The same rule is applied on read, so a line that slipped
    /// in some other way is skipped — not re-read forever.
    public static let maxTouchOffset: Double = 16

    public static func isValidTouchOffset(dx: Double, dy: Double) -> Bool {
        dx.isFinite && dy.isFinite && abs(dx) <= maxTouchOffset && abs(dy) <= maxTouchOffset
    }

    // MARK: - Append (keyboard extension side)

    /// Append a single event. See `append(contentsOf:)`.
    public func append(_ event: LearningEvent) throws {
        try append(contentsOf: [event])
    }

    /// Append a batch of events as one atomic `O_APPEND` write.
    ///
    /// Words are validated with `isLearnableWord`; an invalid primary word
    /// throws `EventLogError.invalidContent` (nothing is written). An invalid
    /// `previousWord` is downgraded to `nil` — the primary word is still
    /// worth learning even when its predecessor was an emoji or a number.
    ///
    /// PRIVACY: the caller must have verified the field context first — see
    /// `LearningPrivacy.assertLoggableFieldContext`.
    public func append(contentsOf events: [LearningEvent]) throws {
        guard !events.isEmpty else { return }
        let day = dayProvider()
        var buffer = ""
        for event in events {
            buffer += try Self.encodeLine(event, day: day)
        }
        try appendRaw(buffer)
    }

    // MARK: - Read (containing app / compactor side)

    /// Read all complete lines after `marker` (or after the generation
    /// header when `marker` is nil or from a different file incarnation).
    /// Tolerates a torn final line; never mutates the file.
    public func read(after marker: ConsumedMarker? = nil) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReadResult(events: [], endMarker: .none, skippedLines: 0)
        }
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            throw EventLogError.ioError("read failed: \(error)")
        }
        let (generation, headerEnd) = Self.parseHeader(bytes)
        guard let headerEnd else {
            // Header line itself is torn (file created but the very first
            // write was interrupted before its newline). Nothing consumable.
            return ReadResult(events: [], endMarker: .none, skippedLines: 0)
        }

        var start = headerEnd
        // The `.none` generation is shared by EVERY headerless incarnation
        // (torn first write, garbled UUID), so an offset taken against one
        // such file proves nothing about another — never resume mid-file
        // there; a headerless file is always read from its first byte. The
        // compactor never persists a `.none` marker past offset 0 (it adopts
        // first, see `adoptIfHeaderless`), so this only ever bites a marker
        // written by a build from before adoption existed.
        if let marker,
           marker.generation == generation,
           generation != ConsumedMarker.none.generation {
            let offset = Int(marker.offset)
            if offset >= headerEnd && offset <= bytes.count {
                start = offset
            }
        }

        var events: [LoggedEvent] = []
        var skipped = 0
        var cursor = start
        var consumedEnd = start
        while cursor < bytes.count {
            guard let newlineIndex = bytes[cursor...].firstIndex(of: 0x0A) else {
                break  // torn final line — leave it out of the marker
            }
            let line = String(decoding: bytes[cursor..<newlineIndex], as: UTF8.self)
            if let logged = Self.decodeLine(line) {
                events.append(logged)
            } else if !line.isEmpty {
                skipped += 1
            }
            cursor = newlineIndex + 1
            consumedEnd = cursor
        }
        return ReadResult(
            events: events,
            endMarker: ConsumedMarker(generation: generation, offset: UInt64(consumedEnd)),
            skippedLines: skipped
        )
    }

    // MARK: - Adopt a headerless file (containing app / compactor side)

    /// Give a file that has no usable generation header — a first write
    /// torn before `#gen\t` completed and later healed, a garbled UUID, or
    /// a file that predates headers — a real identity BEFORE anything is
    /// consumed from it. Such files all share the `.none` sentinel, so an
    /// offset recorded against one can never be trusted against another
    /// (`read(after:)` refuses it); but without an identity a compactor
    /// that crashes between saving its marker and truncating would re-read
    /// the same file from byte 0 and double-apply. Adoption resolves both:
    /// the file is atomically rewritten as `#gen\t<new UUID>\n` + every
    /// data byte after the old (garbled) header line, verbatim — complete
    /// lines keep their exact bytes, a trailing torn fragment stays torn
    /// (the next append still marks it), garbage lines stay garbage — and
    /// the rest of compaction runs on an ordinary generation.
    ///
    /// Crash-safe at every point: the write is write-temp-then-rename, so
    /// the file is either the old headerless one (nothing consumed, nothing
    /// persisted — the next compaction simply adopts again) or the fully
    /// adopted one. Concurrent extension appends are excluded exactly as
    /// for `truncate`: callers run this inside the same coordinated-write
    /// block as the read that follows (`PersonalModel.compact` does).
    ///
    /// Returns the new generation when the file was adopted; nil when it
    /// already had one, is missing/empty, or its header line is still torn
    /// (nothing is consumable from such a file, so nothing needs identity;
    /// the next append heals it into a garbled header and adoption happens
    /// on the following compaction).
    @discardableResult
    public func adoptIfHeaderless() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            throw EventLogError.ioError("read for adopt failed: \(error)")
        }
        guard !bytes.isEmpty else { return nil }
        let (generation, headerEnd) = Self.parseHeader(bytes)
        guard generation == ConsumedMarker.none.generation, let headerEnd else { return nil }

        let newGeneration = UUID()
        var newContents = Data(Self.headerLine(generation: newGeneration).utf8)
        newContents.append(contentsOf: bytes[headerEnd...])
        do {
            try newContents.write(to: url, options: .atomic)
        } catch {
            throw EventLogError.ioError("adopt rewrite failed: \(error)")
        }
        return newGeneration
    }

    // MARK: - Truncate (containing app / compactor side)

    /// Drop the consumed prefix `[header, marker.offset)`, preserving every
    /// byte a concurrent writer appended after the compactor's read. The
    /// file is rewritten atomically with a fresh generation UUID and the
    /// unconsumed tail; returns the marker for "nothing of the new file
    /// consumed yet".
    ///
    /// Safe orderings (all enforced by `PersonalModel.compactAndSave`):
    /// - Crash before: model already saved with the old-generation marker →
    ///   next compaction resumes after `marker.offset`, no double count.
    /// - Crash after: model still holds the old-generation marker, but the
    ///   file now has a new generation → the mismatch resets the read to the
    ///   header, and the file contains only unconsumed events. No loss, no
    ///   double count.
    ///
    /// If the file's generation no longer matches `marker.generation` (the
    /// log was already rotated) this is a no-op and returns `marker`
    /// unchanged — as is a `.none` marker, whatever the file: the sentinel
    /// is shared by every headerless incarnation, so such an offset proves
    /// nothing (use `adoptIfHeaderless` first; `PersonalModel.compact`
    /// does). Must run inside the same coordinated-write block as the
    /// `read` that produced `marker` (see `CoordinatedFileAccess`), so no
    /// append can land between read and truncate unseen.
    @discardableResult
    public func truncate(consumedUpTo marker: ConsumedMarker) throws -> ConsumedMarker {
        guard marker.generation != ConsumedMarker.none.generation else { return marker }
        guard FileManager.default.fileExists(atPath: url.path) else { return marker }
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: url))
        } catch {
            throw EventLogError.ioError("read for truncate failed: \(error)")
        }
        let (generation, headerEnd) = Self.parseHeader(bytes)
        guard headerEnd != nil, generation == marker.generation else { return marker }

        let tailStart = min(Int(marker.offset), bytes.count)
        let newGeneration = UUID()
        var newContents = Data(Self.headerLine(generation: newGeneration).utf8)
        let newOffset = UInt64(newContents.count)
        if tailStart < bytes.count {
            newContents.append(contentsOf: bytes[tailStart...])
        }
        do {
            try newContents.write(to: url, options: .atomic)
        } catch {
            throw EventLogError.ioError("truncate rewrite failed: \(error)")
        }
        return ConsumedMarker(generation: newGeneration, offset: newOffset)
    }

    // MARK: - Line codec

    static func headerLine(generation: UUID) -> String {
        "#gen\t\(generation.uuidString)\n"
    }

    /// Appended (on the same line) to a torn tail before the healing `\n`.
    /// Two tabs then a lone backslash: `escape` only ever emits `\\` `\t`
    /// `\n` `\r`, and every other field is a fixed token or a number, so no
    /// well-formed line can end this way — `decodeLine` rejects any line
    /// carrying it, whatever its field count happens to be. The DOUBLE tab
    /// is for readers that predate the mark (a downgraded install) and only
    /// check field counts: it adds two fields to every fragment, so none of
    /// them can land on a record's exact count with a non-empty last field
    /// (`sa`/`cr` accept any non-empty 5th field — one tab would have let
    /// `1 d sa typed` + mark decode as a 5-field record).
    static let tornMark = "\t\t\\#torn"

    /// Returns (generation, byte offset just past the header's newline).
    /// `headerEnd == nil` means the header line is torn/unreadable.
    /// A file that doesn't start with `#gen` is treated as generation
    /// `.none` with the data starting at offset 0.
    ///
    /// The UUID field ends at the first tab, so a header that merely lost
    /// its newline and was healed (`#gen\t<UUID>` + `tornMark`) keeps its
    /// real generation rather than degrading to `.none`.
    static func parseHeader(_ bytes: [UInt8]) -> (generation: UUID, headerEnd: Int?) {
        let prefix = Array("#gen\t".utf8)
        guard bytes.count >= prefix.count, Array(bytes[0..<prefix.count]) == prefix else {
            // Empty file, or a file that predates the header — treat all
            // bytes as data belonging to the "none" generation.
            return (ConsumedMarker.none.generation, 0)
        }
        guard let newlineIndex = bytes.firstIndex(of: 0x0A) else {
            return (ConsumedMarker.none.generation, nil)
        }
        let uuidField = bytes[prefix.count..<newlineIndex].prefix { $0 != 0x09 }
        let uuidString = String(decoding: uuidField, as: UTF8.self)
        guard let uuid = UUID(uuidString: uuidString) else {
            return (ConsumedMarker.none.generation, newlineIndex + 1)
        }
        return (uuid, newlineIndex + 1)
    }

    static func encodeLine(_ event: LearningEvent, day: Int32) throws -> String {
        func validated(_ word: String, field: String) throws -> String {
            guard isLearnableWord(word) else {
                throw EventLogError.invalidContent("\(field) is not a learnable word")
            }
            return escape(word)
        }
        let fields: [String]
        switch event {
        case .wordCommitted(let word, let previousWord, let hint):
            let prev: String
            if let previousWord, isLearnableWord(previousWord) {
                prev = escape(previousWord)
            } else {
                prev = ""  // invalid predecessor downgrades to nil
            }
            fields = ["wc", try validated(word, field: "word"), prev, hint.rawValue]
        case .suggestionAccepted(let typed, let accepted):
            fields = ["sa", try validated(typed, field: "typed"), try validated(accepted, field: "accepted")]
        case .correctionReverted(let original, let applied):
            fields = ["cr", try validated(original, field: "original"), try validated(applied, field: "applied")]
        case .wordTapped(let word):
            fields = ["wt", try validated(word, field: "word")]
        case .touchSample(let keyChar, let dx, let dy):
            guard isValidTouchOffset(dx: dx, dy: dy) else {
                throw EventLogError.invalidContent("touch offset is not finite / in range")
            }
            fields = [
                "ts",
                escape(String(keyChar)),
                String(format: "%.4f", dx),
                String(format: "%.4f", dy),
            ]
        }
        return "1\t\(day)\t" + fields.joined(separator: "\t") + "\n"
    }

    /// Readers re-apply the writer's validation (`isLearnableWord`,
    /// `isValidTouchOffset`) rather than trusting the file: a hand-edited,
    /// bit-flipped or torn line must never put something into the model that
    /// `append` would have refused. Well-formed lines written by any shipped
    /// build pass unchanged — the rules are the same ones they were written
    /// under. An invalid `previousWord` downgrades to nil, as on write.
    static func decodeLine(_ line: String) -> LoggedEvent? {
        guard !line.hasSuffix(tornMark) else { return nil }  // healed torn fragment
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, fields[0] == "1", let day = Int32(fields[1]) else { return nil }
        switch fields[2] {
        case "wc":
            guard fields.count == 6, let hint = LanguageHint(rawValue: fields[5]) else { return nil }
            let word = unescape(fields[3])
            guard isLearnableWord(word) else { return nil }
            let prev = unescape(fields[4])
            return LoggedEvent(day: day, event: .wordCommitted(
                word: word,
                previousWord: isLearnableWord(prev) ? prev : nil,
                languageHint: hint))
        case "sa":
            guard fields.count == 5 else { return nil }
            let typed = unescape(fields[3]), accepted = unescape(fields[4])
            guard isLearnableWord(typed), isLearnableWord(accepted) else { return nil }
            return LoggedEvent(day: day, event: .suggestionAccepted(typed: typed, accepted: accepted))
        case "cr":
            guard fields.count == 5 else { return nil }
            let original = unescape(fields[3]), applied = unescape(fields[4])
            guard isLearnableWord(original), isLearnableWord(applied) else { return nil }
            return LoggedEvent(day: day, event: .correctionReverted(original: original, applied: applied))
        case "wt":
            guard fields.count == 4 else { return nil }
            let word = unescape(fields[3])
            guard isLearnableWord(word) else { return nil }
            return LoggedEvent(day: day, event: .wordTapped(word: word))
        case "ts":
            guard fields.count == 6, let dx = Double(fields[4]), let dy = Double(fields[5]),
                  isValidTouchOffset(dx: dx, dy: dy) else { return nil }
            let key = unescape(fields[3])
            guard key.count == 1, let keyChar = key.first else { return nil }
            return LoggedEvent(day: day, event: .touchSample(keyChar: keyChar, dx: dx, dy: dy))
        default:
            return nil  // unknown event code or schema version — skip
        }
    }

    static func escape(_ field: String) -> String {
        var out = ""
        out.reserveCapacity(field.count)
        for char in field {
            switch char {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(char)
            }
        }
        return out
    }

    static func unescape(_ field: String) -> String {
        guard field.contains("\\") else { return field }
        var out = ""
        out.reserveCapacity(field.count)
        var iterator = field.makeIterator()
        while let char = iterator.next() {
            if char == "\\", let next = iterator.next() {
                switch next {
                case "\\": out.append("\\")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default:
                    out.append(char)
                    out.append(next)
                }
            } else {
                out.append(char)
            }
        }
        return out
    }

    // MARK: - Raw append

    /// One `open(O_RDWR|O_APPEND|O_CREAT)` + one `write(2)` of the whole
    /// batch. Writes the generation header first when the file is empty, and
    /// a healing `tornMark` + `\n` first when the current tail is torn.
    private func appendRaw(_ lines: String) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        }
        guard fd >= 0 else {
            throw EventLogError.ioError("open failed: errno \(errno)")
        }
        defer { close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw EventLogError.ioError("fstat failed: errno \(errno)")
        }

        var payload = ""
        if status.st_size == 0 {
            payload += Self.headerLine(generation: UUID())
        } else {
            var lastByte: UInt8 = 0
            let readCount = pread(fd, &lastByte, 1, status.st_size - 1)
            if readCount == 1 && lastByte != 0x0A {
                // Heal a torn tail into an isolated, MARKED garbage line —
                // the mark is what stops a cut inside a word from healing
                // into a shorter, perfectly valid word.
                payload += Self.tornMark + "\n"
            }
        }
        payload += lines

        let data = Array(payload.utf8)
        var written = 0
        while written < data.count {
            let result = data[written...].withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw EventLogError.ioError("write failed: errno \(errno)")
            }
            written += result
        }
    }
}
