import Foundation
import MLX
import Darwin

public enum Flux2WeightComponent: String, CaseIterable, Sendable {
  case transformer
  case textEncoder = "text_encoder"
  case vae
}

public enum Flux2WeightsLoaderError: Error {
  case componentDirectoryMissing(Flux2WeightComponent, URL)
  case noSafetensorsFound(Flux2WeightComponent, URL)
  case duplicateTensor(String)
  case unexpectedPrecision(String)
  case changedFile(URL)
  case fileNotAdmitted(String)
}

/// Per-load selection supplied by the host's verified manifest. No discovery or
/// global state: an unrelated file cannot change weights, precision, or templates.
public struct Flux2FileSet: Sendable {
  public let paths: Set<String>
  public init(paths: Set<String>) throws {
    guard !paths.isEmpty, paths.allSatisfy({ path in
      !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }) else { throw Flux2WeightsLoaderError.fileNotAdmitted("invalid file set") }
    self.paths = paths
  }
  public func require(_ path: String) throws {
    guard paths.contains(path) else { throw Flux2WeightsLoaderError.fileNotAdmitted(path) }
  }
  public func contains(_ path: String) -> Bool { paths.contains(path) }
}

/// A fixed set of open safetensors readers for one layered model stage. The
/// readers validate their original file identity on every selected tensor read.
/// No unselected tensor data is materialized.
public final class Flux2PinnedWeightSelection {
  private struct Identity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      modifiedSeconds = value.st_mtimespec.tv_sec
      modifiedNanoseconds = value.st_mtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec
      changedNanoseconds = value.st_ctimespec.tv_nsec
    }
  }

  private let readers: [SafeTensorsReader]
  private let locations: [String: SafeTensorsReader]
  private let identities: [URL: Identity]
  private let admissionValidator: (() throws -> Void)?

  public var tensorNames: Set<String> { Set(locations.keys) }

  public init(snapshot: URL, component: Flux2WeightComponent, fileSet: Flux2FileSet? = nil,
              admissionValidator: (() throws -> Void)? = nil,
              allowedDType: (String, DType) -> Bool) throws {
    try admissionValidator?()
    let files = try Flux2WeightsLoader(snapshot: snapshot, fileSet: fileSet).listSafetensors(component: component)
    var opened: [SafeTensorsReader] = []
    var found: [String: SafeTensorsReader] = [:]
    var saved: [URL: Identity] = [:]
    for file in files {
      try Task.checkCancellation()
      try admissionValidator?()
      let reader = try SafeTensorsReader(fileURL: file)
      try admissionValidator?()
      var value = stat()
      guard Darwin.lstat(file.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
        throw Flux2WeightsLoaderError.changedFile(file)
      }
      saved[file] = Identity(value)
      for metadata in reader.allMetadata() {
        guard allowedDType(metadata.name, metadata.dtype) else {
          throw Flux2WeightsLoaderError.unexpectedPrecision(metadata.name)
        }
        guard found.updateValue(reader, forKey: metadata.name) == nil else {
          throw Flux2WeightsLoaderError.duplicateTensor(metadata.name)
        }
      }
      opened.append(reader)
    }
    readers = opened
    locations = found
    identities = saved
    self.admissionValidator = admissionValidator
    try verifyFileIdentities()
  }

  public func load(where include: (String) -> Bool) throws -> [String: MLXArray] {
    try verifyFileIdentities()
    var selected: [String: MLXArray] = [:]
    for name in locations.keys.sorted() where include(name) {
      try Task.checkCancellation()
      try admissionValidator?()
      selected[name] = try locations[name]!.tensor(named: name)
    }
    try verifyFileIdentities()
    return selected
  }

  /// Call after evaluating the selected block, before loading its successor.
  public func verifyFileIdentities() throws {
    try admissionValidator?()
    for reader in readers {
      try Task.checkCancellation()
      var value = stat()
      guard Darwin.lstat(reader.fileURL.path, &value) == 0,
            value.st_mode & S_IFMT == S_IFREG,
            identities[reader.fileURL] == Identity(value) else {
        throw Flux2WeightsLoaderError.changedFile(reader.fileURL)
      }
    }
    try admissionValidator?()
  }
}

