#if !canImport(Darwin)
import Foundation

extension String {
    /// Stands in for Foundation's localized initializer, which exists only on
    /// Apple's platforms.
    ///
    /// Every error message in this project is written as
    /// `String(localized: "…")`, which on a Mac looks the English text up in
    /// the bundle's `.lproj` tables and returns Spanish when that is the
    /// reader's language. There is no bundle and no table off Apple, so this
    /// returns the English the call site already contains — interpolated
    /// values included, because the argument is an ordinary string by the
    /// time it arrives here.
    ///
    /// So the engine speaks English on Linux, Windows and Android, and that
    /// is a real limitation rather than a tidy equivalence. The fix is not to
    /// reimplement string tables here: the interface translates from the
    /// `VoxScriptaError` case, which carries the facts, rather than from a
    /// sentence the engine already rendered.
    ///
    /// That is now built, rather than only recommended. ``VoxScriptaError``
    /// has `code` and `details`, and the FFI exposes them through
    /// `vs_last_error_json_copy` and `vs_job_error_json_copy` — see
    /// `Diagnostics/ErrorCode.swift`. Note why translating here could not
    /// have worked: by the time this shim is reached the interpolations have
    /// already been substituted, so "the file at /a.wav changed" can no
    /// longer be looked up in a table keyed on "the file at %@ changed".
    /// The key is gone before this function sees the string.
    public init(localized value: String) {
        self = value
    }
}
#endif
