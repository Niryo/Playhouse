import SwiftUI

struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var title = ""

    let onCreate: (String) -> Void

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a task")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Give it a clear name. You can move it across the board as work progresses.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("What needs to get done?", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .accessibilityIdentifier("task-title-field")

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancel-task-button")

                Button("Create Task") {
                    onCreate(normalizedTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.34, green: 0.40, blue: 0.86))
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("create-task-button")
            }
        }
        .padding(26)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isTitleFocused = true
        }
    }
}
