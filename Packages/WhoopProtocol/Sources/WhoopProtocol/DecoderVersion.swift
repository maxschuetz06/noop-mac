/// Version of the historical-record decoder: `parseFrame` plus `extractHistoricalStreams` for WHOOP 4.0
/// type-47 and WHOOP 5/MG puffin history. Bump it in the same change that alters what any archived
/// frame decodes to (a new layout map, a fixed field offset, a changed timestamp gate). The app replays
/// its archive of undecodable frames through the decoder once per version, so a bump is what lets
/// already-acked history recover after a decoder fix. `DecoderVersionTests` fails when the decoded
/// output of its fixture corpus changes, as a reminder to bump.
public enum DecoderVersion {
    public static let current = 1
}
