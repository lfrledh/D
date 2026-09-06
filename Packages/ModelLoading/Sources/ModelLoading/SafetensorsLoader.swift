import Foundation
import MLX
import Core  // 虽然当前未使用 Core 中的类型，但保留以备后续可能依赖

/// Utility for loading safetensors files into MLX arrays.
public enum SafetensorsLoader {
    /// Load all tensors from a safetensors file.
    /// - Parameter url: The file URL.
    /// - Returns: A dictionary mapping tensor names to MLXArray.
    /// - Throws: An error if the file cannot be read or parsed.
    nonisolated public static func loadArrays(from url: URL) throws -> [String: MLXArray] {
        let data = try Data(contentsOf: url)
        let (headerData, tensorData) = try parseSafetensors(data: data)

        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        guard let header = header else {
            throw SafetensorsError.invalidHeader
        }

        var arrays: [String: MLXArray] = [:]
        for (key, value) in header {
            guard let metadata = value as? [String: Any],
                  let dtypeStr = metadata["dtype"] as? String,
                  let shape = metadata["shape"] as? [Int],
                  let dataOffsets = metadata["data_offsets"] as? [Int],
                  dataOffsets.count == 2
            else {
                continue // Skip invalid entries
            }

            let start = dataOffsets[0]
            let end = dataOffsets[1]
            let length = end - start
            guard start >= 0, end <= tensorData.count, length >= 0 else {
                throw SafetensorsError.invalidOffsets(key: key)
            }

            let slice = tensorData[start..<end]
            let tensorDataCopy = Data(slice) // Copy to ensure contiguous memory

            // Convert dtype string to MLX DType
            let dtype: DType = try dtypeFromString(dtypeStr)

            // Create MLXArray from data
            let array = MLXArray(tensorDataCopy, shape, dtype: dtype)

            arrays[key] = array
        }
        return arrays
    }

    /// Parse safetensors file data into header JSON and tensor data.
    private static func parseSafetensors(data: Data) throws -> (headerData: Data, tensorData: Data) {
        guard data.count >= 8 else {
            throw SafetensorsError.truncated
        }

        // First 8 bytes are header length as unsigned 64-bit little-endian integer
        let headerLength = data.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }
        let headerLengthInt = Int(headerLength)

        guard data.count >= 8 + headerLengthInt else {
            throw SafetensorsError.truncated
        }

        let headerData = data.subdata(in: 8..<(8 + headerLengthInt))
        let tensorData = data.subdata(in: (8 + headerLengthInt)..<data.count)

        return (headerData, tensorData)
    }

    private static func dtypeFromString(_ str: String) throws -> DType {
        switch str {
        case "F32": return .float32
        case "F16": return .float16
        case "BF16": return .bfloat16
        case "I64": return .int64
        case "I32": return .int32
        case "I16": return .int16
        case "I8": return .int8
        case "U8": return .uint8
        case "U16": return .uint16
        case "U32": return .uint32   // 新增：支持无符号32位整数
        case "U64": return .uint64
        case "BOOL": return .bool
        default: throw SafetensorsError.unsupportedDtype(str)
        }
    }
}

// MARK: - Errors

enum SafetensorsError: Error, LocalizedError {
    case truncated
    case invalidHeader
    case invalidOffsets(key: String)
    case unsupportedDtype(String)

    var errorDescription: String? {
        switch self {
        case .truncated: return "Safetensors file is truncated"
        case .invalidHeader: return "Invalid header JSON"
        case .invalidOffsets(let key): return "Invalid data offsets for tensor: \(key)"
        case .unsupportedDtype(let dtype): return "Unsupported dtype: \(dtype)"
        }
    }
}
