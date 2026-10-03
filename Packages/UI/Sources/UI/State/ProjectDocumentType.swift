import UniformTypeIdentifiers

enum ProjectDocumentType {
    static let filenameExtension = "dproject"
    static let package = UTType(filenameExtension: filenameExtension, conformingTo: .package)!
    static let allowedContentTypes = [package]
}