public struct Flux2WeightsLoader: Sendable {
  public let snapshot: URL
  public let fileSet: Flux2FileSet?

  public init(snapshot: URL, fileSet: Flux2FileSet? = nil) {
    self.snapshot = snapshot
    self.fileSet = fileSet
  }

  public func listSafetensors(component: Flux2WeightComponent) throws -> [URL] {
    let componentDir = snapshot.appendingPathComponent(component.rawValue)
    guard FileManager.default.fileExists(atPath: componentDir.path) else {
      throw Flux2WeightsLoaderError.componentDirectoryMissing(component, componentDir)
    }

    let contents: [URL]
    if let fileSet {
      contents = fileSet.paths.filter {
        $0.hasPrefix(component.rawValue + "/") && $0.split(separator: "/").count == 2
      }.map { snapshot.appendingPathComponent($0) }
    } else {
      contents = try FileManager.default.contentsOfDirectory(at: componentDir, includingPropertiesForKeys: nil)
    }
    let files = contents.filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else {
      throw Flux2WeightsLoaderError.noSafetensorsFound(component, componentDir)
    }
    return files
  }

  public func load(component: Flux2WeightComponent, dtype: DType? = .bfloat16) throws -> [String: MLXArray] {
    try load(component: component, dtype: dtype, filter: nil)
  }

  public func load(
    component: Flux2WeightComponent,
    dtype: DType? = .bfloat16,
    filter: ((String) -> Bool)?
  ) throws -> [String: MLXArray] {
    let files = try listSafetensors(component: component)
    var tensors: [String: MLXArray] = [:]
    for url in files {
      let fileTensors = try loadArrays(url: url, stream: .cpu)
      let tensorNames = Set(fileTensors.keys)
      for (name, value) in fileTensors {
        if let filter, !filter(name) {
          continue
        }
        var tensor = value
        if let dtype,
           tensor.dtype != dtype,
           shouldCastLoadedTensor(name: name, tensorDType: tensor.dtype, targetDType: dtype, availableNames: tensorNames) {
          tensor = tensor.asType(dtype, stream: .cpu)
        }
        if fileSet != nil, tensors[name] != nil {
          throw Flux2WeightsLoaderError.duplicateTensor(name)
        }
        tensors[name] = tensor
      }
    }
    return tensors
  }

  private func shouldCastLoadedTensor(
    name: String,
    tensorDType: DType,
    targetDType: DType,
    availableNames: Set<String>
  ) -> Bool {
    guard isFloatingDType(tensorDType) else { return false }
    guard targetDType != tensorDType else { return false }

    guard Flux2Quantizer.hasQuantization(at: snapshot, fileSet: fileSet) else {
      return true
    }

    if name.hasSuffix(".scales") || name.hasSuffix(".biases") {
      return false
    }
    if name.hasSuffix(".weight") {
      let base = String(name.dropLast(".weight".count))
      if availableNames.contains("\(base).scales") {
        return false
      }
    }
    return true
  }

  private func isFloatingDType(_ dtype: DType) -> Bool {
    switch dtype {
    case .float16, .float32, .float64, .bfloat16:
      return true
    default:
      return false
    }
  }

  public func loadAll(dtype: DType? = .bfloat16) throws -> [String: MLXArray] {
    var tensors: [String: MLXArray] = [:]
    for component in Flux2WeightComponent.allCases {
      let componentTensors = try load(component: component, dtype: dtype)
      for (key, value) in componentTensors {
        tensors["\(component.rawValue).\(key)"] = value
      }
    }
    return tensors
  }
}
