import Foundation
import MLX
import XCTest
@testable import Flux2

final class SafeTensorsReaderTests: XCTestCase {
  private func writeRaw(_ url: URL, header: String, data: Data = Data()) throws {
    var length = UInt64(header.utf8.count).littleEndian
    var file = withUnsafeBytes(of: &length) { Data($0) }
    file.append(contentsOf: header.utf8)
    file.append(data)
    try file.write(to: url)
  }

  func testRejectsUnboundedAndTruncatedHeaders() throws {
    try withTempDir { dir in
      let url = dir.appendingPathComponent("bad.safetensors")
      var huge = UInt64.max.littleEndian
      try withUnsafeBytes(of: &huge) { Data($0) }.write(to: url)
      XCTAssertThrowsError(try SafeTensorsReader(fileURL: url))
      var truncated = UInt64(100).littleEndian
      try withUnsafeBytes(of: &truncated) { Data($0) }.write(to: url)
      XCTAssertThrowsError(try SafeTensorsReader(fileURL: url))
      try writeRaw(url, header: "{\"x\":{}")
      XCTAssertThrowsError(try SafeTensorsReader(fileURL: url))
    }
  }

  func testRejectsInvalidShapesOffsetsAndDuplicateKeys() throws {
    try withTempDir { dir in
      let url = dir.appendingPathComponent("bad.safetensors")
      for header in [
        #"{"x":{"dtype":"F32","shape":[9223372036854775807,2],"data_offsets":[0,0]}}"#,
        #"{"x":{"dtype":"F32","shape":[-1],"data_offsets":[0,0]}}"#,
        #"{"x":{"dtype":"F32","shape":[1],"data_offsets":[-1,3]}}"#,
        #"{"x":{"dtype":"F32","shape":[1],"data_offsets":[9223372036854775808,9223372036854775812]}}"#,
        #"{"x":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#,
        #"{"x":{"dtype":"F32","shape":[1],"data_offsets":[0,4],"dtype":"I32"}}"#,
        #"{"x":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"x":{"dtype":"I32","shape":[1],"data_offsets":[0,4]}}"#,
      ] {
        let payload = header.contains(#""data_offsets":[0,4]}}"#) ? Data() : Data(repeating: 0, count: 4)
        try writeRaw(url, header: header, data: payload)
        XCTAssertThrowsError(try SafeTensorsReader(fileURL: url), header)
      }
    }
  }

  func testValidI64EmptyShapeAndReplacementBeforeLoad() throws {
    try withTempDir { dir in
      let url = dir.appendingPathComponent("scalar.safetensors")
      var value = Int64(250).littleEndian
      try writeRaw(url, header: #"{"bn.num_batches_tracked":{"dtype":"I64","shape":[],"data_offsets":[0,8]}}"#,
                   data: withUnsafeBytes(of: &value) { Data($0) })
      let reader = try SafeTensorsReader(fileURL: url)
      XCTAssertEqual(reader.metadata(for: "bn.num_batches_tracked")?.elementCount, 1)
      XCTAssertEqual(try reader.intScalar(named: "bn.num_batches_tracked"), 250)
      try Data(repeating: 0, count: 8).write(to: url, options: .atomic)
      XCTAssertThrowsError(try reader.intScalar(named: "bn.num_batches_tracked"))
    }
  }

  func testCancelledReadDoesNotLoadTensor() async throws {
    try withTempDir { dir in
      let url = dir.appendingPathComponent("cancelled.safetensors")
      try writeRaw(url, header: #"{"x":{"dtype":"I64","shape":[],"data_offsets":[0,8]}}"#,
                   data: Data(repeating: 0, count: 8))
      let reader = try SafeTensorsReader(fileURL: url)
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try reader.intScalar(named: "x")
      }
      do { _ = try await task.value; XCTFail("Cancelled read succeeded") }
      catch is CancellationError { }
    }
  }
  private func withTempDir(_ body: (URL) throws -> Void) throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try body(tempDir)
  }

  func testReadsTensorValues() throws {
    try withTempDir { tempDir in
      let fileURL = tempDir.appendingPathComponent("weights.safetensors")
      let values: [Float32] = [1, 2, 3, 4]
      try TestHelpers.writeSafeTensor(
        url: fileURL,
        tensorName: "linear.weight",
        values: values,
        shape: [2, 2]
      )

      let reader = try SafeTensorsReader(fileURL: fileURL)
      let tensor = try reader.tensor(named: "linear.weight")

      XCTAssertEqual(tensor.shape, [2, 2])
      XCTAssertEqual(tensor.dtype, .float32)

      let loaded = tensor.asArray(Float32.self)
      XCTAssertEqual(loaded, values)
    }
  }

  func testReadsIntScalars() throws {
    try withTempDir { tempDir in
      let tests: [(dtype: String, value: Int)] = [
        ("I32", 42),
        ("I64", 43),
        ("U32", 44),
        ("U64", 45),
      ]

      for (dtype, value) in tests {
        let fileURL = tempDir.appendingPathComponent("scalar_\(dtype).safetensors")

        let data: Data = {
          switch dtype {
          case "I32":
            var raw = Int32(value).littleEndian
            return withUnsafeBytes(of: &raw) { Data($0) }
          case "I64":
            var raw = Int64(value).littleEndian
            return withUnsafeBytes(of: &raw) { Data($0) }
          case "U32":
            var raw = UInt32(value).littleEndian
            return withUnsafeBytes(of: &raw) { Data($0) }
          case "U64":
            var raw = UInt64(value).littleEndian
            return withUnsafeBytes(of: &raw) { Data($0) }
          default:
            XCTFail("Unhandled dtype \(dtype)")
            return Data()
          }
        }()

        try TestHelpers.writeSafeTensor(
          url: fileURL,
          tensorName: "scalar",
          dtype: dtype,
          shape: [1],
          data: data
        )

        let reader = try SafeTensorsReader(fileURL: fileURL)
        let loaded = try reader.intScalar(named: "scalar")
        XCTAssertEqual(loaded, value)
      }
    }
  }

  func testIntScalarRejectsNonScalarShapes() throws {
    try withTempDir { tempDir in
      let fileURL = tempDir.appendingPathComponent("not_scalar.safetensors")
      let values: [Int32] = [1, 2]
      let data = values.withUnsafeBytes { Data($0) }

      try TestHelpers.writeSafeTensor(
        url: fileURL,
        tensorName: "x",
        dtype: "I32",
        shape: [2],
        data: data
      )

      let reader = try SafeTensorsReader(fileURL: fileURL)
      XCTAssertThrowsError(try reader.intScalar(named: "x")) { error in
        guard case SafeTensorsReaderError.invalidShape(name: "x") = error else {
          XCTFail("Unexpected error \(error)")
          return
        }
      }
    }
  }

  func testIntScalarRejectsUnsupportedDType() throws {
    try withTempDir { tempDir in
      let fileURL = tempDir.appendingPathComponent("float_scalar.safetensors")
      var value: Float32 = 1.0
      let data = withUnsafeBytes(of: &value) { Data($0) }

      try TestHelpers.writeSafeTensor(
        url: fileURL,
        tensorName: "x",
        dtype: "F32",
        shape: [1],
        data: data
      )

      let reader = try SafeTensorsReader(fileURL: fileURL)
      XCTAssertThrowsError(try reader.intScalar(named: "x")) { error in
        guard case SafeTensorsReaderError.unsupportedScalarDType(name: "x", dtype: _) = error else {
          XCTFail("Unexpected error \(error)")
          return
        }
      }
    }
  }
}
