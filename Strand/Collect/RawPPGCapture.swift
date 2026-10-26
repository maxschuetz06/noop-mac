import Foundation
import Compression
import os
import WhoopProtocol

// MARK: - Raw PPG night capture (SpO₂ research)
//
// WHOOP 5.0 SpO₂ is not decoded yet. The most promising raw source are the historical record layouts
// v20/v21 (PPG channel blocks) and v26 (multiplexed PPG). They are parsed for display but never
// persisted (v20/v21 end up as "rejected" frames in a 5 MB-capped archive, v26 is skipped by design), so
// full nights are lost. This opt-in capturer (default OFF, `RawPPGCapture.enabledKey`) appends the raw
// frames of those layouts — and of any other layout the decoder rejects — to a compact binary file per
// local day under `<external data folder>/raw-ppg/` for offline reverse-engineering. Builds without an
// external data folder (`ExternalDataFolder`) never capture.
//
// SAFETY CONTRACT: this is strictly best-effort and must never influence the sync. `submit…` is
// synchronous, non-throwing and only enqueues (a bounded `AsyncStream` yield; records beyond the queue
// capacity are dropped and counted); all file I/O happens on a serial actor; every error is logged and
// swallowed. It is deliberately NOT part of the rejected-sink's success/failure result, so it can
// neither block nor delay a trim ack.

// MARK: Binary format

/// On-disk record format: repeated `[u32 LE unix][u16 LE len][len bytes]`. `unix` is the record's own
/// timestamp when plausible, otherwise the capture time. Compressed days are plain multi-member gzip.
enum RawPPGFormat {
    struct Record: Equatable {
        var unix: UInt32
        var frame: [UInt8]
    }

    /// Header bytes per record (u32 unix + u16 length).
    static let headerSize = 6
    /// Largest frame the u16 length can describe.
    static let maxFrameLength = Int(UInt16.max)

    /// Encode one record; nil when the frame is empty or too long for the u16 length field.
    static func encode(unix: UInt32, frame: [UInt8]) -> Data? {
        guard !frame.isEmpty, frame.count <= maxFrameLength else { return nil }
        var d = Data(capacity: headerSize + frame.count)
        withUnsafeBytes(of: unix.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(frame.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: frame)
        return d
    }

    /// Decode every complete record; a torn tail (e.g. a crash mid-write) is ignored and reported.
    static func decode(_ data: Data) -> (records: [Record], truncatedTail: Bool) {
        let b = [UInt8](data)
        var records: [Record] = []
        var i = 0
        while i + headerSize <= b.count {
            let unix = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            let len = Int(b[i + 4]) | Int(b[i + 5]) << 8
            guard i + headerSize + len <= b.count else { return (records, true) }
            records.append(Record(unix: unix, frame: Array(b[(i + headerSize)..<(i + headerSize + len)])))
            i += headerSize + len
        }
        return (records, i != b.count)
    }

    // MARK: gzip (multi-member)

    /// Uncompressed bytes per gzip member — bounds memory while compressing a ~100 MB night.
    static let gzipChunkSize = 4 * 1024 * 1024

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// One gzip member: header (with an `RZ` FEXTRA subfield carrying the DEFLATE length, so our own reader
    /// can split members — standard readers ignore it) + raw DEFLATE (Apple's `.zlib` is headerless
    /// RFC 1951) + CRC32 + ISIZE.
    static func gzipMember(_ chunk: Data) throws -> Data {
        let deflated = try (chunk as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0x00, 0xff])
        out.append(contentsOf: [0x08, 0x00, UInt8(ascii: "R"), UInt8(ascii: "Z"), 0x04, 0x00])
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: deflated.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(deflated)
        withUnsafeBytes(of: crc32(chunk).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: chunk.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    struct GzipError: Error { let message: String }

    /// Decompress a (multi-member) gzip stream produced by `gzipMember`. Used by tests and any in-app
    /// reader; Python's `gzip` handles the same files natively.
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        var out = Data()
        var pos = 0
        while pos < b.count {
            // 10 header + 2 XLEN + 6 subfield header... = 20 bytes before the DEFLATE data, 8 trailer bytes.
            guard b.count - pos >= 28, b[pos] == 0x1f, b[pos + 1] == 0x8b, b[pos + 2] == 8, b[pos + 3] == 4,
                  b[pos + 10] == 8, b[pos + 11] == 0, b[pos + 12] == UInt8(ascii: "R"), b[pos + 13] == UInt8(ascii: "Z") else {
                throw GzipError(message: "bad gzip member header at \(pos)")
            }
            let clen = Int(b[pos + 16]) | Int(b[pos + 17]) << 8 | Int(b[pos + 18]) << 16 | Int(b[pos + 19]) << 24
            let start = pos + 20
            guard start + clen + 8 <= b.count else { throw GzipError(message: "truncated gzip member") }
            let inflated = try inflateRaw(Array(b[start..<(start + clen)]))
            let t = start + clen
            let crc = UInt32(b[t]) | UInt32(b[t + 1]) << 8 | UInt32(b[t + 2]) << 16 | UInt32(b[t + 3]) << 24
            guard crc == crc32(inflated) else { throw GzipError(message: "gzip CRC mismatch") }
            pos = t + 8
            out.append(inflated)
        }
        return out
    }

    /// Inflate one raw DEFLATE stream.
    private static func inflateRaw(_ src: [UInt8]) throws -> Data {
        let dstSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw GzipError(message: "compression_stream_init failed")
        }
        defer { compression_stream_destroy(streamPtr) }
        var out = Data()
        try src.withUnsafeBufferPointer { sp in
            guard let base = sp.baseAddress else { return }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = sp.count
            streamPtr.pointee.dst_ptr = dst
            streamPtr.pointee.dst_size = dstSize
            while true {
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = dstSize - streamPtr.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = dstSize
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw GzipError(message: "inflate error") }
            }
        }
        return out
    }
}

