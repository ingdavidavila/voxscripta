/// Package-level constants.
public enum VoxScripta {
    /// Marketing version, and the single place it is written.
    ///
    /// `Provenance` stamps this into every transcript, so a stale value is not
    /// cosmetic: it misattributes work to a version that did not produce it.
    /// It read "0.1.0-phase0" through eight phases, a rename and the addition
    /// of Spanish, which is how it earned the comment above.
    ///
    /// Tools/make-app-bundle.sh reads this constant rather than repeating the
    /// number, and fails the build if it cannot parse it.
    public static let version = "0.3.0"

    /// On-disk project schema version. Bumped whenever the project package layout
    /// changes; `schemaTooNew` is raised when a project exceeds this.
    public static let projectSchemaVersion = 1
}
