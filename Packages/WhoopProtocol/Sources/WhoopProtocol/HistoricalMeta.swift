import Foundation

/// Classification of a METADATA frame (packet type 49) for the historical-offload state machine.
public enum HistoricalMeta: Equatable {
    case start
    case end(unix: UInt32, trim: UInt32)
    case complete
    case other
}

/// Classify a parsed METADATA frame into the four cases the Backfiller needs.
///
/// Field mapping (verified against whoop_protocol.json + Schema.swift + PostHooks.swift):
/// - `p.parsed["meta_type"]` → `.string("HISTORY_START(1)"|"HISTORY_END(2)"|"HISTORY_COMPLETE(3)")`
///   Schema.enumName() appends "(rawValue)" to every enum lookup, so the strings have the form
///   "NAME(N)". We match by checking `hasPrefix` to be robust against raw-value changes.
///   (byte offset 6, u8, MetadataType enum, cat="meta" → stored in parsed dict by FieldBuilder)
/// - For HISTORY_END the metadata post-hook additionally stores in p.parsed:
///   `"unix"` → `.int(unix_seconds)` and `"trim_cursor"` → `.int(trim_value)`
public func classifyHistoricalMeta(_ p: ParsedFrame) -> HistoricalMeta {
    // Integrity gate: only act on a checksum-valid frame. CRC32 is the protocol's only integrity
    // check; without this a malicious/garbled BLE peer could forge HISTORY_END/HISTORY_COMPLETE
    // (advancing the trim cursor + acking the strap to discard data we never durably stored).
    guard p.ok, p.crcOK != false else { return .other }
    guard p.typeName == "METADATA" else { return .other }
    guard case .string(let metaName)? = p.parsed["meta_type"] else { return .other }
    // Schema.enumName() produces "NAME(rawValue)" — match by prefix so the classifier is
    // insulated from raw-value changes.
    if metaName.hasPrefix("HISTORY_START") {
        return .start
    } else if metaName.hasPrefix("HISTORY_COMPLETE") {
        return .complete
    } else if metaName.hasPrefix("HISTORY_END") {
        guard case .int(let unix)? = p.parsed["unix"],
              case .int(let trim)? = p.parsed["trim_cursor"]
        else { return .other }
        return .end(unix: UInt32(truncatingIfNeeded: unix), trim: UInt32(truncatingIfNeeded: trim))
    } else {
        return .other
    }
}

// MARK: - Cheap pre-filter

/// Packet-type bytes that `parseFrame(_:family:)` would name "METADATA", per family. Derived from the
/// schema + `canonicalTypeName` (never hard-coded) so the pre-filter can't drift from the parser:
/// WHOOP 4 uses the schema's own `PacketType` names (49); WHOOP 5 additionally aliases puffin
/// metadata (56) onto METADATA.
private let metadataTypeBytesWhoop4: Set<UInt8> = {
    let schema = loadSchema()
    return Set((0...255).filter { schema.typeName($0) == "METADATA" }.map { UInt8($0) })
}()

private let metadataTypeBytesWhoop5: Set<UInt8> = {
    let schema = loadSchema()
    return Set((0...255).filter { canonicalTypeName($0, schema: schema) == "METADATA" }.map { UInt8($0) })
}()

/// Cheap, allocation-free test: could `frame` possibly classify as anything other than `.other` in
/// `classifyHistoricalMeta(parseFrame(frame, family:))`?
///
/// `classifyHistoricalMeta` only ever returns `.start/.end/.complete` for a frame whose parsed
/// `typeName` is "METADATA", and `parseFrame` derives that name from a single packet-type byte (inner
/// record offset 4 on WHOOP 4, offset 8 on WHOOP 5) after a SOF + minimum-length check. So when this
/// returns `false` the full parse (and its CRC work + ~dozens of String allocations) can be skipped:
/// the frame is guaranteed to classify as `.other`. When it returns `true` the caller MUST still run
/// the full parse + `classifyHistoricalMeta` — the CRC integrity gate lives there, not here.
///
/// Conservative by construction: a `true` is only "maybe METADATA"; it never has a false negative.
public func quickHistoricalMetaCandidate(_ frame: [UInt8], family: DeviceFamily) -> Bool {
    switch family {
    case .whoop4:
        guard frame.count >= 8, frame[0] == 0xAA else { return false }
        return metadataTypeBytesWhoop4.contains(frame[4])
    case .whoop5:
        guard frame.count >= 12, frame[0] == 0xAA else { return false }
        return metadataTypeBytesWhoop5.contains(frame[8])
    }
}
