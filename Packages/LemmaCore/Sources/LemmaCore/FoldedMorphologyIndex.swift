import Foundation

public enum FoldedMorphologyIndexError: Error, CustomStringConvertible {
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt32)
    case truncated(expected: Int, actual: Int)
    case sourceWordFormCount(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidMagic(let magic):
            return "Invalid folded morphology magic: 0x\(String(magic, radix: 16))"
        case .unsupportedVersion(let version):
            return "Unsupported folded morphology version: \(version)"
        case .truncated(let expected, let actual):
            return "Truncated folded morphology index: need \(expected) bytes, file has \(actual)"
        case .sourceWordFormCount(let expected, let actual):
            return "Folded morphology source mismatch: expected \(expected) forms, got \(actual)"
        }
    }
}

/// Mmap-backed exact reverse index from an accent-stripped key to canonical
/// word-form ids in one matching `BinaryLemmatizer` artifact.
public final class FoldedMorphologyIndex {
    private static let magic: UInt32 = 0x4642_4931  // "FBI1"

    private let data: Data
    public let version: Int
    public let keyCount: Int
    public let referenceCount: Int
    public let sourceWordFormCount: Int

    private let keyPoolOffset = 32
    private let keyPoolSize: Int
    private let keyOffsetsOffset: Int
    private let keyLengthsOffset: Int
    private let valueOffsetsOffset: Int
    private let wordIDsOffset: Int

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 32 else {
            throw FoldedMorphologyIndexError.truncated(expected: 32, actual: data.count)
        }

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }

        let magic = u32(0)
        guard magic == Self.magic else {
            throw FoldedMorphologyIndexError.invalidMagic(magic)
        }
        let rawVersion = u32(4)
        guard rawVersion == 1 else {
            throw FoldedMorphologyIndexError.unsupportedVersion(rawVersion)
        }

        version = Int(rawVersion)
        keyCount = Int(u32(8))
        referenceCount = Int(u32(12))
        keyPoolSize = Int(u32(16))
        sourceWordFormCount = Int(u32(20))

        var offset = keyPoolOffset + keyPoolSize
        keyOffsetsOffset = offset
        offset += keyCount * 4
        keyLengthsOffset = offset
        offset += keyCount
        offset = (offset + 3) & ~3
        valueOffsetsOffset = offset
        offset += (keyCount + 1) * 4
        wordIDsOffset = offset
        offset += referenceCount * 4

        guard data.count >= offset else {
            throw FoldedMorphologyIndexError.truncated(expected: offset, actual: data.count)
        }
    }

    /// Source word-form ids for `foldedKey`, or `[]` when absent.
    public func wordFormIDs(matching foldedKey: String) -> [UInt32] {
        let key = Array(foldedKey.lowercased().utf8)
        guard !key.isEmpty else { return [] }
        return data.withUnsafeBytes { buffer in
            guard let index = findKey(key, in: buffer) else { return [] }
            let start = Int(readU32(buffer, at: valueOffsetsOffset + index * 4))
            let end = Int(readU32(buffer, at: valueOffsetsOffset + (index + 1) * 4))
            guard start <= end, end <= referenceCount else { return [] }
            return (start..<end).map { readU32(buffer, at: wordIDsOffset + $0 * 4) }
        }
    }

    public var bufferSize: Int { data.count }

    @inline(__always)
    private func readU32(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }

    private func findKey(_ key: [UInt8], in buffer: UnsafeRawBufferPointer) -> Int? {
        var left = 0
        var right = keyCount - 1
        while left <= right {
            let middle = (left + right) >> 1
            let poolOffset = Int(readU32(buffer, at: keyOffsetsOffset + middle * 4))
            let length = Int(buffer[keyLengthsOffset + middle])
            guard poolOffset <= keyPoolSize, length <= keyPoolSize - poolOffset else {
                return nil
            }
            let comparison = compare(
                key, poolOffset: poolOffset, poolLength: length, in: buffer)
            if comparison == 0 { return middle }
            if comparison > 0 { left = middle + 1 } else { right = middle - 1 }
        }
        return nil
    }

    @inline(__always)
    private func compare(
        _ key: [UInt8], poolOffset: Int, poolLength: Int,
        in buffer: UnsafeRawBufferPointer
    ) -> Int {
        let base = keyPoolOffset + poolOffset
        let count = min(key.count, poolLength)
        for index in 0..<count {
            let lhs = key[index]
            let rhs = buffer[base + index]
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        if key.count == poolLength { return 0 }
        return key.count < poolLength ? -1 : 1
    }
}
