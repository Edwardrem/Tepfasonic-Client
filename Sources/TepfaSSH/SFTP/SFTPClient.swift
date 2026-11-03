import Foundation
import NIOCore
import Synchronization

/// An SFTP session on an `SSHConnection`: directory listings, file metadata,
/// and pipelined uploads and downloads with progress and resume.
///
/// Requests are matched to replies by id, so several can be in flight; the
/// transfer methods keep a window of reads or writes outstanding to fill the
/// pipe. Every method is safe to call from any task.
public final class SFTPClient: @unchecked Sendable {
    public typealias Progress = @Sendable (_ transferred: Int64, _ total: Int64?) -> Void

    /// Bytes per read or write request; OpenSSH accepts up to 256 KiB but 32 KiB is the safe interoperable size.
    public static let chunkSize = 32 * 1024
    /// Requests kept in flight during a transfer.
    public static let pipelineDepth = 16

    public let connection: SSHConnection
    private let channel: Channel
    private let handler: SFTPResponseHandler
    private let nextID = Mutex<UInt32>(0)

    private init(connection: SSHConnection, channel: Channel, handler: SFTPResponseHandler) {
        self.connection = connection
        self.channel = channel
        self.handler = handler
    }

    public var isOpen: Bool { channel.isActive }

    /// Starts the `sftp` subsystem and negotiates version 3.
    public static func open(on connection: SSHConnection) async throws -> SFTPClient {
        let handler = SFTPResponseHandler()
        let channel = try await connection.openSubsystem("sftp") { child in
            try child.pipeline.syncOperations.addHandler(handler)
        }
        let client = SFTPClient(connection: connection, channel: channel, handler: handler)
        var writer = SFTPWriter()
        writer.writeUInt8(SFTP.PacketType.initialize.rawValue)
        writer.writeUInt32(SFTP.protocolVersion)
        let reply = try await client.send(writer, expectingVersion: true)
        var reader = SFTPReader(reply)
        guard try reader.readUInt8() == SFTP.PacketType.version.rawValue else { throw SFTP.Error.protocolError("expected SSH_FXP_VERSION") }
        let version = try reader.readUInt32()
        guard version >= 3 else { throw SFTP.Error.unsupportedVersion(version) }
        return client
    }

    public func close() {
        handler.failAll(SFTP.Error.closed)
        channel.close(promise: nil)
    }

    // MARK: Requests

    private func allocateID() -> UInt32 {
        nextID.withLock { id in
            id &+= 1
            return id
        }
    }