// MARK: Pure policy

enum RawPPGPolicy {
    /// Layouts always captured (WHOOP 5/MG PPG sources). Other layouts arrive via the rejected path.
    static let streamVersions: Set<Int> = [20, 21, 26]

    /// Type-47 (HISTORICAL_DATA) record `hist_version` byte, nil for any other frame.
    /// Type @4 / version @5 on WHOOP 4.0; @8 / @9 on WHOOP 5/MG (the puffin envelope is 4 bytes longer).
    static func historicalVersion(_ frame: [UInt8], family: DeviceFamily) -> Int? {
        let typeIndex = family == .whoop5 ? 8 : 4
        let versionIndex = typeIndex + 1
        guard frame.count > versionIndex, frame[typeIndex] == 47 else { return nil }
        return Int(frame[versionIndex])
    }

    /// True for historical frames of a layout the stream hook captures (v20/v21/v26).
    static func isStreamCaptured(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        guard let v = historicalVersion(frame, family: family) else { return false }
        return streamVersions.contains(v)
    }

    /// The record's own unix seconds (`unix` u32 LE @15 on 5/MG, @11 on 4.0), nil if the frame is too short.
    static func recordUnix(_ frame: [UInt8], family: DeviceFamily) -> UInt32? {
        let o = family == .whoop5 ? 15 : 11
        guard frame.count >= o + 4 else { return nil }
        return UInt32(frame[o]) | UInt32(frame[o + 1]) << 8 | UInt32(frame[o + 2]) << 16 | UInt32(frame[o + 3]) << 24
    }

