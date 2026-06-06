import Foundation

public struct AsdBehaviorLabel: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isTargetBehavior: Bool

    public init(id: String, name: String, isTargetBehavior: Bool) {
        self.id = id
        self.name = name
        self.isTargetBehavior = isTargetBehavior
    }
}

public struct AsdBehaviorReport: Equatable, Sendable {
    public let labelCode: String
    public let features: [String: Bool]
    public let overall: String

    public var detectedLabels: [AsdBehaviorLabel] {
        AsdBehaviorParser.labels.filter { label in
            label.isTargetBehavior && features[label.id] == true
        }
    }

    public var conclusionTitle: String {
        detectedLabels.isEmpty ? "未注意到明显自闭症倾向类型行为" : "注意到 \(detectedLabels.count) 类可关注行为"
    }

    public var conclusionText: String {
        let names = detectedLabels.map(\.name)
        guard !names.isEmpty else {
            return "本次片段中，未注意到自闭症倾向类型行为。"
        }
        return "本次片段中，注意到一些需要关注的行为表现，例如：\(names.joined(separator: "、"))。这些内容仅描述片段中的可见线索，供后续观察参考。"
    }

    public var jsonString: String {
        let featureJSON = AsdBehaviorParser.featureIDs
            .map { id in
                "\"\(id)\":\(features[id] == true ? "true" : "false")"
            }
            .joined(separator: ",")
        return "{\"schema_version\":\"1.0\",\"features\":{\(featureJSON)},\"overall\":\"\(overall)\"}"
    }
}

public enum AsdBehaviorParser {
    public static let featureIDs = ["B01", "B02", "B03", "B04", "B05", "B06", "B07", "B08", "B09", "B10"]
    public static let labels: [AsdBehaviorLabel] = [
        AsdBehaviorLabel(id: "B01", name: "缺乏或回避眼神接触", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B02", name: "攻击行为", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B03", name: "对感觉输入反应过度或不足", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B04", name: "对言语互动缺乏回应", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B05", name: "非典型语言", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B06", name: "物体排列", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B07", name: "自我击打或自伤行为", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B08", name: "自我旋转或旋转物体", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B09", name: "上肢刻板动作", isTargetBehavior: true),
        AsdBehaviorLabel(id: "B10", name: "背景（无明显目标行为）", isTargetBehavior: false),
    ]

    public static func parse(_ raw: String) -> AsdBehaviorReport? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 9, code.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            return nil
        }

        let predictedIDs = Array(featureIDs.prefix(9))
        let chars = Array(code)
        var features: [String: Bool] = [:]
        var anyObserved = false

        for (index, id) in predictedIDs.enumerated() {
            let observed = chars[index] == "1"
            features[id] = observed
            anyObserved = anyObserved || observed
        }

        features["B10"] = !anyObserved
        return AsdBehaviorReport(
            labelCode: code,
            features: features,
            overall: anyObserved ? "behavior_features_observed" : "background"
        )
    }
}
