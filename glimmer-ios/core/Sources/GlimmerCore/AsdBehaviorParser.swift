import Foundation

public struct AsdBehaviorReport: Equatable, Sendable {
    public let labelCode: String
    public let features: [String: Bool]
    public let overall: String

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
