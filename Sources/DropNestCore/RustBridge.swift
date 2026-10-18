import Foundation
import DropNestRust

/// XLSX / PPTX text read by the Rust core in-process.
public enum OfficeText {
    /// Returns nil when the file is not a readable archive.
    public static func extract(_ url: URL, pptx: Bool, limit: Int) -> (text: String, truncated: Bool)? {
        var buffer = DnBuffer(data: nil, len: 0)
        var truncated: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return dn_office_text(path, pptx ? 1 : 0, max(0, limit), &buffer, &truncated)
        }
        defer { dn_buffer_free(buffer) }
        guard result == 0 else { return nil }
        let text = buffer.data.map { String(decoding: UnsafeBufferPointer(start: $0, count: buffer.len), as: UTF8.self) } ?? ""
        return (text, truncated != 0)
    }
}

enum RustDigest {
    /// Parallel SHA-256 of each file; nil entries could not be read or changed while reading.
    static func sha256(_ urls: [URL]) -> [Data?] {
        guard !urls.isEmpty else { return [] }
        let paths = urls.map { strdup(($0 as NSURL).fileSystemRepresentation) }
        defer { paths.forEach { free($0) } }
        var digests = [UInt8](repeating: 0, count: urls.count * 32)
        var results = [Int32](repeating: -1, count: urls.count)
        let status = paths.map { UnsafePointer($0) }.withUnsafeBufferPointer { pointers in
            dn_sha256_files(pointers.baseAddress, urls.count, &digests, &results)
        }
        guard status == 0 else { return Array(repeating: nil, count: urls.count) }
        return results.indices.map { index in
            results[index] == 0 ? Data(digests[index * 32..<(index + 1) * 32]) : nil
        }
    }
}

struct RustScanEntry {
    enum Kind: UInt8 { case folder = 0, file = 1, package = 2 }
    let kind: Kind
    let relativePath: String
    let size: Int64
    let modified: Date
}

enum RustScanner {
    private static let isPackage: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { path in
        guard let path else { return 0 }
        let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true ? 1 : 0
    }

    /// Matches `URL.resourceValues(.contentModificationDateKey)` bit for bit,
    /// so cached index text keyed on modification dates stays valid.
    static func date(seconds: Int64, nanoseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(seconds) - Date.timeIntervalBetween1970AndReferenceDate + 1.0e-9 * Double(nanoseconds))
    }

    static func scan(root: URL, maxEntries: Int, maxDepth: Int) throws -> (entries: [RustScanEntry], incomplete: Bool) {
        var buffer = DnBuffer(data: nil, len: 0)
        let status = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return dn_scan_library(path, maxEntries, maxDepth, isPackage, &buffer)
        }
        defer { dn_buffer_free(buffer) }
        guard status == 0, let base = buffer.data, buffer.len >= 1 else {
            throw ArchiveError.invalid("无法读取归档目录。")
        }
        let bytes = UnsafeRawBufferPointer(start: base, count: buffer.len)
        var offset = 1
        var entries: [RustScanEntry] = []
        func read<T: FixedWidthInteger>(_: T.Type) -> T {
            let value = T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
            offset += MemoryLayout<T>.size
            return value
        }
        while offset + 29 <= bytes.count {
            let kind = read(UInt8.self)
            let size = read(UInt64.self)
            let seconds = read(Int64.self)
            let nanoseconds = read(Int64.self)
            let length = Int(read(UInt32.self))
            guard offset + length <= bytes.count else { break }
            let path = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + length]), as: UTF8.self)
            offset += length
            guard let kind = RustScanEntry.Kind(rawValue: kind) else { continue }
            entries.append(RustScanEntry(kind: kind, relativePath: path, size: Int64(clamping: size),
                                         modified: date(seconds: seconds, nanoseconds: nanoseconds)))
        }
        return (entries, bytes[0] != 0)
    }
}
