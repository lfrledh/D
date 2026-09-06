import Foundation

public enum ModelLoadingError: Error, LocalizedError {
    case directoryNotFound(URL)
    case configNotFound(URL)
    case configParseFailed(underlying: String)
    case noWeightsFound(URL)
    case unsupportedArchitecture(String)
    case weightLoadFailed(String)
    case adapterCreationFailed(String)
    case tokenizerLoadFailed(String)
    case activeDownloadExists
    case invalidModelFolder(String)  // 新增：模型文件夹名无法提取模型ID
    case imageServiceFactoryNotSet   // 新增：未设置图像服务工厂闭包

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let url):
            return "Directory not found: \(url.path)"
        case .configNotFound(let url):
            return "config.json not found in: \(url.path)"
        case .configParseFailed(let details):
            return "Failed to parse config.json: \(details)"
        case .noWeightsFound(let url):
            return "No .safetensors files found in: \(url.path)"
        case .unsupportedArchitecture(let arch):
            return "Unsupported model architecture: \(arch)"
        case .weightLoadFailed(let details):
            return "Failed to load weights: \(details)"
        case .adapterCreationFailed(let details):
            return "Failed to create model adapter: \(details)"
        case .tokenizerLoadFailed(let details):
            return "Failed to load tokenizer: \(details)"
        case .activeDownloadExists:
            return "A download is already in progress. Please wait or cancel it first."
        case .invalidModelFolder(let reason):
            return "Invalid model folder: \(reason)"
        case .imageServiceFactoryNotSet:
            return "Image service factory is not configured. Please set imageServiceFactory on ModelLoadingActor."
        }
    }
}
