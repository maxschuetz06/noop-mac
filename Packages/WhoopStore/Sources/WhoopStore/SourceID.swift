/// The fixed source ids rows are stored under (`deviceId` in every sample, metric and workout table).
/// They are persisted, so the values never change.
public enum SourceID {
    /// The WHOOP strap and the WHOOP export importer (the seeded device-registry row).
    public static let whoop = "my-whoop"
    /// Appended to a device id for the scores NOOP computes on device from that device's raw streams.
    public static let computedSuffix = "-noop"
    /// On-device scores computed from the WHOOP strap's raw streams.
    public static let whoopComputed = whoop + computedSuffix
    /// Apple Health imports.
    public static let appleHealth = "apple-health"
    /// Health Connect imports.
    public static let healthConnect = "health-connect"
}
