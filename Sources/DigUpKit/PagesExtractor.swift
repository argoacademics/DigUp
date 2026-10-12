import Compression
import Foundation

/// The text of a Pages document (Pages 5 and later), read straight from the file: no Pages app, nothing launched.
///
/// A .pages file is a zip (or, saved as a package, a folder) of `Index/*.iwa` files. Each .iwa is a run of
/// Snappy-compressed chunks holding protobuf objects, every one tagged with its type. The text lives in
/// `TSWP.StorageArchive` objects (body, text boxes, headers, footnotes) and table cells in `TST.TableDataList` string
/// lists; everything else (styles, layout, images) is skipped.
enum PagesExtractor {
    /// TSWP.StorageArchive: `repeated string text = 3`.
    static let storageTypes: Set<UInt64> = [2001, 2005]
    /// TST.TableDataList: `repeated ListEntry entries = 3`, each with `optional string string = 3`.
    static let tableStringsType: UInt64 = 6005

    static func text(of url: URL) throws -> String {
        var pieces: [String] = []
        for (name, data) in try iwaFiles(of: url) where !name.contains("Stylesheet") {
            // One unreadable part shouldn't lose the rest of the document.
            guard let objects = try? IWA.unframe(data) else { continue }
            pieces += (try? strings(in: objects)) ?? []
        }
        let text = clean(pieces.joined(separator: "\n\n"))
        guard !text.isEmpty else { throw ExtractError.empty("no text") }
        return text
    }

    /// The .iwa parts, Document.iwa first (the body), as (name, bytes).
    static func iwaFiles(of url: URL) throws -> [(String, Data)] {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        var files: [(String, Data)]
        if isFolder.boolValue {
            let index = url.appendingPathComponent("Index")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: index.path)) ?? []
            files = try names.filter { $0.hasSuffix(".iwa") }.map {
                ("Index/" + $0, try Data(contentsOf: index.appendingPathComponent($0)))
            }
            if files.isEmpty, let inner = try? Data(contentsOf: url.appendingPathComponent("Index.zip")) {
                files = try Zip.entries(of: inner) { $0.hasSuffix(".iwa") }
            }
        } else {
            let data = try Data(contentsOf: url)
            guard data.starts(with: [0x50, 0x4B]) else {
                throw ExtractError.unreadable("not a Pages 5+ document")   // Pages '09 and older
            }
            files = try Zip.entries(of: data) { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }
        }
        guard !files.isEmpty else { throw ExtractError.unreadable("no document inside") }
        func rank(_ name: String) -> (Int, String) { (name == "Index/Document.iwa" ? 0 : 1, name) }
        return files.sorted { rank($0.0) < rank($1.0) }
    }

    /// The text of every storage and table string list in one decompressed .iwa, in file order.
    static func strings(in data: Data) throws -> [String] {
        var found: [String] = []
        for (type, payload) in try IWA.objects(in: data) {
            if storageTypes.contains(type) {
                for field in Protobuf.fields(payload) where field.number == 3 {
                    if let text = field.string, !text.isEmpty { found.append(text) }
                }
            } else if type == tableStringsType {
                let cells = Protobuf.fields(payload).filter { $0.number == 3 }.compactMap { entry in
                    entry.bytes.flatMap { Protobuf.fields($0).first { $0.number == 3 }?.string }
                }
                if !cells.isEmpty { found.append(cells.joined(separator: "\n")) }
            }
        }
        return found
    }

    /// Pages marks attachments, breaks and footnotes with control characters inside the text.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFFFC: continue                          // an inline object (image, shape, footnote anchor)
            case 0x2028, 0x2029: scalars.append("\n")       // line and paragraph separators
            case 0x09, 0x0A: scalars.append(scalar)
            case 0x00..<0x20: scalars.append("\n")          // page, section and column breaks
            default: scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// iWork Archive framing: chunks of [0x00, 24-bit little-endian length, raw Snappy data], and inside them objects of
/// [varint length, ArchiveInfo, payloads], where ArchiveInfo's MessageInfo list gives each payload's type and length.
enum IWA {
    static func unframe(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        var at = 0
        while at + 4 <= bytes.count {
            guard bytes[at] == 0 else { throw ExtractError.unreadable("bad iwa chunk") }
            let length = Int(bytes[at + 1]) | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) << 16
            at += 4
            guard at + length <= bytes.count else { throw ExtractError.unreadable("short iwa chunk") }
            out.append(try Snappy.decompress(bytes[at..<at + length]))
            at += length
        }
        return out
    }

    static func objects(in data: Data) throws -> [(type: UInt64, payload: Data)] {
        let bytes = [UInt8](data)
        var objects: [(UInt64, Data)] = []
        var at = 0
        while at < bytes.count {
            guard let length = Protobuf.varint(bytes, &at), at + Int(length) <= bytes.count else {
                throw ExtractError.unreadable("bad iwa object")
            }
            let info = Data(bytes[at..<at + Int(length)])
            at += Int(length)
            for message in Protobuf.fields(info) where message.number == 2 {
                guard let body = message.bytes else { continue }
                let fields = Protobuf.fields(body)
                let type = fields.first { $0.number == 1 }?.value ?? 0
                let size = Int(fields.first { $0.number == 3 }?.value ?? 0)
                guard at + size <= bytes.count else { throw ExtractError.unreadable("short iwa payload") }
                objects.append((type, Data(bytes[at..<at + size])))
                at += size
            }
        }
        return objects
    }
}

