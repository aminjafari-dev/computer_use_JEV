import Foundation

public struct CandidateBuildResult: Sendable, Equatable {
    public var candidates: [Candidate]
    /// Disabled controls described to the model but not executable.
    public var unavailableLabels: [String]
}

public struct CandidateBuilder: Sendable {
    /// Hard cap. Choice allows 255 options; one slot is reserved for "none of these".
    public var maxCandidates: Int
    /// When no label matches the task, keep this many reading-order controls instead of the full tree.
    public var unmatchedFallbackCount: Int

    public init(maxCandidates: Int = 120, unmatchedFallbackCount: Int = 40) {
        self.maxCandidates = min(maxCandidates, 254)
        self.unmatchedFallbackCount = unmatchedFallbackCount
    }

    public func build(
        observation: ScreenObservation,
        task: String,
        userTextAvailable: Bool
    ) -> CandidateBuildResult {
        let window = Self.windowBounds(observation.elements)

        var unavailable: [String] = []
        var executable: [(score: Int, reading: Int, candidate: Candidate)] = []
        let tokens = Tokenizer.tokens(task)

        for (index, element) in observation.elements.enumerated() {
            if element.isSecure {
                unavailable.append(element.label.isEmpty ? "Secure field" : element.label)
                continue
            }
            let ops = operations(for: element, userTextAvailable: userTextAvailable)
            if !element.enabled {
                if !element.label.isEmpty {
                    unavailable.append("\(element.label) (disabled)")
                }
                continue
            }
            guard !ops.isEmpty else { continue }
            let region = regionWord(for: element.bounds, in: window)
            let score = relevance(element: element, operations: ops, tokens: tokens)
            for operation in ops {
                let draft = Candidate(
                    id: "",
                    label: sanitize(element.label.isEmpty ? element.role : element.label),
                    controlType: element.role,
                    enabled: true,
                    bounds: element.bounds,
                    center: element.bounds.center,
                    operation: operation.operation,
                    source: element.primarySource,
                    contextLabels: element.parentLabels.map(sanitize).prefix(3).map { $0 },
                    elementID: element.id,
                    navigationKey: operation.key,
                    region: region
                )
                executable.append((score, index, draft))
            }
        }

        executable.append(contentsOf: globalKeys(tokens: tokens))

        let matched = executable.filter { $0.score > 0 }
        let pool = matched.isEmpty ? Array(executable.sorted(by: readingOrder).prefix(unmatchedFallbackCount)) : executable
        let ranked = pool.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.label != rhs.candidate.label { return lhs.candidate.label < rhs.candidate.label }
            if lhs.candidate.bounds.y != rhs.candidate.bounds.y { return lhs.candidate.bounds.y < rhs.candidate.bounds.y }
            return lhs.candidate.bounds.x < rhs.candidate.bounds.x
        }

