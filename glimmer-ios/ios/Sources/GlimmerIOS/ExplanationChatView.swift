import SwiftUI

struct ExplanationChatView: View {
    @Binding var draft: String
    let isReady: Bool
    let isResponding: Bool
    let onSend: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("可以和我聊聊", text: $draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .disabled(!isReady || isResponding)
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? ASDTheme.ink : ASDTheme.ink.opacity(0.25), in: Circle())
                }
                .disabled(!canSend)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)

            Text("分析与对话全程在设备本地完成")
                .font(.system(size: 12))
                .foregroundStyle(ASDTheme.subtle)
        }
    }

    private var canSend: Bool {
        isReady && !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }
        draft = ""
        onSend(text)
    }
}
