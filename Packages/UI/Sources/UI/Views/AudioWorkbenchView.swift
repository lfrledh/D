import Foundation
import SwiftUI
import DWorkbench

public struct AudioWorkbenchActions {
    public var importOriginal: () -> Void
    public var startRecording: () -> Void
    public var finishRecording: () -> Void
    public var saveNote: (UUID, String) -> Void
    public var selectClip: (UUID?) -> Void
    public var addClip: (AudioFrameRange, String) -> Void
    public var exportOriginal: () -> Void
    public var exportRange: (AudioFrameRange) -> Void

    public init(importOriginal: @escaping () -> Void, startRecording: @escaping () -> Void,
                finishRecording: @escaping () -> Void, saveNote: @escaping (UUID, String) -> Void,
                selectClip: @escaping (UUID?) -> Void, addClip: @escaping (AudioFrameRange, String) -> Void,
                exportOriginal: @escaping () -> Void, exportRange: @escaping (AudioFrameRange) -> Void) {
        self.importOriginal = importOriginal; self.startRecording = startRecording; self.finishRecording = finishRecording
        self.saveNote = saveNote; self.selectClip = selectClip; self.addClip = addClip
        self.exportOriginal = exportOriginal; self.exportRange = exportRange
    }
}

public struct AudioWorkbenchView: View {
    public let document: AudioDraftDocument?
    public let metadata: AudioAssetMetadata?
    public let waveform: [AudioPeak]
    @Bindable public var transport: AudioTransport
    public let actions: AudioWorkbenchActions
    @State private var note = ""
    @State private var clipName = ""
    @State private var startSeconds = 0.0
    @State private var endSeconds = 0.0
    @State private var editingDocumentID: UUID?
    // Internal, inert when absent: observe actual rendered controls in offscreen layout tests.
    private var layoutProbe: ((String, CGRect) -> Void)?

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self; copy.layoutProbe = observer; return copy
    }

    public init(document: AudioDraftDocument?, metadata: AudioAssetMetadata?, waveform: [AudioPeak],
                transport: AudioTransport, actions: AudioWorkbenchActions) {
        self.document = document; self.metadata = metadata; self.waveform = waveform
        self.transport = transport; self.actions = actions
    }

    public var body: some View {
        Group {
            if let document, let metadata { editor(document: document, metadata: metadata) }
            else { emptyState }
        }
        .padding(20)
        .coordinateSpace(name: "audio-workbench-layout")
        .onChange(of: document?.id) { _, id in load(documentID: id) }
        .onAppear { load(documentID: document?.id) }
        .accessibilityIdentifier("audio-workbench")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("尚未添加音频", systemImage: "waveform")
        } description: { Text("导入原始 WAV/CAF PCM，或由应用明确开始一次录音。") } actions: {
            VStack {
                Button("导入音频…", action: actions.importOriginal).accessibilityIdentifier("audio-import")
                if transport.state == .recording || transport.state == .requestingPermission {
                    Button("结束录音", action: actions.finishRecording).accessibilityIdentifier("audio-record-finish")
                    .audioMeasured("audio-record-finish", probe: layoutProbe)
                } else {
                    Button("开始录音", action: actions.startRecording).accessibilityIdentifier("audio-record-start")
                    .audioMeasured("audio-record-start", probe: layoutProbe)
                }
                Text(statusText).font(.caption).foregroundStyle(transport.state == .failed ? .red : .secondary)
            }
        }
    }

    private func editor(document: AudioDraftDocument, metadata: AudioAssetMetadata) -> some View {
        let format = metadata.format
        return GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(format: format)
                    let layout = viewport.size.width >= 720
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    layout {
                        media(format: format).frame(maxWidth: .infinity).frame(height: 260)
                        details(document: document, format: format)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("audio-editor-scroll")
        }
    }

    private func header(format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("原始音频").font(.title2.weight(.semibold))
                Text("原件保持不变；片段只记录起止位置。\(format.channelCount) 声道 · \(Int(format.sampleRate)) Hz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 126, maximum: 210), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                Button("导出原件", systemImage: "square.and.arrow.up", action: actions.exportOriginal)
                    .buttonStyle(.glass).accessibilityIdentifier("audio-export-original")
                    .audioMeasured("audio-export-original", probe: layoutProbe)
                if transport.state == .recording || transport.state == .requestingPermission {
                    Button(
                        transport.state == .recording ? "结束录音" : "取消等待",
                        systemImage: "stop.fill",
                        action: actions.finishRecording
                    )
                    .buttonStyle(.glass).accessibilityIdentifier("audio-record-finish")
                    .audioMeasured("audio-record-finish", probe: layoutProbe)
                } else {
                    Button("开始录音", systemImage: "mic.fill", action: actions.startRecording)
                        .buttonStyle(.glass).accessibilityIdentifier("audio-record-start")
                    .audioMeasured("audio-record-start", probe: layoutProbe)
                }
            }
        }
        .accessibilityIdentifier("audio-header")
    }

    private func media(format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformView(peaks: waveform, position: transport.positionFrame, frameCount: format.frameCount) { frame in
                do { try transport.seek(toFrame: frame) } catch { transport.present(error) }
            }
                .frame(minHeight: 180).accessibilityIdentifier("audio-waveform")
            HStack {
                Button(transport.state == .playing ? "暂停" : "播放", systemImage: transport.state == .playing ? "pause.fill" : "play.fill") {
                    if transport.state == .playing { transport.pause() } else {
                        do { try transport.play() } catch { transport.present(error) }
                    }
                }.buttonStyle(.glass).accessibilityIdentifier("audio-play-pause")
                Text(time(transport.positionFrame, format: format)).monospacedDigit()
                Spacer()
                Text(statusText).font(.caption)
                    .foregroundStyle(transport.errorMessage == nil ? Color.secondary : Color.red)
                    .accessibilityIdentifier("audio-status")
            }
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func details(document: AudioDraftDocument, format: AudioFormatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("注释与片段").font(.headline)
            TextField("原始媒体注释", text: $note, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("audio-note")
                    .audioMeasured("audio-note", probe: layoutProbe)
            Button("保存注释") {
                guard editingDocumentID == document.id,
                      note.utf8.count <= AudioLimits.maximumNoteBytes else {
                    transport.present(AudioMediaError.limitExceeded)
                    return
                }
                actions.saveNote(document.id, note)
            }
                .accessibilityIdentifier("audio-save-note")
            Divider()
            HStack { TextField("片段名称", text: $clipName).accessibilityIdentifier("audio-clip-name")
                Button("添加片段") {
                    guard editingDocumentID == document.id else { return }
                    guard !clipName.isEmpty,
                          clipName.utf8.count <= AudioLimits.maximumNameBytes,
                          document.clips.count < AudioLimits.maximumClips else {
                        transport.present(AudioMediaError.limitExceeded)
                        return
                    }
                    guard let range = range(format: format) else { return }
                    actions.addClip(range, clipName)
                }.accessibilityIdentifier("audio-add-clip")
                    .audioMeasured("audio-add-clip", probe: layoutProbe) }
            HStack { TextField("开始秒", value: $startSeconds, format: .number).accessibilityIdentifier("audio-range-start")
                TextField("结束秒", value: $endSeconds, format: .number).accessibilityIdentifier("audio-range-end") }
            HStack {
                Button("完整音频") { actions.selectClip(nil) }
                    .accessibilityIdentifier("audio-select-full")
                    .accessibilityAddTraits(document.selectedClipID == nil ? .isSelected : [])
                Button("导出当前范围") {
                    guard editingDocumentID == document.id, let range = range(format: format) else { return }
                    actions.exportRange(range)
                }
                .accessibilityIdentifier("audio-export-range")
            }
            ForEach(document.clips) { clip in
                HStack { Button(clip.name) { guard editingDocumentID == document.id else { return }; actions.selectClip(clip.id) }
                        .accessibilityIdentifier("audio-clip-\(clip.id.uuidString)")
                        .accessibilityAddTraits(document.selectedClipID == clip.id ? .isSelected : [])
                    Spacer(); Text("\(time(clip.range.startFrame, format: format)) – \(time(clip.range.endFrame, format: format))").font(.caption)
                    Button("导出") { guard editingDocumentID == document.id else { return }; actions.exportRange(clip.range) }.accessibilityIdentifier("audio-export-clip-\(clip.id.uuidString)") }
                .audioMeasured("audio-clip-row-\(clip.id.uuidString)", probe: layoutProbe)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusText: String { transport.errorMessage ?? { switch transport.state { case .requestingPermission: "等待录音许可"; case .recording: "正在录音"; case .recorded: "已准备"; default: "" } }() }
    private func load(documentID: UUID?) { editingDocumentID = documentID; note = document?.note ?? ""; clipName = ""; startSeconds = 0; endSeconds = Double(metadata?.format.frameCount ?? 0) / (metadata?.format.sampleRate ?? 1) }
    private func range(format: AudioFormatInfo) -> AudioFrameRange? {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds >= 0,
              startSeconds <= Double(format.frameCount) / format.sampleRate,
              endSeconds <= Double(format.frameCount) / format.sampleRate else {
            transport.present(AudioMediaError.invalidRange); return nil
        }
        let start = Int64((startSeconds * format.sampleRate).rounded(.down))
        let end = Int64((endSeconds * format.sampleRate).rounded(.down))
        guard start < end else { transport.present(AudioMediaError.invalidRange); return nil }
        return AudioFrameRange(startFrame: start, endFrame: end)
    }
    private func time(_ frame: Int64, format: AudioFormatInfo) -> String { String(format: "%.2fs", Double(frame) / format.sampleRate) }
}

private struct WaveformView: View {
    let peaks: [AudioPeak]; let position: Int64; let frameCount: Int64; let seek: (Int64) -> Void
    var body: some View { GeometryReader { proxy in
        Canvas { context, size in
            let count: Int = max(peaks.count, 1)
            let width: CGFloat = size.width / CGFloat(count)
            for (index, peak) in peaks.enumerated() { let x = (CGFloat(index) + 0.5) * width; let top = size.height * (0.5 - CGFloat(peak.maximum) * 0.45); let bottom = size.height * (0.5 - CGFloat(peak.minimum) * 0.45); context.stroke(Path { $0.move(to: CGPoint(x: x, y: top)); $0.addLine(to: CGPoint(x: x, y: bottom)) }, with: .color(.accentColor), lineWidth: max(1, width * 0.55)) }
            if frameCount > 0 { let x = size.width * CGFloat(position) / CGFloat(frameCount); context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.primary), lineWidth: 1) }
        }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { value in
            guard frameCount > 0 else { return }
            let availableWidth: CGFloat = max(proxy.size.width, 1)
            let fraction: Double = min(1, max(0, Double(value.location.x / availableWidth)))
            let frame: Int64 = min(frameCount - 1, max(0, Int64((fraction * Double(frameCount)).rounded(.down))))
            seek(frame)
        })
    } }
}

private extension View {
    func audioMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("audio-workbench-layout"))
        } action: { rectangle in
            probe?(id, rectangle)
        }
    }
}
