import MicroDiffCore
import Testing

@Suite("RepoRowText")
struct RepoRowTextTests {
    /// One point per character, two for wide ones (CJK and emoji).
    private func width(_ text: String) -> Double {
        text.reduce(0) { total, character in
            total + (character.unicodeScalars.contains { $0.value >= 0x2E80 } ? 2 : 1)
        }
    }

    // MARK: Splitting the budget

    @Test func bothInFullWhenTheyFitTogether() {
        let shares = RepoRowText.shares(budget: 30, name: 10, branch: 20)
        #expect(shares.name == 10 && shares.branch == 20)
    }

    @Test func aShortNameKeepsItsWidthAndTheBranchGetsTheRest() {
        let shares = RepoRowText.shares(budget: 30, name: 8, branch: 40)
        #expect(shares.name == 8 && shares.branch == 22)
    }

    @Test func aShortBranchKeepsItsWidthAndTheNameGetsTheRest() {
        let shares = RepoRowText.shares(budget: 30, name: 40, branch: 5)
        #expect(shares.name == 25 && shares.branch == 5)
    }

    @Test func whenBothNeedMoreThanHalfEachGetsHalf() {
        let shares = RepoRowText.shares(budget: 30, name: 40, branch: 50)
        #expect(shares.name == 15 && shares.branch == 15)
    }

    @Test func exactlyHalfCountsAsShort() {
        let shares = RepoRowText.shares(budget: 30, name: 15, branch: 50)
        #expect(shares.name == 15 && shares.branch == 15)
    }

    @Test func aTinyBudgetStillSplitsByTheSameRule() {
        let shares = RepoRowText.shares(budget: 3, name: 40, branch: 50)
        #expect(shares.name == 1.5 && shares.branch == 1.5)
    }

    @Test func aZeroOrNegativeBudgetGivesNothing() {
        for budget in [0.0, -12] {
            let shares = RepoRowText.shares(budget: budget, name: 4, branch: 4)
            #expect(shares.name == 0 && shares.branch == 0)
        }
        let empty = RepoRowText.shares(budget: 0, name: 0, branch: 0)
        #expect(empty.name == 0 && empty.branch == 0)
    }

    // MARK: Shortening in the middle

    @Test func aStringThatFitsStaysAsItIs() {
        #expect(RepoRowText.shortened("abcdef", to: 6, measure: width) == "abcdef")
        #expect(RepoRowText.shortened("abcdef", to: 100, measure: width) == "abcdef")
        #expect(RepoRowText.shortened("", to: 0, measure: width) == "")
    }

    @Test func anEvenCountKeepsTheSameAtBothEnds() {
        // 5 points: "…" and 4 characters.
        #expect(RepoRowText.shortened("abcdefghij", to: 5, measure: width) == "ab…ij")
    }

    @Test func anOddCountGivesTheExtraCharacterToTheStart() {
        // 6 points: "…" and 5 characters.
        #expect(RepoRowText.shortened("abcdefghij", to: 6, measure: width) == "abc…ij")
    }

    @Test func theExampleFromTheSidebar() {
        #expect(RepoRowText.shortened("storefront-pricing-service", to: 14, measure: width) == "storefr…ervice")
        #expect(RepoRowText.shortened("feature/checkout-saved-carts", to: 16, measure: width) == "feature/…d-carts")
    }

    @Test func wideCharactersAreMeasuredNotCounted() {
        // 7 points: "…" (1) and three wide characters (6): two at the start, one at the end.
        #expect(RepoRowText.shortened("日本語のリポジトリ", to: 7, measure: width) == "日本…リ")
        #expect(width(RepoRowText.shortened("日本語のリポジトリ", to: 8, measure: width)) <= 8)
    }

    @Test func accentedCharactersStayWhole() {
        #expect(RepoRowText.shortened("café-résumé-ñandú", to: 7, measure: width) == "caf…ndú")
    }

    @Test func combinedCharactersAreNeverSplit() {
        let family = "👨‍👩‍👧"
        let flag = "🇰🇿"
        let text = family + "ab" + flag + "cd" + family
        for room in stride(from: 1.0, through: 12, by: 1) {
            let result = RepoRowText.shortened(text, to: room, measure: width)
            #expect(width(result) <= room)
            for part in result.split(separator: "…", omittingEmptySubsequences: true) {
                #expect(text.contains(part), "\(part) is a piece of the original")
            }
        }
        #expect(RepoRowText.shortened(text, to: 6, measure: width) == family + "a…" + family)
    }

    @Test func oneCharacterOfRoomGivesOnlyTheEllipsis() {
        #expect(RepoRowText.shortened("abcdef", to: 1, measure: width) == "…")
    }

    @Test func noRoomForTheEllipsisGivesNothing() {
        #expect(RepoRowText.shortened("abcdef", to: 0, measure: width) == "")
        #expect(RepoRowText.shortened("abcdef", to: 0.5, measure: width) == "")
        #expect(RepoRowText.shortened("日本語", to: 1, measure: width) == "…")
    }

    @Test func theResultNeverExceedsTheWidth() {
        let text = "storefront-pricing-service 日本語 café"
        for room in stride(from: 0.0, through: 50, by: 0.5) {
            #expect(width(RepoRowText.shortened(text, to: room, measure: width)) <= room)
        }
    }

    // MARK: Both together

    @Test func bothInFullWhenTheyFit() {
        let fit = RepoRowText.fit(name: "app", branch: "main", budget: 7, measureName: width, measureBranch: width)
        #expect(fit == RepoRowText.Fit(name: "app", branch: "main", isShortened: false))
    }

    @Test func aLongBranchLeavesTheShortNameWhole() {
        let fit = RepoRowText.fit(
            name: "app", branch: "feature/checkout-saved-carts", budget: 20, measureName: width, measureBranch: width)
        #expect(fit.name == "app")
        #expect(fit.branch == "feature/…ed-carts")
        #expect(fit.isShortened)
    }

    @Test func bothLongEachGetsHalf() {
        let fit = RepoRowText.fit(
            name: "storefront-pricing-service", branch: "feature/checkout-saved-carts", budget: 28, measureName: width,
            measureBranch: width)
        #expect(fit.name == "storefr…ervice")
        #expect(fit.branch == "feature…-carts")
        #expect(width(fit.name) + width(fit.branch) <= 28)
    }

    @Test func nothingFitsInAZeroBudget() {
        let fit = RepoRowText.fit(name: "app", branch: "main", budget: 0, measureName: width, measureBranch: width)
        #expect(fit.name == "" && fit.branch == "" && fit.isShortened)
    }
}
