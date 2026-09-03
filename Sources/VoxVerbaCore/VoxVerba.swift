/// Package-level constants.
public enum VoxVerba {
    /// Marketing version. Kept here so `Provenance` can record it without a bundle.
    public static let version = "0.1.0-phase0"

    /// On-disk project schema version. Bumped whenever the project package layout
    /// changes; `schemaTooNew` is raised when a project exceeds this.
    public static let projectSchemaVersion = 1
}
