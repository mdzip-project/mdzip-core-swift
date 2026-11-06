import Foundation

/// Resource limits applied when reading an archive (Section 13.1).
///
/// Declared sizes are checked when the archive is opened. Because declared sizes can lie,
/// the bytes actually produced are checked again on every read: decompression stops as soon
/// as an entry passes its declared size, and an entry can never return more than that.
/// Exceeding a limit fails with `ERR_LIMIT_EXCEEDED`.
public struct MDZipLimits: Sendable, Equatable {
    /// The most entries an archive may list. Default 20,000.
    public var maxEntries: Int
    /// The most bytes one entry may expand to. Default 256 MiB.
    public var maxEntryBytes: UInt64
    /// The most bytes all entries together may expand to. Default 1 GiB.
    public var maxTotalBytes: UInt64
    /// The highest allowed ratio of uncompressed to compressed size. Default 1000.
    public var maxCompressionRatio: Int
    /// The ratio limit applies only to entries larger than this, since tiny entries can have
    /// large ratios harmlessly. Default 1 MiB.
    public var ratioAppliesAboveBytes: UInt64

    public init(maxEntries: Int = 20_000,
                maxEntryBytes: UInt64 = 256 << 20,
                maxTotalBytes: UInt64 = 1 << 30,
                maxCompressionRatio: Int = 1000,
                ratioAppliesAboveBytes: UInt64 = 1 << 20) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxCompressionRatio = maxCompressionRatio
        self.ratioAppliesAboveBytes = ratioAppliesAboveBytes
    }

    /// The defaults, which are no looser than the specification fixtures' reference limits.
    public static let `default` = MDZipLimits()
}
