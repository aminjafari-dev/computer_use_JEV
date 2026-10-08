import Foundation

public enum ObservationMerger {
    /// IoU above this, plus a compatible label, collapses two observations of the same control.
    public static let mergeIoU = 0.45

    public static func merge(_ groups: [[UIElementObservation]]) -> [UIElementObservation] {
        var kept: [UIElementObservation] = []
        for element in groups.flatMap({ $0 }) {
            if element.isSecure { continue }
            if let index = kept.firstIndex(where: { overlaps($0, element) }) {
                kept[index] = combine(kept[index], element)
            } else {
                kept.append(element)
            }
        }
        return kept
    }

    static func overlaps(_ lhs: UIElementObservation, _ rhs: UIElementObservation) -> Bool {
        let iou = lhs.bounds.iou(rhs.bounds)
        guard iou >= mergeIoU || lhs.bounds.center.distance(to: rhs.bounds.center) < 12 else {
            return false
        }
        return labelsCompatible(lhs.label, rhs.label)
    }

    static func labelsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalize(lhs)
        let b = normalize(rhs)
        if a.isEmpty || b.isEmpty { return true }
        if a == b { return true }
        if a.count >= 3, b.count >= 3, a.contains(b) || b.contains(a) { return true }
        return false
    }

    static func normalize(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func combine(_ preferred: UIElementObservation, _ incoming: UIElementObservation) -> UIElementObservation {
        let incomingWins = rank(incoming) < rank(preferred)
        let winner = incomingWins ? incoming : preferred
        let loser = incomingWins ? preferred : incoming
        var sources = winner.sources
        for source in loser.sources where !sources.contains(source) {
            sources.append(source)
        }
        var merged = winner
        merged.sources = sources
        if merged.label.isEmpty { merged.label = loser.label }
        if merged.supportedActions.isEmpty { merged.supportedActions = loser.supportedActions }
        if merged.parentLabels.isEmpty { merged.parentLabels = loser.parentLabels }
        return merged
    }

    /// Lower is better. Accessibility geometry wins over a detector, which wins over OCR.
    static func rank(_ element: UIElementObservation) -> Int {
        switch element.primarySource {
        case .accessibility: 0
        case .coreML: 1
        case .ocr: 2
        }
    }
}
