import Foundation
import Observation

/// 手感参数的唯一来源。视图和窗口层都通过 Observation 自动跟随变化。
@MainActor
@Observable
final class TuningStore {
    static let shared = TuningStore()

    private static let defaultsKey = "animationTuning"

    var tuning: AnimationTuning {
        didSet {
            guard tuning != oldValue else { return }
            save()
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(AnimationTuning.self, from: data) {
            tuning = saved
        } else {
            tuning = .defaults
        }
    }

    func reset() {
        tuning = .defaults
    }

    /// 导出成 JSON，方便把调好的参数发给开发者固化成默认值
    var exportedJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tuning) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tuning) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
