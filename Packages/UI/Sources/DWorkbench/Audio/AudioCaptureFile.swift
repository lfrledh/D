import AudioToolbox
import Darwin
import Foundation

struct AudioCaptureIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

/// Owns the exact inode created by ProjectStore. The unchecked conformance is deliberately
/// confined to this C-callback bridge: every descriptor operation and close is serialized by
/// `lock`, and AudioFileID never outlives the strong owner held by the recording device.
final class AudioCaptureFile: @unchecked Sendable {
    let id: UUID
    let url: URL
    let rootIdentity: AudioCaptureIdentity
    let directoryIdentity: AudioCaptureIdentity
    let fileIdentity: AudioCaptureIdentity

    private let lock = NSLock()
    private var fileDescriptor: Int32
    private var directoryDescriptor: Int32
    private var firstCallbackError: String?

    init(id: UUID, url: URL, fileDescriptor: Int32, directoryDescriptor: Int32,
         rootIdentity: AudioCaptureIdentity, directoryIdentity: AudioCaptureIdentity,
         fileIdentity: AudioCaptureIdentity) {
        self.id = id
        self.url = url
        self.fileDescriptor = fileDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.rootIdentity = rootIdentity
        self.directoryIdentity = directoryIdentity
        self.fileIdentity = fileIdentity
    }

    deinit {
        lock.lock()
        let file = fileDescriptor
        let directory = directoryDescriptor
        fileDescriptor = -1
        directoryDescriptor = -1
        lock.unlock()
        if file >= 0 { Darwin.close(file) }
        if directory >= 0 { Darwin.close(directory) }
    }

    func duplicateDescriptor() throws -> Int32 {
        try lock.withLock {
            guard fileDescriptor >= 0 else { throw AudioMediaError.io("录音文件已经关闭") }
            let result = dup(fileDescriptor)
            guard result >= 0 else { throw AudioMediaError.io(String(cString: strerror(errno))) }
            return result
        }
    }

    func currentIdentities() throws -> (AudioCaptureIdentity, AudioCaptureIdentity) {
        try lock.withLock {
            guard fileDescriptor >= 0, directoryDescriptor >= 0 else {
                throw AudioMediaError.io("录音文件已经关闭")
            }
            var fileInfo = stat(), directoryInfo = stat()
            guard fstat(fileDescriptor, &fileInfo) == 0,
                  fstat(directoryDescriptor, &directoryInfo) == 0 else {
                throw AudioMediaError.io(String(cString: strerror(errno)))
            }
            guard fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1 else {
                throw AudioMediaError.invalidMedia("录音必须是单链接普通文件")
            }
            return (AudioCaptureIdentity(directoryInfo), AudioCaptureIdentity(fileInfo))
        }
    }

    func initializeAudioFile(format: inout AudioStreamBasicDescription) throws -> AudioFileID {
        var result: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(self).toOpaque(),
            audioCaptureRead, audioCaptureWrite, audioCaptureGetSize, audioCaptureSetSize,
            kAudioFileCAFType, &format, [], &result
        )
        guard status == noErr, let result else {
            throw AudioMediaError.io("无法在已持有录音文件上初始化 CAF（\(status)）")
        }
        return result
    }

    func synchronize() -> String? {
        lock.withLock {
            if let firstCallbackError { return firstCallbackError }
            guard fileDescriptor >= 0, directoryDescriptor >= 0 else { return "录音文件已经关闭" }
            if fsync(fileDescriptor) != 0 { return String(cString: strerror(errno)) }
            if fsync(directoryDescriptor) != 0 { return String(cString: strerror(errno)) }
            return firstCallbackError
        }
    }

    fileprivate func read(at position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer,
                          actualCount: UnsafeMutablePointer<UInt32>) -> OSStatus {
        lock.withLock {
            actualCount.pointee = 0
            guard fileDescriptor >= 0, position >= 0,
                  position <= Int64(AudioLimits.maximumBytes),
                  Int64(count) <= Int64(AudioLimits.maximumBytes) - position else {
                return fail("录音读取越过 64 MiB 边界")
            }
            var completed = 0
            while completed < Int(count) {
                let amount = pread(fileDescriptor, buffer.advanced(by: completed),
                                   Int(count) - completed, off_t(position) + off_t(completed))
                if amount < 0, errno == EINTR { continue }
                if amount < 0 { return fail(String(cString: strerror(errno))) }
                if amount == 0 { break }
                completed += amount
            }
            actualCount.pointee = UInt32(completed)
            return noErr
        }
    }

    fileprivate func write(at position: Int64, count: UInt32, from buffer: UnsafeRawPointer,
                           actualCount: UnsafeMutablePointer<UInt32>) -> OSStatus {
        lock.withLock {
            actualCount.pointee = 0
            guard fileDescriptor >= 0, position >= 0,
                  position <= Int64(AudioLimits.maximumBytes),
                  Int64(count) <= Int64(AudioLimits.maximumBytes) - position else {
                return fail("录音写入越过 64 MiB 边界")
            }
            var completed = 0
            while completed < Int(count) {
                let amount = pwrite(fileDescriptor, buffer.advanced(by: completed),
                                    Int(count) - completed, off_t(position) + off_t(completed))
                if amount < 0, errno == EINTR { continue }
                if amount <= 0 { return fail(String(cString: strerror(errno))) }
                completed += amount
            }
            actualCount.pointee = count
            return noErr
        }
    }

    fileprivate func size() -> Int64 {
        lock.withLock {
            guard fileDescriptor >= 0 else { return 0 }
            var info = stat()
            guard fstat(fileDescriptor, &info) == 0, info.st_size >= 0,
                  info.st_size <= AudioLimits.maximumBytes else {
                _ = fail("无法读取录音文件长度")
                return 0
            }
            return Int64(info.st_size)
        }
    }

    fileprivate func resize(to size: Int64) -> OSStatus {
        lock.withLock {
            guard fileDescriptor >= 0, size >= 0, size <= Int64(AudioLimits.maximumBytes) else {
                return fail("录音文件大小越过 64 MiB 边界")
            }
            guard ftruncate(fileDescriptor, off_t(size)) == 0 else {
                return fail(String(cString: strerror(errno)))
            }
            return noErr
        }
    }

    private func fail(_ message: String) -> OSStatus {
        if firstCallbackError == nil { firstCallbackError = message }
        return kAudioFileUnspecifiedError
    }
}

private func capture(_ clientData: UnsafeMutableRawPointer?) -> AudioCaptureFile? {
    guard let clientData else { return nil }
    return Unmanaged<AudioCaptureFile>.fromOpaque(clientData).takeUnretainedValue()
}

private let audioCaptureRead: AudioFile_ReadProc = { clientData, position, count, buffer, actual in
    guard let owner = capture(clientData), let actual else { return kAudioFileUnspecifiedError }
    return owner.read(at: position, count: count, into: buffer, actualCount: actual)
}

private let audioCaptureWrite: AudioFile_WriteProc = { clientData, position, count, buffer, actual in
    guard let owner = capture(clientData), let actual else { return kAudioFileUnspecifiedError }
    return owner.write(at: position, count: count, from: buffer, actualCount: actual)
}

private let audioCaptureGetSize: AudioFile_GetSizeProc = { clientData in
    capture(clientData)?.size() ?? 0
}

private let audioCaptureSetSize: AudioFile_SetSizeProc = { clientData, size in
    capture(clientData)?.resize(to: size) ?? kAudioFileUnspecifiedError
}
