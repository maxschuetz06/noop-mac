import Foundation

/// File operations on the raw-PPG day files (`YYYY-MM-DD.bin` / `YYYY-MM-DD.bin.gz`) used by the
/// `RawPPGCapture` maintenance run. Every file it creates is owner-only (0600).
enum RawPPGDayArchive {
    private static let copyChunkSize = 4 * 1024 * 1024

    /// Name, size and last write of every entry in `directory` (input of the retention plan).
    static func entries(in directory: URL) -> [RawPPGPolicy.FileEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.map { name in
            let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return RawPPGPolicy.FileEntry(name: name,
                                          size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                                          modified: attrs?[.modificationDate] as? Date ?? .distantPast)
        }
    }

    /// `day.bin` → gzip members appended to `day.bin.gz` (created if absent), then `day.bin` removed.
    ///
    /// Crash-safe and idempotent: the new `.gz` is built in a temporary file and published by `rename(2)`,
    /// and the `.bin` is removed only afterwards. If a previous run died between the rename and the removal,
    /// the published `.gz` already ends with exactly this segment's members (compression is deterministic),
    /// so the `.bin` is only removed and the day is never duplicated.
    static func compress(name: String, day: String, in directory: URL) throws {
        let fm = FileManager.default
        let src = directory.appendingPathComponent(name)
        let dst = directory.appendingPathComponent("\(day).bin.gz")
        let members = directory.appendingPathComponent("\(day).bin.members.tmp")
        let next = directory.appendingPathComponent("\(day).bin.gz.tmp")
        for stale in [members, next] { try? fm.removeItem(at: stale) }
        defer { for temp in [members, next] { try? fm.removeItem(at: temp) } }

        try writeGzipMembers(of: src, to: members)
        if fm.fileExists(atPath: dst.path), try file(dst, endsWithContentsOf: members) {
            try fm.removeItem(at: src)
            return
        }
        guard try PrivateFiles.createEmptyFile(at: next) else { throw CocoaError(.fileWriteFileExists) }
        let writer = try FileHandle(forWritingTo: next)
        defer { try? writer.close() }
        if fm.fileExists(atPath: dst.path) { try copy(dst, to: writer) }
        try copy(members, to: writer)
        try writer.synchronize()
        guard rename(next.path, dst.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: dst.path])
        }
        try fm.removeItem(at: src)
    }

    private static func writeGzipMembers(of src: URL, to target: URL) throws {
        guard try PrivateFiles.createEmptyFile(at: target) else { throw CocoaError(.fileWriteFileExists) }
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        while let chunk = try reader.read(upToCount: RawPPGFormat.gzipChunkSize), !chunk.isEmpty {
            try writer.write(contentsOf: try RawPPGFormat.gzipMember(chunk))
        }
    }

    private static func copy(_ src: URL, to writer: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        while let part = try reader.read(upToCount: copyChunkSize), !part.isEmpty {
            try writer.write(contentsOf: part)
        }
    }

    /// True when the last bytes of `url` equal the whole content of `suffix` (compared chunk by chunk).
    static func file(_ url: URL, endsWithContentsOf suffix: URL) throws -> Bool {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        let suffixHandle = try FileHandle(forReadingFrom: suffix)
        defer { try? suffixHandle.close() }
        let fileSize = try fileHandle.seekToEnd()
        let suffixSize = try suffixHandle.seekToEnd()
        guard suffixSize > 0, fileSize >= suffixSize else { return false }
        try fileHandle.seek(toOffset: fileSize - suffixSize)
        try suffixHandle.seek(toOffset: 0)
        while let expected = try suffixHandle.read(upToCount: copyChunkSize), !expected.isEmpty {
            guard try fileHandle.read(upToCount: expected.count) == expected else { return false }
        }
        return true
    }
}
