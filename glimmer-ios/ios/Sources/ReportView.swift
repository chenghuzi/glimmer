import SwiftUI

// MARK: - 行为标签定义（B01–B10）

struct BehaviorFeature: Identifiable {
    let id: String          // B01...
    let name: String        // 中文名
    let concerning: Bool     // 是否属于需关注的目标行为（B10 背景不算）
}

let behaviorFeatures: [BehaviorFeature] = [
    .init(id: "B01", name: "缺乏或回避眼神接触", concerning: true),
    .init(id: "B02", name: "攻击行为", concerning: true),
    .init(id: "B03", name: "对感觉输入反应过度或不足", concerning: true),
    .init(id: "B04", name: "对言语互动缺乏回应", concerning: true),
    .init(id: "B05", name: "非典型语言", concerning: true),
    .init(id: "B06", name: "物体排列", concerning: true),
    .init(id: "B07", name: "自我击打或自伤行为", concerning: true),
    .init(id: "B08", name: "自我旋转或旋转物体", concerning: true),
    .init(id: "B09", name: "上肢刻板动作", concerning: true),
    .init(id: "B10", name: "背景（无明显目标行为）", concerning: false),
]

// MARK: - 严格 JSON 解析 + 校验

struct ScreeningReport {
    let features: [String: Bool]   // B01...B10 → bool
    let overall: String

    /// 检测到的需关注行为（B01–B09 中为 true 的）
    var detected: [BehaviorFeature] {
        behaviorFeatures.filter { $0.concerning && features[$0.id] == true }
    }

    /// 从模型输出里抽取并严格校验 JSON。校验不通过返回 nil。
    static func parse(_ raw: String) -> ScreeningReport? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "```") {                 // 去 markdown 围栏
            s = String(s[r.upperBound...])
            if s.lowercased().hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let end = s.range(of: "```") { s = String(s[..<end.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end,
              let data = String(s[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // schema_version 必须是 "1.0"
        guard (obj["schema_version"] as? String) == "1.0" else { return nil }
        // features 必须且只能包含 B01–B10，且都是 bool
        guard let rawFeatures = obj["features"] as? [String: Any] else { return nil }
        var features: [String: Bool] = [:]
        for f in behaviorFeatures {
            guard let v = rawFeatures[f.id] as? Bool else { return nil }
            features[f.id] = v
        }
        guard rawFeatures.count == behaviorFeatures.count else { return nil }
        guard let overall = obj["overall"] as? String else { return nil }
        return ScreeningReport(features: features, overall: overall)
    }
}

// MARK: - 报告视图

struct ReportView: View {
    let raw: String

    var body: some View {
        if let report = ScreeningReport.parse(raw) {
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

    // 顶部总结
    private func summaryCard(_ report: ScreeningReport) -> some View {
        let n = report.detected.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: n == 0 ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(n == 0 ? Color(hex: 0x2FA36B) : Color(hex: 0xE5853D))
                Text(n == 0 ? "未观察到明显目标行为特征" : "观察到 \(n) 项可关注的行为特征")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ASDTheme.ink)
            }
            Text("检测到的为可观察行为特征，需要结合更多场景和专业评估理解，本结果仅作筛查支持，不构成诊断。")
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
    private func detectedSection(_ report: ScreeningReport) -> some View {
        if !report.detected.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("观察到的行为特征")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ASDTheme.subtle)
                    .textCase(.uppercase)
                ForEach(report.detected) { f in
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
    private func checklistSection(_ report: ScreeningReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("完整观察项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ASDTheme.subtle)
                .textCase(.uppercase)
            ForEach(behaviorFeatures) { f in
                let on = report.features[f.id] == true
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(on ? (f.concerning ? Color(hex: 0xE5853D) : Color(hex: 0x8A8A82))
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