/// Raw Snappy (no stream framing or checksums), as iWork writes it.
enum Snappy {
    static func decompress(_ input: ArraySlice<UInt8>) throws -> Data {
        let src = Array(input)
        var at = 0
        guard let expected = Protobuf.varint(src, &at), expected < 1 << 28 else {
            throw ExtractError.unreadable("bad snappy header")
        }
        var out = [UInt8]()
        out.reserveCapacity(Int(expected))
        func need(_ count: Int) throws {
            guard at + count <= src.count else { throw ExtractError.unreadable("short snappy data") }
        }
        while at < src.count {
            let tag = src[at]
            at += 1
            let length: Int
            let offset: Int
            switch tag & 3 {
            case 0:   // a literal
                var literal = Int(tag >> 2)
                if literal >= 60 {
                    let width = literal - 59
                    try need(width)
                    literal = (0..<width).reduce(0) { $0 | Int(src[at + $1]) << (8 * $1) }
                    at += width
                }
                literal += 1
                try need(literal)
                out.append(contentsOf: src[at..<at + literal])
                at += literal
                continue
            case 1:
                try need(1)
                length = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(src[at])
                at += 1
            case 2:
                try need(2)
                length = Int(tag >> 2) + 1
                offset = Int(src[at]) | Int(src[at + 1]) << 8
                at += 2
            default:
                try need(4)
                length = Int(tag >> 2) + 1
                offset = (0..<4).reduce(0) { $0 | Int(src[at + $1]) << (8 * $1) }
                at += 4
            }
            guard offset > 0, offset <= out.count else { throw ExtractError.unreadable("bad snappy copy") }
            let start = out.count - offset
            for index in 0..<length { out.append(out[start + index]) }   // a copy may overlap what it writes
        }
        guard out.count == Int(expected) else { throw ExtractError.unreadable("snappy length mismatch") }
        return Data(out)
    }
}

/// Just enough protobuf to walk fields: no schema, numbers and wire types only.
enum Protobuf {
    struct Field {
        let number: UInt64
        let value: UInt64?   // varint and fixed fields
        let bytes: Data?     // length-delimited fields
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func varint(_ bytes: [UInt8], _ at: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while at < bytes.count, shift < 64 {
            let byte = bytes[at]
            at += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    /// The fields of one message; stops quietly at anything malformed.
    static func fields(_ data: Data) -> [Field] {
        let bytes = [UInt8](data)
        var fields: [Field] = []
        var at = 0
        while at < bytes.count, let key = varint(bytes, &at) {
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard let value = varint(bytes, &at) else { return fields }
                fields.append(Field(number: number, value: value, bytes: nil))
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard at + width <= bytes.count else { return fields }
                let value = (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
                at += width
                fields.append(Field(number: number, value: value, bytes: nil))
            case 2:
                guard let length = varint(bytes, &at), length <= UInt64(bytes.count - at) else { return fields }
                fields.append(Field(number: number, value: nil, bytes: Data(bytes[at..<at + Int(length)])))
                at += Int(length)
            default:
                return fields
            }
        }
        return fields
    }
}

/// Reads entries out of a zip in memory: stored or deflated, no zip64 (a Pages file's parts are small).
enum Zip {
    static func entries(of data: Data, where wanted: (String) -> Bool) throws -> [(String, Data)] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        // The end-of-central-directory record is in the last 64 KiB (after an optional comment).
        guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4B50 }) else { throw ExtractError.unreadable("not a zip") }
        let count = u16(end + 10)
        var at = u32(end + 16)
        var entries: [(String, Data)] = []
        for _ in 0..<count {
            guard at + 46 <= bytes.count, u32(at) == 0x0201_4B50 else {
                throw ExtractError.unreadable("bad zip directory")
            }
            let method = u16(at + 10)
            let packed = u32(at + 20)
            let size = u32(at + 24)
            let nameLength = u16(at + 28)
            let local = u32(at + 42)
            guard at + 46 + nameLength <= bytes.count else { throw ExtractError.unreadable("bad zip directory") }
            let name = String(decoding: bytes[at + 46..<at + 46 + nameLength], as: UTF8.self)
            at += 46 + nameLength + u16(at + 30) + u16(at + 32)
            guard wanted(name) else { continue }
            guard local + 30 <= bytes.count, u32(local) == 0x0403_4B50 else {
                throw ExtractError.unreadable("bad zip entry")
            }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + packed <= bytes.count else { throw ExtractError.unreadable("short zip entry") }
            let raw = Data(bytes[start..<start + packed])
            switch method {
            case 0: entries.append((name, raw))
            case 8: entries.append((name, try inflate(raw, size: size)))
            default: throw ExtractError.unreadable("zip method \(method)")
            }
        }
        return entries
    }

    /// Raw deflate (what zip stores), through the Compression framework's zlib decoder.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0, !data.isEmpty else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ExtractError.unreadable("bad deflate data") }
        return out
    }
}
