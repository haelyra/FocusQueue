import Darwin
import Foundation

/// Generous ceilings for files Focus Queue reads whole. Each sits far above the
/// largest real file of its kind (measured November 2026), so ordinary work
/// never reaches one; they only stop runaway or hostile input. Existing limits
/// stay where they are: 10 MB project import, 20 MB preview metadata, 2 MB
/// preview text, 64 MiB library blob.
public enum FileReadLimits {
    /// Task context.json, cleanup manifests and reports, canvas sessions, and
    /// document chat stores. Largest real file: a 362 KiB context.json (~90x headroom).
    public static let metadataBytes = 32 * 1024 * 1024
    /// First load of a canvas artifact. Largest registered artifact: 244 KiB
    /// (~130x headroom); largest HTML file of any kind measured: 15 MB.
    public static let canvasArtifactBytes = 32 * 1024 * 1024
    /// Whole-document reads for in-place chat edits. Largest real Markdown: 730 KiB (~22x headroom).
    public static let editableDocumentBytes = 16 * 1024 * 1024
}

public enum SafeFileReadError: Error, LocalizedError, Equatable, Sendable {
    /// A named pipe, device, socket, or folder: opening or reading one can block or never end.
    case notRegularFile(String)
    /// More than `limit` bytes were actually read, whatever the size metadata said.
    case tooLarge(String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let path):
            "\(path) is not a regular file. Named pipes, devices, sockets, and folders are not read."
        case let .tooLarge(path, limit):
            "\(path) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) read limit."
        }
    }
}

/// Reads local files without blocking on special files and without trusting
/// size metadata. The path is classified before opening, so a device or pipe
/// is never opened; the open uses O_NONBLOCK, so a pipe swapped in afterwards
/// never waits for a writer; `fstat` on the descriptor must report a regular
/// file; and whole-file reads stop one byte past the limit, so a file that grows
/// during the read is still refused. Symlinks are followed unless the caller
/// opts out, so an intentional link works when its destination is a regular file.
public enum SafeFileRead {
    /// Every byte of a regular file holding at most `limit` bytes.
    public static func data(at url: URL, limit: Int, followSymlinks: Bool = true) throws -> Data {
        let file = try openRegularFile(url, followSymlinks: followSymlinks)
        defer { Darwin.close(file.descriptor) }
        return try readAll(file, limit: limit)
    }

    /// At most the first `count` bytes of a regular file; a longer file is not an error.
    public static func prefix(of url: URL, count: Int) throws -> Data {
        let file = try openRegularFile(url, followSymlinks: true)
        defer { Darwin.close(file.descriptor) }
        return try read(file, upTo: max(0, count))
    }

    /// Confirms a readable regular file no larger than `limit` without reading
    /// its content. Cheap and nonblocking, so the main thread may call it.
    @discardableResult
    public static func validateRegularFile(at url: URL, limit: Int? = nil) throws -> Int {
        let file = try openRegularFile(url, followSymlinks: true)
        Darwin.close(file.descriptor)
        if let limit, file.size > limit { throw SafeFileReadError.tooLarge(file.path, limit: limit) }
        return file.size
    }

    struct OpenedFile {
        let descriptor: Int32
        let path: String
        let size: Int
    }

    /// The caller closes the descriptor.
    static func openRegularFile(_ url: URL, followSymlinks: Bool) throws -> OpenedFile {
        let path = url.path
        var metadata = stat()
        // Classify first: opening a device or socket can have side effects of its own.
        guard Darwin.fstatat(AT_FDCWD, path, &metadata, followSymlinks ? 0 : AT_SYMLINK_NOFOLLOW) == 0 else {
            throw fileError(errno, path: path)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw SafeFileReadError.notRegularFile(path) }
        var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY
        if !followSymlinks { flags |= O_NOFOLLOW }
        var descriptor: Int32
        repeat { descriptor = Darwin.open(path, flags) } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else { throw fileError(errno, path: path) }
        // The path may have changed since stat; only the open descriptor is authoritative.
        guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw SafeFileReadError.notRegularFile(path)
        }
        // A regular file never blocks; restore ordinary reads.
        let current = fcntl(descriptor, F_GETFL)
        if current >= 0 { _ = fcntl(descriptor, F_SETFL, current & ~O_NONBLOCK) }
        return OpenedFile(descriptor: descriptor, path: path, size: Int(metadata.st_size))
    }

    /// Fails at once when the metadata already exceeds the limit, and otherwise
    /// trusts only the bytes actually read.
    static func readAll(_ file: OpenedFile, limit: Int) throws -> Data {
        guard file.size <= limit else { throw SafeFileReadError.tooLarge(file.path, limit: limit) }
        let data = try read(file, upTo: limit + 1)
        guard data.count <= limit else { throw SafeFileReadError.tooLarge(file.path, limit: limit) }
        return data
    }

    private static func read(_ file: OpenedFile, upTo maximum: Int) throws -> Data {
        var data = Data()
        // Metadata only sizes the buffer; it never decides when reading stops.
        data.reserveCapacity(min(max(file.size, 0), maximum))
        var buffer = [UInt8](repeating: 0, count: max(1, min(64 * 1024, maximum)))
        while data.count < maximum {
            let wanted = min(buffer.count, maximum - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file.descriptor, $0.baseAddress, wanted) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw fileError(errno, path: file.path)
            }
        }
        return data
    }

    /// Foundation's own codes, so callers that recognize a missing file still do.
    private static func fileError(_ code: Int32, path: String) -> Error {
        let cocoa: CocoaError.Code = switch code {
        case ENOENT, ENOTDIR: .fileReadNoSuchFile
        case EACCES, EPERM: .fileReadNoPermission
        default: .fileReadUnknown
        }
        return CocoaError(cocoa, userInfo: [
            NSFilePathErrorKey: path,
            NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO),
        ])
    }
}
