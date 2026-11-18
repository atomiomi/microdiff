import Foundation
import MicroDiffCore
import MicroDiffTestSupport

@testable import MicroDiffUI

enum DocumentFixture {
    /// Loads a file of `repo` the way a tab would: with its change and repository from a fresh scan,
    /// laid out with the app's own row heights.
    @MainActor
    static func load(_ repo: TestRepo, _ relative: String, mode: ViewMode = .diff) -> TextDocument {
        let scanner = RepoScanner()
        let snapshot = scanner.scan(root: repo.path)
        let repoSnapshot = snapshot.repos.first
        let change = repoSnapshot?.changes.first { $0.path == relative }
        let request = DocumentRequest(path: repo.path + "/" + relative, repo: change == nil ? nil : repoSnapshot, change: change, mode: mode,
            metrics: Theme.rowMetrics)
        guard case let .text(document) = DocumentLoader(scanner: scanner).load(request) else {
            fatalError("\(relative) did not load as text")
        }
        return document
    }
}
