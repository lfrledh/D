import Foundation
import Testing
import UniformTypeIdentifiers
@testable import UI

@Suite("D project document type")
struct ProjectDocumentTypeTests {
    @Test func productionFilterSelectsOnlyProjectPackages() throws {
        let project = try #require(ProjectDocumentType.allowedContentTypes.first)

        #expect(project.conforms(to: .package))
        #expect(project.preferredFilenameExtension == ProjectDocumentType.filenameExtension)
        #expect(ProjectDocumentType.allowedContentTypes == [project])
        #expect(!UTType.png.conforms(to: project))
        #expect(!UTType.folder.conforms(to: project))
    }

    @Test func exportedDeclarationMatchesPackageFilterWhenRegistered() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("D/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let exports = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let exportedIdentifier = "com.lfrledh.d.project"
        let declaration = try #require(exports.first { $0["UTTypeIdentifier"] as? String == exportedIdentifier })
        let parents = try #require(declaration["UTTypeConformsTo"] as? [String])
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try #require(tags["public.filename-extension"] as? [String])

        #expect(parents.contains(UTType.package.identifier))
        #expect(extensions.contains(ProjectDocumentType.filenameExtension))
        if !ProjectDocumentType.package.isDynamic {
            #expect(ProjectDocumentType.package.identifier == exportedIdentifier)
        }
    }
}
