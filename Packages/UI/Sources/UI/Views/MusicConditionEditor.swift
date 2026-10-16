import DWorkbench
import Foundation
import SwiftUI

/// Presentation-only editing for the saveable music-condition draft.  Parsing and request
/// construction stay in DWorkbench so partially typed rows are never discarded by the view.
struct MusicConditionEditor: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    @Binding var draft: MusicCreationDraft
    let isBusy: Bool
    let importCondition: (() -> Void)?
    let exportCondition: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(consistencyText(consistencyLanguage, "remaining.65b2cc5e64d7"), isOn: $draft.hasNoteCondition)
                .disabled(isBusy)
                .accessibilityIdentifier("audio-create-music-condition-enabled")
            if draft.hasNoteCondition {
                Text(consistencyText(consistencyLanguage, "remaining.67af9b023180"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($draft.notes) { $note in
                    noteRow($note)
                }
                HStack {
                    Button(consistencyText(consistencyLanguage, "remaining.27c9b1735f9e")) { draft.notes.append(MusicNoteDraft()) }
                        .disabled(isBusy || draft.notes.count >= 512)
                        .accessibilityIdentifier("audio-create-music-add-note")
                    Button(consistencyText(consistencyLanguage, "remaining.0d53f08678d8")) { draft = .example }
                        .disabled(isBusy)
                        .accessibilityIdentifier("audio-create-music-example")
                }
                if draft.notes.count >= 512 {
                    Text(consistencyText(consistencyLanguage, "remaining.43cf4c9e90f5"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if importCondition != nil || exportCondition != nil {
                HStack {
                    if let importCondition {
                        Button(consistencyText(consistencyLanguage, "remaining.03cb2fd6329e"), action: importCondition).disabled(isBusy)
                            .accessibilityIdentifier("audio-create-music-import")
                    }
                    if let exportCondition {
                        Button(consistencyText(consistencyLanguage, "remaining.d2d09d5d32b2"), action: exportCondition).disabled(isBusy)
                            .accessibilityIdentifier("audio-create-music-export")
                    }
                }
            }
        }
        .accessibilityIdentifier("audio-create-music-editor")
    }

    private func noteRow(_ note: Binding<MusicNoteDraft>) -> some View {
        HStack(spacing: 6) {
            TextField(consistencyText(consistencyLanguage, "remaining.32363e42432e"), text: note.pitchText).textFieldStyle(WorkbenchGlassTextFieldStyle())
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-pitch-\(note.wrappedValue.id.uuidString)")
            TextField(consistencyText(consistencyLanguage, "remaining.fee2076675e1"), text: note.startText).textFieldStyle(WorkbenchGlassTextFieldStyle())
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-start-\(note.wrappedValue.id.uuidString)")
            TextField(consistencyText(consistencyLanguage, "remaining.692f572654d7"), text: note.durationText).textFieldStyle(WorkbenchGlassTextFieldStyle())
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-duration-\(note.wrappedValue.id.uuidString)")
            Button(consistencyText(consistencyLanguage, "remaining.6135d4159e89")) { draft.notes.removeAll { $0.id == note.wrappedValue.id } }
                .disabled(isBusy).accessibilityIdentifier("audio-create-music-remove-\(note.wrappedValue.id.uuidString)")
        }
        .accessibilityIdentifier("audio-create-music-note-\(note.wrappedValue.id.uuidString)")
    }
}
