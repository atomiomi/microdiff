/// How the name and the branch of a repository row share one line: whichever needs more than half of the room
/// is shortened in the middle, the other keeps as much as it can use.
package enum RepoRowText {
    /// What is drawn for a row.
    package struct Fit: Equatable {
        package var name: String
        package var branch: String
        /// Either side was cut.
        package var isShortened: Bool

        package init(name: String, branch: String, isShortened: Bool) {
            self.name = name
            self.branch = branch
            self.isShortened = isShortened
        }
    }

    /// The widths the name and the branch may take out of `budget`. Both in full when they fit together; else each is
    /// guaranteed half, and a side that needs less than half gives the rest to the other.
    package static func shares(budget: Double, name: Double, branch: Double) -> (name: Double, branch: Double) {
        let budget = max(0, budget)
        if name + branch <= budget { return (name, branch) }
        let half = budget / 2
        if name <= half { return (name, budget - name) }
        if branch <= half { return (budget - branch, branch) }
        return (half, half)
    }

    /// `text` cut in the middle with one "…" so that it is at most `width` wide, keeping the start and the end (the
    /// start has the extra character when the kept count is odd). Whole characters only. When not even "…" fits: "".
    /// `measure` is the width of a string as drawn.
    package static func shortened(_ text: String, to width: Double, measure: (String) -> Double) -> String {
        let full = measure(text)
        if full <= width { return text }
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }
        func candidate(_ kept: Int) -> String {
            let head = (kept + 1) / 2
            return String(characters[..<head]) + "…" + String(characters[(characters.count - (kept - head))...])
        }
        func fits(_ kept: Int) -> Bool { measure(candidate(kept)) <= width }
        // Every character kept makes the result wider, so the most that fits is a step or two from a first guess
        // (the average character width); trying every length would measure dozens of strings per row.
        let average = full / Double(characters.count)
        let guess = average > 0 ? min(max(0, width / average), Double(characters.count)) : 0
        var kept = min(characters.count - 1, Int(guess))
        if fits(kept) {
            while kept + 1 < characters.count, fits(kept + 1) { kept += 1 }
            return candidate(kept)
        }
        while kept > 0 {
            kept -= 1
            if fits(kept) { return candidate(kept) }
        }
        return ""
    }

    /// The strings to draw for a name and a branch in `budget` points. Each side has its own `measure`.
    package static func fit(
        name: String, branch: String, budget: Double, measureName: (String) -> Double, measureBranch: (String) -> Double
    ) -> Fit {
        let shares = shares(budget: budget, name: measureName(name), branch: measureBranch(branch))
        let shortName = shortened(name, to: shares.name, measure: measureName)
        let shortBranch = shortened(branch, to: shares.branch, measure: measureBranch)
        return Fit(name: shortName, branch: shortBranch, isShortened: shortName != name || shortBranch != branch)
    }
}
