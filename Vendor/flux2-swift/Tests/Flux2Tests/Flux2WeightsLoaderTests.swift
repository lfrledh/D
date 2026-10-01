import Foundation
import MLX
import Darwin
import XCTest
@testable import Flux2

final class Flux2WeightsLoaderTests: XCTestCase {
  func testLoadsComponentWeights() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let componentDir = tempDir.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = componentDir.appendingPathComponent("model.safetensors")
    let values: [Float32] = [5, 6, 7, 8]
    try TestHelpers.writeSafeTensor(
      url: fileURL,
      tensorName: "proj.weight",
      values: values,
      shape: [2, 2]
    )

    let loader = Flux2WeightsLoader(snapshot: tempDir)
    let tensors = try loader.load(component: .transformer, dtype: .float32)
    let tensor = try XCTUnwrap(tensors["proj.weight"])

    XCTAssertEqual(tensor.shape, [2, 2])
    XCTAssertEqual(tensor.asArray(Float32.self), values)
  }

  func testLoadFiltersTensorNames() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let componentDir = tempDir.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try TestHelpers.writeSafeTensor(
      url: componentDir.appendingPathComponent("model-a.safetensors"),
      tensorName: "a.weight",
      values: [1, 2, 3, 4],
      shape: [2, 2]
    )

    try TestHelpers.writeSafeTensor(
      url: componentDir.appendingPathComponent("model-b.safetensors"),
      tensorName: "b.weight",
      values: [9, 10, 11, 12],
      shape: [2, 2]
    )

    let loader = Flux2WeightsLoader(snapshot: tempDir)
    let tensors = try loader.load(component: .transformer, dtype: .float32) { name in
      name == "a.weight"
    }

    XCTAssertEqual(tensors.keys.sorted(), ["a.weight"])
    XCTAssertEqual(tensors["a.weight"]?.asArray(Float32.self), [1, 2, 3, 4])
  }

  func testPinnedSelectionRejectsDuplicateAndWrongDType() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try TestHelpers.writeSafeTensor(url: component.appendingPathComponent("a.safetensors"),
      tensorName: "same.weight", values: [1, 2, 3, 4], shape: [2, 2])
    XCTAssertThrowsError(try Flux2PinnedWeightSelection(snapshot: root, component: .transformer) {
      _, dtype in dtype == .bfloat16
    })
    try TestHelpers.writeSafeTensor(url: component.appendingPathComponent("b.safetensors"),
      tensorName: "same.weight", values: [5, 6, 7, 8], shape: [2, 2])
    XCTAssertThrowsError(try Flux2PinnedWeightSelection(snapshot: root, component: .transformer) {
      _, dtype in dtype == .float32
    }) { error in
      guard case Flux2WeightsLoaderError.duplicateTensor(let name) = error,
            name == "same.weight" else {
        return XCTFail("Expected duplicate key, got \(error)")
      }
    }
  }

  func testPinnedSelectionMatchesIndependentReaderAndRejectsReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = component.appendingPathComponent("block.safetensors")
    try TestHelpers.writeSafeTensor(url: file, tensorName: "block.weight",
      values: [1, 2, 3, 4], shape: [2, 2])
    let source = try Flux2PinnedWeightSelection(snapshot: root, component: .transformer) {
      _, dtype in dtype == .float32
    }
    let expected = try SafeTensorsReader(fileURL: file).tensor(named: "block.weight")
    let actual = try XCTUnwrap(source.load { $0 == "block.weight" }["block.weight"])
    XCTAssertEqual(actual.asArray(Float32.self), expected.asArray(Float32.self))
    try FileManager.default.removeItem(at: file)
    try TestHelpers.writeSafeTensor(url: file, tensorName: "block.weight",
      values: [1, 2, 3, 4], shape: [2, 2])
    XCTAssertThrowsError(try source.verifyFileIdentities())
    XCTAssertThrowsError(try source.load { $0 == "block.weight" })
  }

  func testAdmissionRejectsSameLayoutReplacementBeforeSelectionOpens() throws {
    enum AdmissionError: Error { case changed }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = component.appendingPathComponent("block.safetensors")
    let replacement = component.appendingPathComponent("replacement.tmp")
    try TestHelpers.writeSafeTensor(url: file, tensorName: "block.weight",
      values: [1, 2, 3, 4], shape: [2, 2])
    try TestHelpers.writeSafeTensor(url: replacement, tensorName: "block.weight",
      values: [5, 6, 7, 8], shape: [2, 2])
    var admitted = stat()
    XCTAssertEqual(Darwin.lstat(file.path, &admitted), 0)
    var substituted = stat()
    XCTAssertEqual(Darwin.lstat(replacement.path, &substituted), 0)
    XCTAssertEqual(admitted.st_size, substituted.st_size)
    XCTAssertNotEqual(admitted.st_ino, substituted.st_ino)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: replacement, to: file)

    var inspectedMetadata = false
    let validate: () throws -> Void = {
      var current = stat()
      guard Darwin.lstat(file.path, &current) == 0,
            current.st_dev == admitted.st_dev,
            current.st_ino == admitted.st_ino,
            current.st_size == admitted.st_size else { throw AdmissionError.changed }
    }
    XCTAssertThrowsError(try Flux2PinnedWeightSelection(snapshot: root, component: .transformer,
      admissionValidator: validate) { _, dtype in
        inspectedMetadata = true
        return dtype == .float32
      }) { error in
        guard case AdmissionError.changed = error else {
          return XCTFail("Expected original admission failure, got \(error)")
        }
      }
    XCTAssertFalse(inspectedMetadata, "Replacement must fail before selected tensor metadata or payload is used")
  }

  func testPinnedSelectionHonorsCancellationBeforeTensorRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("transformer")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try TestHelpers.writeSafeTensor(url: component.appendingPathComponent("block.safetensors"),
      tensorName: "block.weight", values: [1, 2, 3, 4], shape: [2, 2])
    let source = try Flux2PinnedWeightSelection(snapshot: root, component: .transformer) {
      _, dtype in dtype == .float32
    }
    let cancelled = await Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try source.load { _ in true }; return false }
      catch is CancellationError { return true }
      catch { return false }
    }.value
    XCTAssertTrue(cancelled)
  }
}
