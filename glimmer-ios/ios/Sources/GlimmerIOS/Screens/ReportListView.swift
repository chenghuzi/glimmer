import SwiftUI

struct ReportListView: View {
    var store: ReportConversationStore
    var onOpen: (ReportConversationRecord) -> Void = { _ in }
    var onSelectAnalyze: () -> Void = {}

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if store.records.isEmpty {
                    emptyState
                } else {
                    recordsList
                }

                Text("分析与对话全程在设备本地完成")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Color(hex: 0x666664))
                    .padding(.top, 4)

                GlimmerTabBar(active: .report) { tab in
                    if tab == .analyze { onSelectAnalyze() }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var header: some View {
        HStack {
            Text("报告")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GTheme.ink)
            Spacer()
        }
        .padding(.top, 68)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("暂无分析报告")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(GTheme.ink)
            Text("完成一次视频分析后，结果会显示在这里。")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(GTheme.subtle)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordsList: some View {
        List {
            ForEach(store.records) { record in
                ReportRow(record: record)
                    .contentShape(RoundedRectangle(cornerRadius: 24))
                    .onTapGesture { onOpen(record) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.delete(record)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}

private struct ReportRow: View {
    let record: ReportConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(record.timestamp)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(GTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Text(record.videoDuration)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(GTheme.subtle)
            }

            Text(record.conclusion)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(GTheme.inkSecondary)
                .lineSpacing(5)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GTheme.onInk)
                    .frame(width: 24, height: 24)
                    .background(GTheme.ink, in: Circle())

                Text(record.videoTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GTheme.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GTheme.faint)
            }
        }
        .padding(18)
        .background(GTheme.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
    }
}

#Preview {
    ReportListView(store: ReportConversationStore())
}
