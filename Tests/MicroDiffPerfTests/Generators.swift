import Foundation
import MicroDiffCore

// Deterministic input generators: same bytes on every run.

/// SplitMix64: tiny, fast, and fully determined by its seed.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Generate {
    /// `git status --porcelain=v2 -z` output with `records` entries: mostly type 1, some renames,
    /// untracked files and a few submodules. Paths are about 40 bytes long.
    static func statusOutput(records: Int) -> Data {
        var rng = SeededRandom(seed: 1)
        let hash = String(repeating: "a", count: 40)
        var text = "# branch.oid \(hash)\0# branch.head main\0"
        for i in 0..<records {
            let path = "src/module\(i % 97)/part\(i % 13)/file_\(i)_name.swift".padding(toLength: 40, withPad: "x", startingAt: 0) + "\(i)"
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<60:
                text += "1 .M N... 100644 100644 100644 \(hash) \(hash) \(path)\0"
            case 60..<75:
                text += "1 A. N... 000000 100644 100644 \(hash) \(hash) \(path)\0"
            case 75..<85:
                text += "2 R. N... 100644 100644 100644 \(hash) \(hash) R100 \(path)\0\(path).old\0"
            case 85..<99:
                text += "? \(path)\0"
            default:
                text += "1 .M S.M. 160000 160000 160000 \(hash) \(hash) vendor/lib\(i)\0"
            }
        }
        return Data(text.utf8)
    }

    /// A snapshot with `repoSizes.count` repos; the changes of repo r spread over `folders[r]` folders.
    static func snapshot(repoSizes: [Int], folders: [Int]) -> WorkspaceSnapshot {
        var repos: [RepoSnapshot] = []
        for (r, size) in repoSizes.enumerated() {
            let changes = (0..<size).map { i -> FileChange in
                let folder = i % folders[r]
                return FileChange(path: "area\(folder / 20)/module\(folder)/file_\(i).swift", kind: i % 5 == 0 ? .added : .modified)
            }
            repos.append(RepoSnapshot(
                rootPath: "/tmp/repo\(r)", displayPath: r == 0 ? "" : "sub\(r)", name: "repo\(r)",
                isSubmodule: r > 0, branchLabel: "main", hasHead: true, changes: changes))
        }
        return WorkspaceSnapshot(rootPath: "/tmp/repo0", isGitRepo: true, repos: repos)
    }

    /// `lines` lines of exactly 49 characters plus a newline (50 bytes per line).
    static func plainText(lines: Int) -> Data {
        let pool = (0..<1000).map { i in "let value\(i) = compute(\(i), offset: \(i * 7))".padding(toLength: 49, withPad: " ", startingAt: 0) }
        var out = Data(capacity: lines * 50)
        for i in 0..<lines { out.append(contentsOf: (pool[i % 1000] + "\n").utf8) }
        return out
    }

    /// A -U0 patch of `hunks` one-line replacements, about 100 bytes each.
    static func patch(hunks: Int) -> Data {
        var text = "diff --git a/Big.swift b/Big.swift\nindex 1111111..2222222 100644\n--- a/Big.swift\n+++ b/Big.swift\n"
        for i in 0..<hunks {
            let line = i * 20 + 5
            text += "@@ -\(line) +\(line) @@ func member\(i)()\n-    let oldValue\(i) = oldCompute(\(i), offset: 1)\n+    let newValue\(i) = newCompute(\(i), offset: 2)\n"
        }
        return Data(text.utf8)
    }

    /// `hunks` one-line replacements spaced 20 lines apart.
    static func filePatch(hunks: Int) -> FilePatch {
        let list = (0..<hunks).map { i in
            Hunk(oldStart: i * 20 + 5, oldCount: 1, newStart: i * 20 + 5, newCount: 1, deletedLines: i..<(i + 1))
        }
        return FilePatch(hunks: list)
    }

    /// A typical changed line pair of about 80 characters.
    static let wordDiffPairs: [(old: String, new: String)] = (0..<8).map { i in
        ("    let result\(i) = computeTotal(items: orderItems, discount: appliedDiscount) + shippingFee",
         "    let result\(i) = computeTotal(items: cartItems, discount: appliedDiscount, tax: taxRate) + fee")
    }

    /// 40 lines of realistic Swift: strings, interpolation, comments (also multi-line), numbers, generics.
    static let swiftSnippet = """
    import Foundation

    /// A tiny cache of parsed values, keyed by whatever the caller prefers to use.
    struct Item<Key: Hashable>: Codable {
        /// The identifier shown in the sidebar next to the name of the item.
        var id: Int = 42
        let name: String
        var tags: [String] = []

        /* Totals are cached by the owner of the item
           and recomputed only when the rate changes. */
        func total(with rate: Double = 0.25) -> Double {
            let base = Double(id) * 1_000.5 + Double(tags.count) * 12.75
            let label = "item-\\(id): \\(name) (\\(tags.count) tags)"
            if label.isEmpty { return 0 }
            return base * (1 + rate) // tax included in the price
        }

        mutating func rename(to newName: String) throws {
            guard !newName.isEmpty else {
                throw ItemError.empty(0x1F)
            }
            tags.append("renamed from \\(name) to \\(newName)")
        }
    }

    enum ItemError: Error {
        case empty(Int)
        case missing(key: String)
        case duplicate(key: String, count: Int)
    }

    extension Item where Key == String {
        static let sample = Item<String>(id: 7, name: "demo item", tags: ["a", "b"])
        func describe() -> String {
            "\\(name) has \\(tags.count) tags and costs \\(total())"
        }
    }

    """


    /// `lines` lines of Swift made by repeating the snippet; the type name carries a counter so no two copies are identical.
    static func swiftSource(lines: Int, unique: Bool = true) -> String {
        let snippet = swiftSnippet.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        var out = ""
        out.reserveCapacity(lines * 40)
        var line = 0
        var copy = 0
        while line < lines {
            for text in snippet where line < lines {
                out += unique ? text.replacingOccurrences(of: "Item", with: "Item\(copy)") : text
                out += "\n"
                line += 1
            }
            copy += 1
        }
        return out
    }

    static let vueSnippet = """
    <template>
      <section class="panel" v-if="items.length">
        <h2 :title="title" @click="toggle(id)">{{ title.toUpperCase() }}</h2>
        <ul>
          <li v-for="item in items" :key="item.id">{{ item.name }} ({{ item.count + 1 }})</li>
        </ul>
      </section>
    </template>

    <script setup lang="ts">
    import { computed, ref } from 'vue'

    interface Item { id: number; name: string; count: number }

    /* Items are loaded once
       and filtered by the search box. */
    const items = ref<Item[]>([])
    const total = computed(() => items.value.reduce((sum, item) => sum + item.count, 0) / 2)
    const pattern = /^item-\\d+$/i // matches ids

    function toggle(id: number): boolean {
      return items.value.some((item) => item.id === id && `${item.name}`.length > 0)
    }
    </script>

    <style scoped lang="scss">
    $gap: 8px;
    .panel {
      padding: $gap * 2; // spacing
      h2 { color: #1a2b3c; margin: 0 }
    }
    </style>

    """

    /// `lines` lines of a Vue single-file component made by repeating the snippet (template, TypeScript, SCSS).
    static func vueSource(lines: Int) -> String {
        let snippet = vueSnippet.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        var out = ""
        out.reserveCapacity(lines * 40)
        var line = 0
        while line < lines {
            for text in snippet where line < lines {
                out += text
                out += "\n"
                line += 1
            }
        }
        return out
    }

    /// The icon path measured for SVG parsing (same data as the folder icon in the UI).
    static let folderPath = "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"

    /// File names as they appear in a real tree: known extensions, special names, unknown ones.
    static let fileNames = [
        "main.swift", "App.rs", "index.tsx", "README.md", "Makefile", "style.css", "lib.py", "Dockerfile",
        "data.json", "notes.txt", "Foo.RS", "script.sh", ".gitignore", "unknown.xyz", "noextension", "view.go",
    ]
}
