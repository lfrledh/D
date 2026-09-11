import AppKit
import DWorkbench
import Foundation
import UniformTypeIdentifiers

public enum AudioWorkbenchIsolation {
    public static func isEnabled(environment: [String: String]) -> Bool {
        #if DEBUG
        guard environment["D_AUDIO_WORKBENCH_TEST"] == "1",
              let token = environment["D_UI_TEST_SESSION"],
              UUID(uuidString: token) != nil else { return false }
        return true
        #else
        return false
        #endif
    }
}

public enum AudioExportPanelKind: Equatable, Sendable {
    case original(AudioContainer)
    case float32WAVRange

    var filenameExtension: String {
        switch self {
        case .original(.wav), .float32WAVRange: "wav"
        case .original(.caf): "caf"
        }
    }
}

public struct AudioExportPanelRequest: Equatable, Sendable {
    public let kind: AudioExportPanelKind
    public let suggestedName: String
    public let title: String
    public let explanation: String

    public init(kind: AudioExportPanelKind, suggestedName: String,
                title: String, explanation: String) {
        self.kind = kind
        self.suggestedName = suggestedName
        self.title = title
        self.explanation = explanation
    }
}

@MainActor
public protocol AudioWorkbenchPanelProviding: AnyObject {
    func chooseAudioImport() async -> URL?
    func chooseAudioExport(_ request: AudioExportPanelRequest) async -> URL?
}

@MainActor
public final class NativeAudioWorkbenchPanels: AudioWorkbenchPanelProviding {
    public init() {}

    public func chooseAudioImport() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入原始 WAV 或 CAF PCM"
        panel.message = "只会读取所选的一个文件，并将受支持的原声登记到当前项目。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "caf"].compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    public func chooseAudioExport(_ request: AudioExportPanelRequest) async -> URL? {
        let panel = NSSavePanel()
        panel.title = request.title
        panel.message = request.explanation
        panel.nameFieldStringValue = request.suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: request.kind.filenameExtension) {
            panel.allowedContentTypes = [type]
        }
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}

public struct AudioWorkbenchProductionActions {
    public var importOriginal: () -> Void
    public var startRecording: () -> Void
    public var finishRecording: () -> Void
    public var refreshInspection: (UUID, UUID) async -> Bool
    public var saveNote: (UUID, UUID) async -> Bool
    public var addClip: (UUID, UUID) async -> Bool
    public var discardInput: (UUID, UUID) -> Bool
    public var selectClip: (UUID?, UUID, UUID) async -> Bool
    public var prepareRange: (AudioFrameRange, UUID, UUID) async -> Bool
    public var exportOriginal: (UUID, UUID) -> Void
    public var exportSavedClip: (UUID, UUID, UUID) -> Void
    public var exportRange: (AudioFrameRange, UInt64, UUID, UUID) -> Void
    public var retryCapture: (UUID, UUID, UUID?) -> Void
    public var keepCapture: (UUID, UUID, UUID?) -> Void

    public init(importOriginal: @escaping () -> Void,
                startRecording: @escaping () -> Void,
                finishRecording: @escaping () -> Void,
                refreshInspection: @escaping (UUID, UUID) async -> Bool,
                saveNote: @escaping (UUID, UUID) async -> Bool,
                addClip: @escaping (UUID, UUID) async -> Bool,
                discardInput: @escaping (UUID, UUID) -> Bool,
                selectClip: @escaping (UUID?, UUID, UUID) async -> Bool,
                prepareRange: @escaping (AudioFrameRange, UUID, UUID) async -> Bool,
                exportOriginal: @escaping (UUID, UUID) -> Void,
                exportSavedClip: @escaping (UUID, UUID, UUID) -> Void,
                exportRange: @escaping (AudioFrameRange, UInt64, UUID, UUID) -> Void,
                retryCapture: @escaping (UUID, UUID, UUID?) -> Void,
                keepCapture: @escaping (UUID, UUID, UUID?) -> Void) {
        self.importOriginal = importOriginal
        self.startRecording = startRecording
        self.finishRecording = finishRecording
        self.refreshInspection = refreshInspection
        self.saveNote = saveNote
        self.addClip = addClip
        self.discardInput = discardInput
        self.selectClip = selectClip
        self.prepareRange = prepareRange
        self.exportOriginal = exportOriginal
        self.exportSavedClip = exportSavedClip
        self.exportRange = exportRange
        self.retryCapture = retryCapture
        self.keepCapture = keepCapture
    }
}
