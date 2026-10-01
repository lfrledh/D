import Foundation
import MLX
import Darwin
import CoreFoundation

public struct SafeTensorMetadata: Sendable {
  public let name: String
  public let dtype: DType
  public let shape: [Int]
  public let dataOffset: Int
  public let byteCount: Int

  public var elementCount: Int {
    shape.reduce(1, *)
  }
}

public enum SafeTensorsReaderError: Error {
  case fileTooSmall(URL)
  case invalidHeaderLength(URL)
  case malformedHeader(URL)
  case tensorMetadataMissing(String)
  case unsupportedDType(String)
  case unsupportedScalarDType(name: String, dtype: String)
  case invalidOffsets(name: String)
  case invalidShape(name: String)
  case tensorNotFound(String)
  case unmappedData(URL)
  case fileChanged(URL)
  case truncatedData(URL)
}

public final class SafeTensorsReader {
  public let fileURL: URL
  private let descriptor: Int32
  private let identity: FileIdentity
  private let tensors: [String: SafeTensorMetadata]
  public let fileMetadata: [String: String]

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: timespec
    let changed: timespec

    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      modified = value.st_mtimespec
      changed = value.st_ctimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
        lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
        lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
  }

  deinit { Darwin.close(descriptor) }

  public init(fileURL: URL) throws {
    try Task.checkCancellation()
    let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw SafeTensorsReaderError.fileChanged(fileURL) }
    var keepDescriptor = false
    defer { if !keepDescriptor { Darwin.close(fd) } }
    var info = stat()
    guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= off_t(Int.max) else {
      throw SafeTensorsReaderError.fileChanged(fileURL)
    }
    let original = FileIdentity(info)
    guard info.st_size >= off_t(MemoryLayout<UInt64>.size) else {
      throw SafeTensorsReaderError.fileTooSmall(fileURL)
    }
    let lengthBytes = try Self.read(fd, offset: 0, count: 8, fileURL: fileURL)
    let length = lengthBytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    // Safetensors caps JSON headers at 100 MB. Check before allocating or converting to Int.
    guard length <= 100_000_000, length <= UInt64(info.st_size - 8) else {
      throw SafeTensorsReaderError.invalidHeaderLength(fileURL)
    }
    let headerLength = Int(length)
    let headerStart = 8
    let headerEnd = headerStart + headerLength
    let headerData = try Self.read(fd, offset: headerStart, count: headerLength, fileURL: fileURL)
    guard Self.hasUniqueObjectKeys(headerData) else {
      throw SafeTensorsReaderError.malformedHeader(fileURL)
    }
    try Task.checkCancellation()
    let headerJSON: Any
    do { headerJSON = try JSONSerialization.jsonObject(with: headerData, options: []) }
    catch { throw SafeTensorsReaderError.malformedHeader(fileURL) }

    guard let headerDict = headerJSON as? [String: Any] else {
      throw SafeTensorsReaderError.malformedHeader(fileURL)
    }

    var tensorMetadata: [String: SafeTensorMetadata] = [:]
    var metadataValues: [String: String] = [:]
    var ranges: [(Int, Int)] = []

    let dataStartOffset = headerEnd

    for (key, value) in headerDict {
      try Task.checkCancellation()
      if key == "__metadata__" {
        guard let dict = value as? [String: String] else {
          throw SafeTensorsReaderError.malformedHeader(fileURL)
        }
        metadataValues = dict
        continue
      }

      guard let tensorInfo = value as? [String: Any],
            Set(tensorInfo.keys) == Set(["dtype", "shape", "data_offsets"]) else {
        throw SafeTensorsReaderError.tensorMetadataMissing(key)
      }

      guard let dtypeString = tensorInfo["dtype"] as? String else {
        throw SafeTensorsReaderError.tensorMetadataMissing(key)
      }

      let dtype = try SafeTensorsReader.mapDType(dtypeString)

      guard let shapeAny = tensorInfo["shape"] as? [Any] else {
        throw SafeTensorsReaderError.tensorMetadataMissing(key)
      }

      let shape: [Int] = try shapeAny.map { try Self.parseInteger($0, error: .invalidShape(name: key)) }

      guard let offsetsAny = tensorInfo["data_offsets"] as? [Any], offsetsAny.count == 2 else {
        throw SafeTensorsReaderError.tensorMetadataMissing(key)
      }

      let startOffset = try SafeTensorsReader.parseOffset(offsetsAny[0], tensorName: key)
      let endOffset = try SafeTensorsReader.parseOffset(offsetsAny[1], tensorName: key)

      guard startOffset >= 0, endOffset >= startOffset else {
        throw SafeTensorsReaderError.invalidOffsets(name: key)
      }

      let byteCount = endOffset - startOffset
      let expectedBytes = try SafeTensorsReader.expectedByteCount(shape: shape, dtype: dtype, name: key)
      guard byteCount == expectedBytes else {
        throw SafeTensorsReaderError.invalidShape(name: key)
      }

      let (absoluteOffset, offsetOverflow) = dataStartOffset.addingReportingOverflow(startOffset)
      guard !offsetOverflow, startOffset >= 0, endOffset <= Int(info.st_size) - dataStartOffset else {
        throw SafeTensorsReaderError.invalidOffsets(name: key)
      }

      tensorMetadata[key] = SafeTensorMetadata(
        name: key,
        dtype: dtype,
        shape: shape,
        dataOffset: absoluteOffset,
        byteCount: byteCount
      )
      ranges.append((startOffset, endOffset))
    }

    var nextOffset = 0
    for range in ranges.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
      guard range.0 == nextOffset else { throw SafeTensorsReaderError.malformedHeader(fileURL) }
      nextOffset = range.1
    }
    guard nextOffset == Int(info.st_size) - headerEnd else {
      throw SafeTensorsReaderError.malformedHeader(fileURL)
    }

    try Self.checkIdentity(fd, fileURL: fileURL, original: original)
    self.fileURL = fileURL
    self.descriptor = fd
    self.identity = original
    self.tensors = tensorMetadata
    self.fileMetadata = metadataValues
    keepDescriptor = true
  }

  public var tensorNames: [String] {
    Array(tensors.keys)
  }

  public func metadata(for name: String) -> SafeTensorMetadata? {
    tensors[name]
  }

  public func contains(_ name: String) -> Bool {
    tensors[name] != nil
  }

  public func allMetadata() -> [SafeTensorMetadata] {
    Array(tensors.values)
  }

  public func loadAllTensors(as dtype: DType? = nil) throws -> [String: MLXArray] {
    var results: [String: MLXArray] = [:]
    for name in tensorNames {
      var tensor = try self.tensor(named: name)
      if let dtype, tensor.dtype != dtype {
        tensor = tensor.asType(dtype)
      }
      results[name] = tensor
    }
    return results
  }

  public func tensor(named name: String) throws -> MLXArray {
    guard let metadata = tensors[name] else {
      throw SafeTensorsReaderError.tensorNotFound(name)
    }

    let data = try readTensor(metadata)
    return MLXArray(data, metadata.shape, dtype: metadata.dtype)
  }

  public func intScalar(named name: String) throws -> Int {
    guard let metadata = tensors[name] else {
      throw SafeTensorsReaderError.tensorNotFound(name)
    }
    guard metadata.elementCount == 1 else {
      throw SafeTensorsReaderError.invalidShape(name: name)
    }

    let data = try readTensor(metadata)
    return try data.withUnsafeBytes { rawBuffer in
      guard let valuePtr = rawBuffer.baseAddress else { throw SafeTensorsReaderError.truncatedData(fileURL) }
      switch metadata.dtype {
      case .int32:
        var value: Int32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
          dst.copyBytes(from: UnsafeRawBufferPointer(start: valuePtr, count: MemoryLayout<Int32>.size))
        }
        return Int(value)

      case .int64:
        var value: Int64 = 0
        withUnsafeMutableBytes(of: &value) { dst in
          dst.copyBytes(from: UnsafeRawBufferPointer(start: valuePtr, count: MemoryLayout<Int64>.size))
        }
        return Int(value)

      case .uint32:
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
          dst.copyBytes(from: UnsafeRawBufferPointer(start: valuePtr, count: MemoryLayout<UInt32>.size))
        }
        return Int(value)

      case .uint64:
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { dst in
          dst.copyBytes(from: UnsafeRawBufferPointer(start: valuePtr, count: MemoryLayout<UInt64>.size))
        }
        guard let converted = Int(exactly: value) else {
          throw SafeTensorsReaderError.invalidShape(name: name)
        }
        return converted

      default:
        throw SafeTensorsReaderError.unsupportedScalarDType(name: name, dtype: String(describing: metadata.dtype))
      }
    }
  }

  private static func parseOffset(_ value: Any, tensorName: String) throws -> Int {
    try parseInteger(value, error: .invalidOffsets(name: tensorName))
  }

  private static func expectedByteCount(shape: [Int], dtype: DType, name: String) throws -> Int {
    var elements = 1
    for dimension in shape {
      // MLX stores dimensions as Int32, including when a zero dimension makes
      // the total byte count zero. Reject an unrepresentable shape before load.
      guard (0...Int(Int32.max)).contains(dimension) else {
        throw SafeTensorsReaderError.invalidShape(name: name)
      }
      let (next, overflow) = elements.multipliedReportingOverflow(by: dimension)
      guard !overflow else { throw SafeTensorsReaderError.invalidShape(name: name) }
      elements = next
    }
    let (bytes, overflow) = elements.multipliedReportingOverflow(by: dtype.size)
    guard !overflow else { throw SafeTensorsReaderError.invalidShape(name: name) }
    return bytes
  }

  private static func parseInteger(_ value: Any, error: SafeTensorsReaderError) throws -> Int {
    // Safetensors shape and offset members are JSON integers. A mathematically
    // integral JSON float such as 1.0 or 1e0 is still the wrong token type.
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
          let result = Int(number.stringValue), String(result) == number.stringValue else {
      throw error
    }
    return result
  }

  private static func read(_ fd: Int32, offset: Int, count: Int, fileURL: URL) throws -> Data {
    try Task.checkCancellation()
    var data = Data(count: count)
    var done = 0
    while done < count {
      try Task.checkCancellation()
      let n = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(fd, bytes.baseAddress?.advanced(by: done), count - done, off_t(offset + done))
      }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw SafeTensorsReaderError.truncatedData(fileURL) }
      done += n
    }
    return data
  }

  private static func checkIdentity(_ fd: Int32, fileURL: URL, original: FileIdentity) throws {
    var opened = stat()
    var path = stat()
    guard Darwin.fstat(fd, &opened) == 0,
          Darwin.lstat(fileURL.path, &path) == 0,
          opened.st_mode & S_IFMT == S_IFREG, path.st_mode & S_IFMT == S_IFREG,
          FileIdentity(opened) == original, FileIdentity(path) == original else {
      throw SafeTensorsReaderError.fileChanged(fileURL)
    }
  }

  private func readTensor(_ metadata: SafeTensorMetadata) throws -> Data {
    try Self.checkIdentity(descriptor, fileURL: fileURL, original: identity)
    let data = try Self.read(descriptor, offset: metadata.dataOffset,
                             count: metadata.byteCount, fileURL: fileURL)
    try Self.checkIdentity(descriptor, fileURL: fileURL, original: identity)
    return data
  }

  /// JSONSerialization keeps the last duplicate object member; reject duplicates
  /// before it can silently change a tensor's dtype, shape or offsets.
  private static func hasUniqueObjectKeys(_ data: Data) -> Bool {
    let bytes = Array(data)
    var cursor = 0
    func whitespace() {
      while cursor < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[cursor]) { cursor += 1 }
    }
    func string() -> String? {
      let start = cursor
      guard cursor < bytes.count, bytes[cursor] == 34 else { return nil }
      cursor += 1
      while cursor < bytes.count {
        if bytes[cursor] == 92 { cursor += 2; continue }
        if bytes[cursor] == 34 {
          cursor += 1
          return try? JSONSerialization.jsonObject(with: Data(bytes[start..<cursor]),
                                                    options: .fragmentsAllowed) as? String
        }
        cursor += 1
      }
      return nil
    }
    func value(_ depth: Int) -> Bool {
      guard depth <= 128 else { return false }
      whitespace()
      guard cursor < bytes.count else { return false }
      if bytes[cursor] == 34 { return string() != nil }
      if bytes[cursor] == 123 || bytes[cursor] == 91 {
        let object = bytes[cursor] == 123
        let closing: UInt8 = object ? 125 : 93
        cursor += 1
        whitespace()
        if cursor < bytes.count, bytes[cursor] == closing { cursor += 1; return true }
        var keys = Set<String>()
        while cursor < bytes.count {
          if object {
            guard let key = string(), keys.insert(key).inserted else { return false }
            whitespace()
            guard cursor < bytes.count, bytes[cursor] == 58 else { return false }
            cursor += 1
          }
          guard value(depth + 1) else { return false }
          whitespace()
          guard cursor < bytes.count else { return false }
          if bytes[cursor] == closing { cursor += 1; return true }
          guard bytes[cursor] == 44 else { return false }
          cursor += 1
          whitespace()
        }
        return false
      }
      let start = cursor
      while cursor < bytes.count && ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[cursor]) {
        cursor += 1
      }
      return cursor > start
    }
    guard value(0) else { return false }
    whitespace()
    return cursor == bytes.count
  }

  private static func mapDType(_ value: String) throws -> DType {
    let key = value.uppercased()
    switch key {
    case "F32":
      return .float32
    case "F16":
      return .float16
    case "F64":
      return .float64
    case "BF16":
      return .bfloat16
    case "I64":
      return .int64
    case "I32":
      return .int32
    case "I16":
      return .int16
    case "I8":
      return .int8
    case "U64":
      return .uint64
    case "U32":
      return .uint32
    case "U16":
      return .uint16
    case "U8":
      return .uint8
    case "BOOL":
      return .bool
    default:
      throw SafeTensorsReaderError.unsupportedDType(value)
    }
  }
}