    /// `YYYY-MM-DD` of `date` in `timeZone` (the file name of that local day).
    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYY-MM-DD` shifted by `days` (negative = earlier), same time zone.
    static func shiftedDay(_ date: Date, days: Int, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let shifted = cal.date(byAdding: .day, value: days, to: date) ?? date
        return dayString(shifted, timeZone: timeZone)
    }

    /// `YYYY-MM-DD` out of a file name `YYYY-MM-DD.bin` / `YYYY-MM-DD.bin.gz`; nil for anything else.
    static func day(fromFileName name: String) -> String? {
        guard name.hasSuffix(".bin") || name.hasSuffix(".bin.gz"), name.count >= 10 else { return nil }
        let d = String(name.prefix(10))
        let parts = d.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return d
    }

    struct FileEntry: Equatable {
        var name: String
        var size: Int64
        var modified: Date = .distantPast
    }

    static let retentionDays = 30
    static let retentionMaxBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// A file written this recently is never deleted, even when its day is already older than the
    /// retention window (a backlog night captured just now must survive the next maintenance run).
    static let recentWriteProtection: TimeInterval = 24 * 60 * 60

    /// Retention plan (pure): names to delete. (1) every file whose day is older than `today − maxAgeDays`;
    /// (2) then, while the total exceeds `maxBytes`, the oldest days first — but never the newest day, so
    /// the capture in progress survives even when one night alone exceeds the cap. Files written within
    /// `recentWriteProtection` are never deleted (they still count towards the total). Files whose names
    /// are not `YYYY-MM-DD.bin[.gz]` are never touched.
    static func retentionDeletions(entries: [FileEntry], today: Date, timeZone: TimeZone,
                                   maxAgeDays: Int = retentionDays,
                                   maxBytes: Int64 = retentionMaxBytes) -> [String] {
        let cutoff = shiftedDay(today, days: -maxAgeDays, timeZone: timeZone)
        let dated: [(entry: FileEntry, day: String)] = entries.compactMap { e in
            day(fromFileName: e.name).map { (e, $0) }
        }
        let isRecent = { (e: FileEntry) in today.timeIntervalSince(e.modified) < recentWriteProtection }
        var doomed = Set(dated.filter { $0.day < cutoff && !isRecent($0.entry) }.map(\.entry.name))
        let survivors = dated.filter { !doomed.contains($0.entry.name) }
            .sorted { ($0.day, $0.entry.name) < ($1.day, $1.entry.name) }
        var total = survivors.reduce(Int64(0)) { $0 + $1.entry.size }
        let newestDay = survivors.last?.day
        for candidate in survivors where total > maxBytes && candidate.day != newestDay && !isRecent(candidate.entry) {
            doomed.insert(candidate.entry.name)
            total -= candidate.entry.size
        }
        return doomed.sorted()
    }
}

// MARK: Capturer

/// Serial, off-main writer. All public entry points are non-throwing; failures are logged and dropped.
actor RawPPGCapture {
    /// UserDefaults / `@AppStorage` key of the opt-in toggle (default OFF).
    nonisolated static let enabledKey = "noop.rawPPGCapture"

    /// Writes into the external data folder; a build without one never captures.
    nonisolated static let shared = RawPPGCapture(directory: ExternalDataFolder.current?.rawPPGDirectory)

    struct Limits: Sendable {
        /// A day stays uncompressed until it is more than this many days old (a morning sync delivers
        /// last night, so yesterday is still "active").
        var graceDays = 1
        var retentionDays = RawPPGPolicy.retentionDays
        var retentionMaxBytes = RawPPGPolicy.retentionMaxBytes
        /// Records waiting for the writer. Beyond this, new records are dropped (and counted) instead of
        /// growing memory without bound when the disk is slower than the strap.
        var queueCapacity = 20_000
    }

    private enum Item: Sendable {
        case record(unix: UInt32?, frame: [UInt8], family: DeviceFamily)
        case flush(CheckedContinuation<Bool, Never>)
    }

    /// nil = no external data folder: every entry point is a no-op and nothing is created.
    nonisolated let directory: URL?
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool
    private let limits: Limits
    private nonisolated let logger = Logger(subsystem: "com.noopapp.noop", category: "RawPPGCapture")
    private nonisolated let continuation: AsyncStream<Item>.Continuation
    private nonisolated let dropped = OSAllocatedUnfairLock(initialState: 0)
    private var consumer: Task<Void, Never>?

    private var handle: FileHandle?
    private var activeDay: String?
    private var lastMaintenanceDay: String?
    private var lastErrorLog: Date = .distantPast

    init(directory: URL?,
         timeZone: TimeZone = .current,
         now: @escaping @Sendable () -> Date = { Date() },
         isEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: RawPPGCapture.enabledKey) },
         limits: Limits = Limits()) {
        self.directory = directory
        self.timeZone = timeZone
        self.now = now
        self.isEnabled = isEnabled
        self.limits = limits
        var cont: AsyncStream<Item>.Continuation!
        let stream = AsyncStream<Item>(bufferingPolicy: .bufferingOldest(max(1, limits.queueCapacity))) { cont = $0 }
        self.continuation = cont
        self.consumer = Task.detached(priority: .utility) { [weak self] in
            for await item in stream {
                guard let self else { break }
                await self.process(item)
            }
        }
    }

    deinit {
        continuation.finish()
        try? handle?.close()
    }

    /// Records dropped because the queue was full (since launch).
    nonisolated var droppedRecordCount: Int { dropped.withLock { $0 } }

    // MARK: Fire-and-forget entry points (callable from any thread / actor, never block, never throw)

    /// Stream hook: every historical frame as it arrives, BEFORE the Backfiller sees it. Captures only
    /// layouts v20/v21/v26. Cheap pre-filter (two byte reads) so the hot path stays hot.
    nonisolated func submitStreamFrame(_ frame: [UInt8], family: DeviceFamily) {
        guard directory != nil, RawPPGPolicy.isStreamCaptured(frame, family: family), isEnabled() else { return }
        enqueue(.record(unix: RawPPGPolicy.recordUnix(frame, family: family), frame: frame, family: family))
    }

    /// Rejected hook: frames the decoder could not map. Layouts already taken by the stream hook are
    /// skipped so nothing is captured twice.
    nonisolated func submitRejected(_ frames: [[UInt8]], family: DeviceFamily) {
        guard directory != nil, !frames.isEmpty, isEnabled() else { return }
        for f in frames where !RawPPGPolicy.isStreamCaptured(f, family: family) {
            enqueue(.record(unix: RawPPGPolicy.recordUnix(f, family: family), frame: f, family: family))
        }
    }

    private nonisolated func enqueue(_ item: Item) {
        guard case .dropped = continuation.yield(item) else { return }
        let count = dropped.withLock { total -> Int in
            total += 1
            return total
        }
        if count == 1 || count.isMultiple(of: 1_000) {
            logger.error("raw PPG capture queue full; \(count, privacy: .public) records dropped so far")
        }
    }

    /// Wait until everything submitted so far has been written (tests, shutdown). Retries while the queue
    /// is full, so it never returns before the records queued ahead of it.
    func flush() async {
        while true {
            let done = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                switch continuation.yield(.flush(c)) {
                case .enqueued: break
                case .dropped: c.resume(returning: false)
                case .terminated: c.resume(returning: true)
                @unknown default: c.resume(returning: true)
                }
            }
            if done { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Close the open file handle (the next record reopens it).
    func close() {
        try? handle?.close()
        handle = nil
        activeDay = nil
    }

    // MARK: Processing (actor-isolated)

    private func process(_ item: Item) {
        switch item {
        case .flush(let c):
            c.resume(returning: true)
        case .record(let unix, let frame, _):
            append(unix: unix, frame: frame)
        }
    }

    /// Directly append one record (used by tests; the stream path goes through `process`).
    func append(unix: UInt32?, frame: [UInt8]) {
        guard let directory else { return }
        do { try write(unix: unix, frame: frame, into: directory) } catch { report(error) }
    }

    private func write(unix: UInt32?, frame: [UInt8], into directory: URL) throws {
        let wall = now()
        let wallUnix = Int(wall.timeIntervalSince1970)
        // Prefer the record's own time (it names the night the data belongs to); a bad-clock strap emits
        // garbage, in which case fall back to the capture time.
        let recordUnix: Int
        if let unix, isPlausibleHistoricalUnix(Int(unix), wallNow: wallUnix) {
            recordUnix = Int(unix)
        } else {
            recordUnix = wallUnix
        }
        guard let encoded = RawPPGFormat.encode(unix: UInt32(truncatingIfNeeded: recordUnix), frame: frame) else { return }
        let day = RawPPGPolicy.dayString(Date(timeIntervalSince1970: TimeInterval(recordUnix)), timeZone: timeZone)
        let switching = activeDay != day || handle == nil
        if switching {
            // Close first so a finished day is not "active" and can be compressed by the maintenance below.
            try? handle?.close()
            handle = nil
            activeDay = nil
        }
        let today = RawPPGPolicy.dayString(wall, timeZone: timeZone)
        if switching || lastMaintenanceDay != today {
            lastMaintenanceDay = today
            runMaintenance(in: directory, keeping: day)
        }
        if switching {
            try PrivateFiles.ensureDirectory(directory)
            let url = directory.appendingPathComponent("\(day).bin")
            // A `.bin` next to the day's `.gz` is a segment from an earlier run (possibly one that crashed
            // after publishing it). Fold it in first so the new segment is never merged with it.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(day).bin.gz").path),
               FileManager.default.fileExists(atPath: url.path) {
                do { try RawPPGDayArchive.compress(name: url.lastPathComponent, day: day, in: directory) } catch { report(error) }
            }
            try PrivateFiles.createEmptyFile(at: url)
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
            activeDay = day
        }
        try handle?.write(contentsOf: encoded)
    }

    /// Compress finished days, then apply retention. Never throws: maintenance must not stop capturing.
    /// `upcomingDay` (about to be written) and the open day are never compressed or deleted.
    private func runMaintenance(in directory: URL, keeping upcomingDay: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let wall = now()
        let compressBefore = RawPPGPolicy.shiftedDay(wall, days: -limits.graceDays, timeZone: timeZone)
        let openDays = Set([activeDay, upcomingDay].compactMap { $0 })
        for name in names {
            if name.hasSuffix(".tmp") { try? fm.removeItem(at: directory.appendingPathComponent(name)); continue }
            guard name.hasSuffix(".bin"), let day = RawPPGPolicy.day(fromFileName: name),
                  day < compressBefore, !openDays.contains(day) else { continue }
            do { try RawPPGDayArchive.compress(name: name, day: day, in: directory) } catch { report(error) }
        }
        let deletions = RawPPGPolicy.retentionDeletions(entries: RawPPGDayArchive.entries(in: directory),
                                                        today: wall, timeZone: timeZone,
                                                        maxAgeDays: limits.retentionDays,
                                                        maxBytes: limits.retentionMaxBytes)
        for name in deletions {
            if let day = RawPPGPolicy.day(fromFileName: name), openDays.contains(day) { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Log and swallow, at most once a minute so a full disk can't flood the log.
    private func report(_ error: Error) {
        let t = now()
        guard t.timeIntervalSince(lastErrorLog) > 60 else { return }
        lastErrorLog = t
        logger.error("raw PPG capture error (swallowed): \(String(describing: error), privacy: .public)")
    }
}
