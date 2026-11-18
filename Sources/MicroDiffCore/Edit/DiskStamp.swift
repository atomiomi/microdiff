import Foundation

/// Identifies one on-disk version of a file. Equal stamps mean "same file, same content" for our purposes.
package struct DiskStamp: Sendable, Equatable {
    package var size: Int64
    package var modifiedNanos: Int64
    package var inode: UInt64

    package init(size: Int64, modifiedNanos: Int64, inode: UInt64) {
        self.size = size
        self.modifiedNanos = modifiedNanos
        self.inode = inode
    }

    init(_ info: stat) {
        self.init(
            size: Int64(info.st_size),
            modifiedNanos: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }
}

/// What a path looks like on disk right now.
package enum DiskObservation: Sendable, Equatable {
    case missing
    case present(DiskStamp)

    /// Follows symlinks. Nil when the state cannot be told (for example no permission on the folder).
    package static func observe(_ path: String) -> DiskObservation? {
        var info = stat()
        if stat(path, &info) == 0 { return .present(DiskStamp(info)) }
        return errno == ENOENT || errno == ENOTDIR ? .missing : nil
    }
}
