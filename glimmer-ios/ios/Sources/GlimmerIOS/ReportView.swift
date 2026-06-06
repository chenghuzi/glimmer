import SwiftUI
import GlimmerCore

// MARK: - 报告视图

struct ReportView: View {
    let raw: String

    var body: some View {
        if let report = report(from: raw) {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard(report)
                detectedSection(report)
                checklistSection(report)
            }
        } else {
            // 解析/校验失败：不展示原始文本，给出明确提示
            VStack(alignment: .leading, spacing: 8) {
                Text("结果解析失败")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ASDTheme.ink)
                Text("模型本次未返回合法的结构化结果，请重试或更换视频片段。")
                    .font(.system(size: 13))
                    .foregroundStyle(ASDTheme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func report(from raw: String) -> AsdBehaviorReport? {
        if let report = AsdBehaviorParser.parse(raw) {
            return report
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [String: Bool] else {
            return nil
        }
        let code = AsdBehaviorParser.featureIDs.prefix(9).map { id in
            features[id] == true ? "1" : "0"
        }.joined()
        return AsdBehaviorParser.parse(code)
    }

    // 顶部总结
    private func summaryCard(_ report: AsdBehaviorReport) -> some View {
        let n = report.detectedLabels.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: n == 0 ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(n == 0 ? Color(hex: 0x2FA36B) : Color(hex: 0xE5853D))
                Text(report.conclusionTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ASDTheme.ink)
            }
            Text(report.conclusionText)
                .font(.system(size: 13))
                .foregroundStyle(ASDTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    // 检测到的行为特征
    @ViewBuilder
    private func detectedSection(_ report: AsdBehaviorReport) -> some View {
        if !report.detectedLabels.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("观察到的行为特征")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ASDTheme.subtle)
                    .textCase(.uppercase)
                ForEach(report.detectedLabels) { f in
                    HStack(alignment: .center, spacing: 10) {
                        Circle().fill(Color(hex: 0xE5853D)).frame(width: 8, height: 8)
                        Text(f.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ASDTheme.ink)
                        Spacer()
                        Text(f.id).font(.system(size: 12, weight: .medium)).foregroundStyle(ASDTheme.subtle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // 完整 10 项清单
    private func checklistSection(_ report: AsdBehaviorReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("完整观察项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ASDTheme.subtle)
                .textCase(.uppercase)
            ForEach(AsdBehaviorParser.labels) { f in
                let on = report.features[f.id] == true
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(on ? (f.isTargetBehavior ? Color(hex: 0xE5853D) : Color(hex: 0x8A8A82))
                                            : Color(hex: 0xCFCFC7))
                    Text(f.name)
                        .font(.system(size: 14))
                        .foregroundStyle(on ? ASDTheme.ink : ASDTheme.subtle)
                    Spacer()
                    Text(f.id).font(.system(size: 11)).foregroundStyle(ASDTheme.subtle.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
