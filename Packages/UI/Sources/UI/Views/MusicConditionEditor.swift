import DWorkbench
import Foundation
import SwiftUI

/// Presentation-only editing for the saveable music-condition draft.  Parsing and request
/// construction stay in DWorkbench so partially typed rows are never discarded by the view.
struct MusicConditionEditor: View {
    @Binding var draft: MusicCreationDraft
    let isBusy: Bool
    let importCondition: (() -> Void)?
    let exportCondition: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("使用旋律条件", isOn: $draft.hasNoteCondition)
                .disabled(isBusy)
                .accessibilityIdentifier("audio-create-music-condition-enabled")
            if draft.hasNoteCondition {
                Text("音名（如 C4）或 MIDI 整数／开始秒／持续秒；同一开始时间可组成和弦。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($draft.notes) { $note in
                    noteRow($note)
                }
                HStack {
                    Button("添加音符") { draft.notes.append(MusicNoteDraft()) }
                        .disabled(isBusy || draft.notes.count >= 512)
                        .accessibilityIdentifier("audio-create-music-add-note")
                    Button("示例") { draft = .example }
                        .disabled(isBusy)
                        .accessibilityIdentifier("audio-create-music-example")
                }
                if draft.notes.count >= 512 {
                    Text("最多 512 行音符。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if importCondition != nil || exportCondition != nil {
                HStack {
                    if let importCondition {
                        Button("导入高级条件", action: importCondition).disabled(isBusy)
                            .accessibilityIdentifier("audio-create-music-import")
                    }
                    if let exportCondition {
                        Button("导出高级条件", action: exportCondition).disabled(isBusy)
                            .accessibilityIdentifier("audio-create-music-export")
                    }
                }
            }
        }
        .accessibilityIdentifier("audio-create-music-editor")
    }

    private func noteRow(_ note: Binding<MusicNoteDraft>) -> some View {
        HStack(spacing: 6) {
            TextField("音名或 MIDI", text: note.pitchText).textFieldStyle(.roundedBorder)
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-pitch-\(note.wrappedValue.id.uuidString)")
            TextField("开始秒", text: note.startText).textFieldStyle(.roundedBorder)
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-start-\(note.wrappedValue.id.uuidString)")
            TextField("持续秒", text: note.durationText).textFieldStyle(.roundedBorder)
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-duration-\(note.wrappedValue.id.uuidString)")
            Button("移除") { draft.notes.removeAll { $0.id == note.wrappedValue.id } }
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-remove-\(note.wrappedValue.id.uuidString)")
        }
        .accessibilityIdentifier("audio-create-music-note-\(note.wrappedValue.id.uuidString)")
    }
}
