import Foundation

/// Filesystem locations Spartan persists to.
public enum SpartanPaths {
    /// `~/Library/Application Support/Spartan/<sub>`, created on demand.
    public static func dir(_ sub: String? = nil) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        var url = support.appendingPathComponent("Spartan", isDirectory: true)
        if let sub { url = url.appendingPathComponent(sub, isDirectory: true) }
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }
}