    /// Sends a packet and waits for its reply. For INIT the reply has no id.
    private func send(_ writer: SFTPWriter, expectingVersion: Bool = false, id: UInt32? = nil) async throws -> [UInt8] {
        guard channel.isActive else { throw SFTP.Error.closed }
        let framed = writer.framed()
        let key: UInt32 = expectingVersion ? SFTPResponseHandler.versionKey : (id ?? 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Swift.Error>) in
                handler.register(id: key, continuation: continuation)
                var buffer = channel.allocator.buffer(capacity: framed.count)
                buffer.writeBytes(framed)
                channel.writeAndFlush(buffer).whenFailure { [handler] error in
                    handler.fail(id: key, error: error)
                }
            }
        } onCancel: {
            handler.fail(id: key, error: CancellationError())
        }
    }

    private func request(_ type: SFTP.PacketType, _ body: (inout SFTPWriter) -> Void) async throws -> (SFTP.PacketType, SFTPReader) {
        let id = allocateID()
        var writer = SFTPWriter()
        writer.writeUInt8(type.rawValue)
        writer.writeUInt32(id)
        body(&writer)
        let reply = try await send(writer, id: id)
        var reader = SFTPReader(reply)
        guard let replyType = SFTP.PacketType(rawValue: try reader.readUInt8()) else { throw SFTP.Error.protocolError("unknown reply type") }
        _ = try reader.readUInt32() // id, already matched
        return (replyType, reader)
    }

    /// Reads a status reply; throws unless it is OK (or `allowEOF` and EOF).
    private func expectStatus(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String?, allowEOF: Bool = false) throws -> SFTP.StatusCode {
        guard type == .status else { throw SFTP.Error.protocolError("expected SSH_FXP_STATUS, got \(type)") }
        let code = SFTP.StatusCode(rawValue: try reader.readUInt32()) ?? .failure
        let message = (try? reader.readString()) ?? ""
        if code == .ok || (allowEOF && code == .eof) { return code }
        throw SFTP.Error.status(code, message, path: path)
    }

    private func expectAttributes(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String) throws -> SFTP.Attributes {
        switch type {
        case .attrs: return try SFTP.Attributes.decode(from: &reader)
        case .status: _ = try expectStatus(type, &reader, path: path); throw SFTP.Error.protocolError("status instead of attributes")
        default: throw SFTP.Error.protocolError("expected SSH_FXP_ATTRS, got \(type)")
        }
    }

    private func expectHandle(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String) throws -> [UInt8] {
        switch type {
        case .handle: return try reader.readBytes()
        case .status: _ = try expectStatus(type, &reader, path: path); throw SFTP.Error.protocolError("status instead of handle")
        default: throw SFTP.Error.protocolError("expected SSH_FXP_HANDLE, got \(type)")
        }
    }

    // MARK: Metadata

    public func realPath(_ path: String) async throws -> String {
        let (type, reader) = try await request(.realpath) { $0.writeString(path) }
        var reader = reader
        switch type {
        case .name:
            _ = try reader.readUInt32()
            return try reader.readString()
        default:
            _ = try expectStatus(type, &reader, path: path)
            throw SFTP.Error.protocolError("status instead of name")
        }
    }

    public func stat(_ path: String) async throws -> SFTP.Attributes {
        let (type, reader) = try await request(.stat) { $0.writeString(path) }
        var reader = reader
        return try expectAttributes(type, &reader, path: path)
    }

    public func lstat(_ path: String) async throws -> SFTP.Attributes {
        let (type, reader) = try await request(.lstat) { $0.writeString(path) }
        var reader = reader
        return try expectAttributes(type, &reader, path: path)
    }

    public func setAttributes(_ attributes: SFTP.Attributes, path: String) async throws {
        let (type, reader) = try await request(.setstat) { writer in
            writer.writeString(path)
            attributes.encode(into: &writer)
        }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    public func setPermissions(_ mode: UInt32, path: String) async throws {
        try await setAttributes(SFTP.Attributes(permissions: mode & 0o7777), path: path)
    }

    public func readLink(_ path: String) async throws -> String {
        let (type, reader) = try await request(.readlink) { $0.writeString(path) }
        var reader = reader
        guard type == .name else {
            _ = try expectStatus(type, &reader, path: path)
            throw SFTP.Error.protocolError("status instead of name")
        }
        _ = try reader.readUInt32()
        return try reader.readString()
    }

    public func symlink(target: String, at path: String) async throws {
        // OpenSSH reverses the documented argument order; it is what every client sends.
        let (type, reader) = try await request(.symlink) { writer in
            writer.writeString(target)
            writer.writeString(path)
        }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    // MARK: Directories

    public func listDirectory(_ path: String) async throws -> [SFTP.Entry] {
        let (openType, openReader) = try await request(.opendir) { $0.writeString(path) }
        var openReader = openReader
        let handle = try expectHandle(openType, &openReader, path: path)
        var entries: [SFTP.Entry] = []
        defer { Task { try? await self.closeHandle(handle) } }
        while true {
            let (type, reader) = try await request(.readdir) { $0.writeBytes(handle) }
            var reader = reader
            if type == .status {
                _ = try expectStatus(type, &reader, path: path, allowEOF: true)
                break
            }
            guard type == .name else { throw SFTP.Error.protocolError("expected SSH_FXP_NAME") }
            let count = try reader.readUInt32()
            for _ in 0..<count {
                let name = try reader.readString()
                let longName = try reader.readString()
                let attributes = try SFTP.Attributes.decode(from: &reader)
                if name == "." || name == ".." { continue }
                entries.append(SFTP.Entry(name: name, longName: longName, attributes: attributes))
            }
        }
        return entries
    }

    public func makeDirectory(_ path: String, mode: UInt32? = nil) async throws {
        let (type, reader) = try await request(.mkdir) { writer in
            writer.writeString(path)
            SFTP.Attributes(permissions: mode).encode(into: &writer)
        }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    public func removeDirectory(_ path: String) async throws {
        let (type, reader) = try await request(.rmdir) { $0.writeString(path) }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    public func remove(_ path: String) async throws {
        let (type, reader) = try await request(.remove) { $0.writeString(path) }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        let (type, reader) = try await request(.rename) { writer in
            writer.writeString(path)
            writer.writeString(newPath)
        }
        var reader = reader
        _ = try expectStatus(type, &reader, path: path)
    }

    /// Deletes a file, or a directory and everything in it.
    public func removeRecursively(_ path: String) async throws {
        let attributes = try await lstat(path)
        guard attributes.isDirectory else {
            try await remove(path)
            return
        }
        for entry in try await listDirectory(path) {
            try Task.checkCancellation()
            try await removeRecursively(SFTP.join(path, entry.name))
        }
        try await removeDirectory(path)
    }

    // MARK: Files

    public func openFile(_ path: String, flags: SFTP.OpenFlags, mode: UInt32? = nil) async throws -> [UInt8] {
        let (type, reader) = try await request(.open) { writer in
            writer.writeString(path)
            writer.writeUInt32(flags.rawValue)
            SFTP.Attributes(permissions: mode).encode(into: &writer)
        }
        var reader = reader
        return try expectHandle(type, &reader, path: path)
    }

    public func closeHandle(_ handle: [UInt8]) async throws {
        let (type, reader) = try await request(.close) { $0.writeBytes(handle) }
        var reader = reader
        _ = try expectStatus(type, &reader, path: nil)
    }

    /// Reads up to `length` bytes; empty at end of file.
    public func read(handle: [UInt8], offset: UInt64, length: Int) async throws -> [UInt8] {
        let (type, reader) = try await request(.read) { writer in
            writer.writeBytes(handle)
            writer.writeUInt64(offset)
            writer.writeUInt32(UInt32(length))
        }
        var reader = reader
        switch type {
        case .data: return try reader.readBytes()
        case .status:
            if try expectStatus(type, &reader, path: nil, allowEOF: true) == .eof { return [] }
            return []
        default: throw SFTP.Error.protocolError("expected SSH_FXP_DATA")
        }
    }

    public func write(handle: [UInt8], offset: UInt64, data: [UInt8]) async throws {
        let (type, reader) = try await request(.write) { writer in
            writer.writeBytes(handle)
            writer.writeUInt64(offset)
            writer.writeBytes(data)
        }
        var reader = reader
        _ = try expectStatus(type, &reader, path: nil)
    }

    /// Reads a whole file into memory (for open-with and small previews).
    public func readFile(_ path: String, limit: Int = 64 * 1024 * 1024) async throws -> Data {
        let handle = try await openFile(path, flags: [.read])
        defer { Task { try? await self.closeHandle(handle) } }
        var out = Data()
        var offset: UInt64 = 0
        while out.count < limit {
            let chunk = try await read(handle: handle, offset: offset, length: Self.chunkSize)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
            offset += UInt64(chunk.count)
        }
        return out
    }

    public func writeFile(_ data: Data, to path: String, mode: UInt32? = nil) async throws {
        let handle = try await openFile(path, flags: [.write, .create, .truncate], mode: mode)
        var offset: UInt64 = 0
        let bytes = [UInt8](data)
        while Int(offset) < bytes.count {
            let end = min(Int(offset) + Self.chunkSize, bytes.count)
            try await write(handle: handle, offset: offset, data: Array(bytes[Int(offset)..<end]))
            offset = UInt64(end)
        }
        try await closeHandle(handle)
    }

    // MARK: Transfers

    /// Downloads `remotePath` to `localURL`, with `pipelineDepth` reads in
    /// flight. With `resume`, appends to the existing local file starting at its size.
    public func download(_ remotePath: String, to localURL: URL, resume: Bool = false, progress: Progress? = nil) async throws {
        let attributes = try await stat(remotePath)
        let total = attributes.size.map(Int64.init)
        var offset: UInt64 = 0
        let manager = FileManager.default
        if resume, let existing = try? manager.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber {
            offset = existing.uint64Value
            if let total, Int64(offset) >= total {
                progress?(total, total)
                return
            }
        } else {
            try manager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: localURL.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        let handle = try await openFile(remotePath, flags: [.read])
        defer { Task { try? await self.closeHandle(handle) } }

        var transferred = Int64(offset)
        var nextOffset = offset
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let starts = (0..<Self.pipelineDepth).map { nextOffset + UInt64($0 * Self.chunkSize) }
            let chunks = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group -> [[UInt8]] in
                for (index, start) in starts.enumerated() {
                    group.addTask { (index, try await self.read(handle: handle, offset: start, length: Self.chunkSize)) }
                }
                var results = [[UInt8]](repeating: [], count: starts.count)
                for try await (index, bytes) in group { results[index] = bytes }
                return results
            }
            for chunk in chunks {
                if chunk.isEmpty {
                    finished = true
                    break
                }
                try file.write(contentsOf: chunk)
                transferred += Int64(chunk.count)
                nextOffset += UInt64(chunk.count)
                progress?(transferred, total)
                if chunk.count < Self.chunkSize {
                    finished = true
                    break
                }
            }
        }
        if let modified = attributes.modificationTime {
            try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: localURL.path)
        }
        progress?(transferred, total ?? transferred)
    }

    /// Uploads `localURL` to `remotePath` with `pipelineDepth` writes in flight.
    /// With `resume`, continues from the remote file's current size.
    public func upload(_ localURL: URL, to remotePath: String, resume: Bool = false, mode: UInt32? = nil, progress: Progress? = nil) async throws {
        let total = Int64((try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var offset: UInt64 = 0
        if resume, let existing = try? await stat(remotePath).size, Int64(existing) <= total {
            offset = existing
        }
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        let flags: SFTP.OpenFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
        let handle = try await openFile(remotePath, flags: flags, mode: mode)
        var transferred = Int64(offset)
        progress?(transferred, total)
        while true {
            try Task.checkCancellation()
            var batch: [(UInt64, [UInt8])] = []
            for _ in 0..<Self.pipelineDepth {
                guard let data = try file.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                batch.append((offset, [UInt8](data)))
                offset += UInt64(data.count)
            }
            if batch.isEmpty { break }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (start, bytes) in batch {
                    group.addTask { try await self.write(handle: handle, offset: start, data: bytes) }
                }
                try await group.waitForAll()
            }
            transferred += Int64(batch.reduce(0) { $0 + $1.1.count })
            progress?(transferred, total)
        }
        try await closeHandle(handle)
        progress?(transferred, total)
    }
}

/// Reassembles SFTP packets from the channel and hands each reply to the
/// request that is waiting for it.
final class SFTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    static let versionKey: UInt32 = UInt32.max

    private let pending = Mutex<[UInt32: CheckedContinuation<[UInt8], Swift.Error>]>([:])
    private var framer = SFTPFramer()

    func register(id: UInt32, continuation: CheckedContinuation<[UInt8], Swift.Error>) {
        let duplicate = pending.withLock { table -> CheckedContinuation<[UInt8], Swift.Error>? in
            let existing = table[id]
            table[id] = continuation
            return existing
        }
        duplicate?.resume(throwing: SFTP.Error.protocolError("duplicate request id"))
    }

    func fail(id: UInt32, error: Swift.Error) {
        pending.withLock { $0.removeValue(forKey: id) }?.resume(throwing: error)
    }

    func failAll(_ error: Swift.Error) {
        let all = pending.withLock { table -> [CheckedContinuation<[UInt8], Swift.Error>] in
            let values = Array(table.values)
            table.removeAll()
            return values
        }
        for continuation in all { continuation.resume(throwing: error) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        for packet in framer.feed(bytes) {
            guard let type = packet.first else { continue }
            let id: UInt32
            if type == SFTP.PacketType.version.rawValue {
                id = Self.versionKey
            } else {
                guard packet.count >= 5 else { continue }
                id = UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 8 | UInt32(packet[4])
            }
            pending.withLock { $0.removeValue(forKey: id) }?.resume(returning: packet)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTP.Error.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Swift.Error) {
        failAll(error)
        context.close(promise: nil)
    }
}