        var seen = Set<String>()
        var chosen: [Candidate] = []
        for item in ranked {
            let key = "\(item.candidate.elementID)|\(item.candidate.operation.rawValue)|\(item.candidate.navigationKey?.rawValue ?? "")"
            guard seen.insert(key).inserted else { continue }
            var candidate = item.candidate
            candidate.id = "c\(chosen.count + 1)"
            chosen.append(candidate)
            if chosen.count >= maxCandidates { break }
        }
        return CandidateBuildResult(candidates: chosen, unavailableLabels: unavailable)
    }

    private func readingOrder(_ lhs: (score: Int, reading: Int, candidate: Candidate), _ rhs: (score: Int, reading: Int, candidate: Candidate)) -> Bool {
        if lhs.reading != rhs.reading { return lhs.reading < rhs.reading }
        return lhs.candidate.operation.rawValue < rhs.candidate.operation.rawValue
    }

    private struct Op {
        var operation: Operation
        var key: NavigationKey?
    }

    private func operations(for element: UIElementObservation, userTextAvailable: Bool) -> [Op] {
        let role = element.role
        let actions = Set(element.supportedActions)
        var ops: [Op] = []
        let clickableRoles: Set<String> = [
            "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXTab", "AXCell", "AXImage", "AXRow", "AXOutlineRow", "AXStaticText",
            "AXDisclosureTriangle", "AXIncrementor", "AXToolbarButton", "OCRText", "DetectedControl"
        ]
        if actions.contains("AXPress") || clickableRoles.contains(role) {
            ops.append(Op(operation: .click, key: nil))
        }
        if role == "AXRow" || role == "AXOutlineRow" || role == "AXImage" {
            ops.append(Op(operation: .doubleClick, key: nil))
        }
        if actions.contains("AXShowMenu") || role == "AXMenuButton" {
            ops.append(Op(operation: .rightClick, key: nil))
        }
        let scrollRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXTextArea"]
        if scrollRoles.contains(role) || actions.contains("AXScrollUpByPage") || actions.contains("AXScrollDownByPage") {
            ops.append(Op(operation: .scrollUp, key: nil))
            ops.append(Op(operation: .scrollDown, key: nil))
        }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        if userTextAvailable, !element.isSecure, textRoles.contains(role) {
            ops.append(Op(operation: .insertText, key: nil))
        }
        return ops
    }

    private func globalKeys(tokens: Set<String>) -> [(score: Int, reading: Int, candidate: Candidate)] {
        NavigationKey.allCases.enumerated().map { index, key in
            let candidate = Candidate(
                id: "",
                label: "Press \(key.displayName)",
                controlType: "key",
                enabled: true,
                bounds: Rect(x: 0, y: 0, width: 0, height: 0),
                center: Point(x: 0, y: 0),
                operation: .pressKey,
                source: .accessibility,
                contextLabels: [],
                elementID: "key:\(key.rawValue)",
                navigationKey: key,
                region: "keyboard"
            )
            let name = Tokenizer.tokens(key.displayName)
            var score = 0
            if !name.isDisjoint(with: tokens) { score += 8 }
            if tokens.contains("press") || tokens.contains("key") || tokens.contains("keyboard") { score += 2 }
            return (score, 10_000 + index, candidate)
        }
    }

    private func relevance(element: UIElementObservation, operations: [Op], tokens: Set<String>) -> Int {
        var score = 0
        let labelTokens = Tokenizer.tokens(element.label + " " + element.parentLabels.joined(separator: " ") + " " + element.role)
        score += labelTokens.intersection(tokens).count * 10
        if !element.label.isEmpty { score += 1 }
        if operations.contains(where: { $0.operation == .click }) { score += 1 }
        return score
    }

    private func regionWord(for bounds: Rect, in window: Rect) -> String {
        guard window.width > 1, window.height > 1 else { return "center" }
        let nx = (bounds.center.x - window.minX) / window.width
        let ny = (bounds.center.y - window.minY) / window.height
        let vertical = ny < 0.33 ? "top" : (ny > 0.66 ? "bottom" : "middle")
        let horizontal = nx < 0.33 ? "left" : (nx > 0.66 ? "right" : "center")
        return "\(vertical)-\(horizontal)"
    }

    private static func windowBounds(_ elements: [UIElementObservation]) -> Rect {
        guard let first = elements.first else { return Rect(x: 0, y: 0, width: 1, height: 1) }
        return elements.dropFirst().reduce(first.bounds) { partial, element in
            let x = min(partial.minX, element.bounds.minX)
            let y = min(partial.minY, element.bounds.minY)
            let maxX = max(partial.maxX, element.bounds.maxX)
            let maxY = max(partial.maxY, element.bounds.maxY)
            return Rect(x: x, y: y, width: maxX - x, height: maxY - y)
        }
    }

    private func sanitize(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 80 { return cleaned }
        return String(cleaned.prefix(79)) + "…"
    }
}

enum Tokenizer {
    static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count > 1 })
    }
}
