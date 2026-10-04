import Foundation

/// A bounded, read-only LevelDB reader for a single Chromium Local Storage key.
/// Follows the live MANIFEST: scanning arbitrary old SST files can resurrect deleted pins.
/// Never opens the database, acquires its write lock, or returns unrelated storage entries.
enum ChromiumLocalStorageReader {
    enum ReadError: Error { case invalid, changed, limit }
    private static let maximumSize = 32 * 1024 * 1024
    private struct Bytes {
        var data: [UInt8]
        var position = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position <= data.count, count <= data.count - position else { throw ReadError.invalid }
            defer { position += count }
            return Array(data[position..<position + count])
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let byte = try take(1)[0]
                guard shift != 63 || byte <= 1 else { throw ReadError.invalid }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw ReadError.invalid
        }
        mutating func integer() throws -> Int {
            let value = try varint()
            guard value <= UInt64(maximumSize) else { throw ReadError.limit }
            return Int(value)
        }
        mutating func string() throws -> [UInt8] { try take(integer()) }
    }
    private static func fixed(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f63b78 : 0) }
        return crc
    }
    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        crc ^= 0xffffffff
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }
    private static func readFile(_ url: URL) throws -> [UInt8] {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true,
              let size = info.fileSize, size <= maximumSize else { throw ReadError.limit }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumSize else { throw ReadError.limit }
        return Array(data)
    }

    private static func records(_ bytes: [UInt8], trailingAllowed: Bool) throws -> [[UInt8]] {
        var result: [[UInt8]] = [], pending: [UInt8]? = nil, offset = 0
        while offset < bytes.count {
            let remaining = 32768 - offset % 32768
            if remaining < 7 { offset += remaining; continue }
            guard offset + 7 <= bytes.count else {
                if trailingAllowed { break }; throw ReadError.changed
            }
            let length = Int(fixed(bytes[offset + 4..<offset + 6]))
            let type = bytes[offset + 6]
            if type == 0, length == 0 {
                guard bytes[offset..<min(bytes.count, offset + remaining)].allSatisfy({ $0 == 0 }) else { throw ReadError.invalid }
                offset += remaining; continue
            }
            guard length <= remaining - 7 else { throw ReadError.invalid }
            guard offset + 7 + length <= bytes.count else {
                if trailingAllowed { break }; throw ReadError.changed
            }
            let body = Array(bytes[offset + 7..<offset + 7 + length])
            guard checksum([type] + body) == UInt32(fixed(bytes[offset..<offset + 4])) else { throw ReadError.changed }
            switch type {
            case 1:
                guard pending == nil else { throw ReadError.invalid }; result.append(body)
            case 2:
                guard pending == nil else { throw ReadError.invalid }; pending = body
            case 3, 4:
                guard pending != nil else { throw ReadError.invalid }
                pending!.append(contentsOf: body)
                guard pending!.count <= maximumSize else { throw ReadError.limit }
                if type == 4 { result.append(pending!); pending = nil }
            default: throw ReadError.invalid
            }
            offset += 7 + length
        }
        if pending != nil && !trailingAllowed { throw ReadError.changed }
        return result
    }

    /// Raw Snappy block decoder (LevelDB's compressed blocks are not framed streams).
    static func decodeSnappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var input = Bytes(data: bytes)
        let length = try input.integer()
        var output: [UInt8] = []; output.reserveCapacity(length)
        while input.position < bytes.count {
            let tag = try input.take(1)[0]
            if tag & 3 == 0 {
                var count = Int(tag >> 2) + 1
                if count >= 61 {
                    let encoded = try input.take(count - 60)
                    let value = fixed(encoded[...])
                    guard value < UInt64(maximumSize) else { throw ReadError.limit }
                    count = Int(value) + 1
                }
                guard count <= length - output.count else { throw ReadError.invalid }
                output += try input.take(count)
            } else {
                let count: Int, distance: Int
                switch tag & 3 {
                case 1:
                    count = 4 + Int((tag >> 2) & 7)
                    distance = Int(tag & 224) << 3 | Int(try input.take(1)[0])
                case 2:
                    count = 1 + Int(tag >> 2)
                    distance = Int(fixed(try input.take(2)[...]))
                default:
                    count = 1 + Int(tag >> 2)
                    distance = Int(fixed(try input.take(4)[...]))
                }
                guard distance > 0, distance <= output.count, count <= length - output.count else { throw ReadError.invalid }
                for _ in 0..<count { output.append(output[output.count - distance]) }
            }
        }
        guard output.count == length else { throw ReadError.invalid }
        return output
    }

    private static func block(_ table: [UInt8], handle: [UInt8]) throws -> [UInt8] {
        var pointer = Bytes(data: handle)
        let offset = try pointer.integer(), size = try pointer.integer()
        guard table.count >= 5, offset <= table.count - 5, size <= table.count - offset - 5 else { throw ReadError.invalid }
        let body = Array(table[offset..<offset + size])
        let type = table[offset + size]
        guard checksum(body + [type]) == UInt32(fixed(table[offset + size + 1..<offset + size + 5])) else { throw ReadError.invalid }
        switch type {
        case 0: return body
        case 1: return try decodeSnappy(body)
        default: throw ReadError.invalid
        }
    }
    private static func entries(_ bytes: [UInt8], visit: ([UInt8], [UInt8]) throws -> Void) throws {
        guard bytes.count >= 4 else { throw ReadError.invalid }
        let count = Int(fixed(bytes[(bytes.count - 4)...]))
        guard count <= (bytes.count - 4) / 4 else { throw ReadError.invalid }
        let end = bytes.count - 4 * (count + 1)
        var input = Bytes(data: Array(bytes[..<end])), previous: [UInt8] = []
        while input.position < end {
            let shared = try input.integer(), suffix = try input.integer(), size = try input.integer()
            guard shared <= previous.count else { throw ReadError.invalid }
            let key = Array(previous.prefix(shared)) + (try input.take(suffix))
            let value = try input.take(size)
            try visit(key, value); previous = key
        }
    }
    private struct Manifest {
        var tables = Set<UInt64>()
        var log: UInt64 = 0
        var previousLog: UInt64 = 0
    }
    private static func manifest(_ bytes: [UInt8]) throws -> Manifest {
        var state = Manifest()
        for record in try records(bytes, trailingAllowed: false) {
            var input = Bytes(data: record)
            while input.position < record.count {
                switch try input.varint() {
                case 1: _ = try input.string() // comparator
                case 2: state.log = try input.varint()
                case 3, 4: _ = try input.varint() // next file, last sequence
                case 5: _ = try input.varint(); _ = try input.string() // compaction pointer
                case 6:
                    _ = try input.varint(); state.tables.remove(try input.varint())
                case 7:
                    _ = try input.varint(); state.tables.insert(try input.varint())
                    _ = try input.varint(); _ = try input.string(); _ = try input.string()
                case 9: state.previousLog = try input.varint()
                default: throw ReadError.invalid
                }
            }
        }
        return state
    }

    static func value(for userKey: Data, at directory: URL) throws -> Data? {
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ReadError.invalid }
        let currentURL = directory.appendingPathComponent("CURRENT")
        let current = try readFile(currentURL)
        guard let name = String(bytes: current, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("MANIFEST-"), name.dropFirst(9).allSatisfy(\.isNumber), name.count > 9 else { throw ReadError.invalid }
        let manifestURL = directory.appendingPathComponent(name)
        let manifestBytes = try readFile(manifestURL)
        let state = try manifest(manifestBytes)
        guard state.tables.count <= 128 else { throw ReadError.limit }
        var latest: (sequence: UInt64, value: Data?)?
        let target = Array(userKey)
        func apply(_ sequence: UInt64, _ value: [UInt8]?) {
            if latest == nil || sequence > latest!.sequence { latest = (sequence, value.map { Data($0) }) }
        }
        var total = 0
        for number in state.tables.sorted() {
            let filename = String(format: "%06llu.ldb", number)
            var url = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) { url = directory.appendingPathComponent(String(format: "%06llu.sst", number)) }
            let table = try readFile(url); total += table.count
            guard total <= 128 * 1024 * 1024, table.count >= 48,
                  fixed(table[(table.count - 8)...]) == 0xdb4775248b80fb57 else { throw ReadError.invalid }
            var footer = Bytes(data: Array(table[(table.count - 48)..<(table.count - 8)]))
            _ = try footer.varint(); _ = try footer.varint()
            let index = try block(table, handle: Array(footer.data[footer.position...]))
            try entries(index) { _, handle in
                try entries(block(table, handle: handle)) { key, value in
                    guard key.count >= 8, Array(key.dropLast(8)) == target else { return }
                    let internalKey = fixed(key.suffix(8))
                    let type = internalKey & 255
                    guard type <= 1 else { throw ReadError.invalid }
                    apply(internalKey >> 8, type == 0 ? nil : value)
                }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let logs = files.filter {
            guard $0.pathExtension == "log", let number = UInt64($0.deletingPathExtension().lastPathComponent) else { return false }
            return (state.log > 0 && number >= state.log) || (state.previousLog > 0 && number == state.previousLog)
        }
        guard logs.count <= 16 else { throw ReadError.limit }
        for url in logs {
            let bytes = try readFile(url); total += bytes.count
            guard total <= 128 * 1024 * 1024 else { throw ReadError.limit }
            for record in try records(bytes, trailingAllowed: true) {
                var input = Bytes(data: record)
                let sequence = fixed(try input.take(8)[...])
                let count = Int(fixed(try input.take(4)[...]))
                guard count <= maximumSize, sequence <= UInt64.max - UInt64(count) else { throw ReadError.invalid }
                var changes: [(UInt64, [UInt8]?)] = []
                for index in 0..<count {
                    let type = try input.take(1)[0]
                    guard type <= 1 else { throw ReadError.invalid }
                    let key = try input.string(), value = type == 1 ? try input.string() : nil
                    if key == target { changes.append((sequence + UInt64(index), value)) }
                }
                guard input.position == record.count else { throw ReadError.invalid }
                for change in changes { apply(change.0, change.1) }
            }
        }
        // A compaction or MANIFEST append during the read invalidates this snapshot.
        guard current == (try readFile(currentURL)), manifestBytes == (try readFile(manifestURL)) else { throw ReadError.changed }
        return latest?.value
    }
}
