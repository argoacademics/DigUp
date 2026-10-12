import Foundation
import Testing
@testable import DigUpKit

/// Pages documents, built here byte by byte the way Pages writes them: a stored zip of Snappy-framed .iwa files.
@Suite struct PagesTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func readsBodyTextBoxesAndTables() throws {
        let body = storage("Lease for 12 Elm St\u{2029}Pets are allowed with\u{FFFC} written consent.\u{000C}Page two")
        let box = storage("A text box: rent is due on the 1st.")
        let table = object(type: 6005, fields(1, varint: 1)
            + fields(3, bytes: fields(1, varint: 1) + fields(3, string: "Bond"))
            + fields(3, bytes: fields(1, varint: 2) + fields(3, string: "$2,400")))
        let style = storage("Lorem ipsum from a style sample")
        let file = folder.appendingPathComponent("Lease.pages")
        try zip([("Index/Document.iwa", frame(body + table)), ("Index/Shapes.iwa", frame(box)),
                 ("Index/DocumentStylesheet.iwa", frame(style)), ("preview.jpg", Data([0xFF, 0xD8]))]).write(to: file)

        let text = try DocExtractor.text(of: file)
        #expect(text.hasPrefix("Lease for 12 Elm St\nPets are allowed with written consent.\nPage two"))
        #expect(text.contains("Bond\n$2,400"))
        #expect(text.contains("rent is due on the 1st."))
        #expect(!text.contains("Lorem"))
    }

    @Test func snappyCopiesThatOverlap() throws {
        // "abc" as a literal, then 6 bytes copied from 3 back: the copy reads what it is writing.
        let compressed: [UInt8] = [9, 2 << 2, 0x61, 0x62, 0x63, (5 << 2) | 2, 3, 0]
        #expect(try Snappy.decompress(compressed[...]) == Data("abcabcabc".utf8))
    }

    @Test func pagesIsADocument() {
        let file = folder.appendingPathComponent("Essay.pages")
        #expect(Rules.classify(file, type: .init(filenameExtension: "pages"), options: IndexOptions()) == .index(.doc))
    }

    @Test func oldPagesFilesAreUnreadableNotFatal() throws {
        let file = folder.appendingPathComponent("Old.pages")
        try Data("<?xml version=\"1.0\"?>".utf8).write(to: file)
        #expect(throws: ExtractError.self) { try PagesExtractor.text(of: file) }
    }

    // MARK: Writing the format

    func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    func fields(_ number: UInt64, varint value: UInt64) -> Data { varint(number << 3) + varint(value) }
    func fields(_ number: UInt64, bytes: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    func fields(_ number: UInt64, string: String) -> Data { fields(number, bytes: Data(string.utf8)) }

    /// One object: [varint length, ArchiveInfo { identifier, MessageInfo { type, length } }, payload].
    func object(type: UInt64, _ payload: Data) -> Data {
        let message = fields(1, varint: type) + fields(3, varint: UInt64(payload.count))
        let info = fields(1, varint: 1) + fields(2, bytes: message)
        return varint(UInt64(info.count)) + info + payload
    }

    func storage(_ text: String) -> Data { object(type: 2001, fields(1, varint: 0) + fields(3, string: text)) }

    /// One chunk of literal-only Snappy: [0x00, 24-bit length, varint size, literal tag, bytes].
    func frame(_ data: Data) -> Data {
        var tag = Data()
        if data.count <= 60 {
            tag.append(UInt8(data.count - 1) << 2)
        } else {
            tag.append(61 << 2)   // a two-byte length follows
            tag.append(UInt8((data.count - 1) & 0xFF))
            tag.append(UInt8((data.count - 1) >> 8))
        }
        let snappy = varint(UInt64(data.count)) + tag + data
        return Data([0, UInt8(snappy.count & 0xFF), UInt8(snappy.count >> 8 & 0xFF), UInt8(snappy.count >> 16)]) + snappy
    }

    /// A zip with every entry stored, as Pages writes it.
    func zip(_ entries: [(String, Data)]) -> Data {
        func u16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func u32(_ value: Int) -> Data { u16(value & 0xFFFF) + u16(value >> 16) }
        var out = Data()
        var directory = Data()
        for (name, data) in entries {
            let offset = out.count
            let sizes = u32(0) + u32(data.count) + u32(data.count)   // crc (unchecked), packed, size
            out += u32(0x0403_4B50) + u16(20) + u16(0) + u16(0) + u32(0) + sizes + u16(name.utf8.count) + u16(0)
            out += Data(name.utf8) + data
            directory += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0) + u16(0) + u32(0) + sizes
            directory += u16(name.utf8.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset)
            directory += Data(name.utf8)
        }
        let start = out.count
        out += directory
        out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count) + u32(directory.count)
        out += u32(start) + u16(0)
        return out
    }
}
