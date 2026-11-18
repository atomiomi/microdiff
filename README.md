# MicroDiff

A slim native macOS viewer for git changes. Two sidebar tabs (`changes`, `files`), file tabs, a unified diff view and a plain file view. Submodules and nested repositories with changes inside show up as their own section. It only reads; it never stages or commits.

Written in Swift with AppKit, no third-party dependencies.

## Run

```sh
swift run -c release MicroDiff /path/to/repo     # or run it inside a repo with no argument
scripts/build-app.sh                              # builds build/MicroDiff.app
open build/MicroDiff.app --args /path/to/repo
```

From any terminal, once `scripts/microdiff` is linked into a folder on your PATH (`ln -s "$PWD/scripts/microdiff" ~/.local/bin/microdiff`):

```sh
microdiff                  # the current folder
microdiff path/to/repo
microdiff src/app.rs       # that file's repository, with the file open in a tab
```

All windows live in one running app with one Dock icon. While it runs, `microdiff` opens the folder as a new window there (or brings its window to the front if that folder or repository is already open) and returns at once. The terminal call talks to the app over a socket in your private temporary folder; `MICRODIFF_SOCKET=/path/x.sock` picks another one (handy for a test copy). Closing the last window quits the app. `--snapshot`, `--soak` and the benchmark mode always run as their own process.

`scripts/make-demo-repo.sh` creates a throwaway repository with every case from the design (modified, added, deleted, renamed, binary, submodule) and prints its path.

Keys: `⌘1` changes, `⌘2` files, `⌘D` switch diff / file, `⌘W` close tab, `⌘⇧W` close window, ``⌘` `` cycle windows, `⌘⇧]` `⌘⇧[` next / previous tab, `⌘R` refresh, `⌘O` open folder. A single click opens a file in a preview tab (italic); a double click keeps it.

The font is JetBrains Mono when it is installed, otherwise the system monospaced font.

## Tests

```sh
scripts/test.sh                 # unit and integration tests (Swift Testing)
scripts/test.sh --filter Lexer  # a subset
scripts/perf.sh                 # speed and memory budgets, optimized build
scripts/perf-app.sh             # launches the real app and checks startup time and memory
scripts/coverage.sh             # line and function coverage per source file
scripts/leaks.sh                # drives the real app offscreen under `leaks` while a repo changes under it
MICRODIFF_SOAK=10 scripts/test.sh --filter Isolated   # the memory-growth tests, ten times longer
```

Use the scripts rather than plain `swift test`: with only the Command Line Tools installed, SwiftPM needs extra flags to find the Swift Testing framework, and the scripts add them.

Two developer aids are built into the binary:

```sh
# Render the window to a picture without showing it (for checking the look):
MicroDiff /path/to/repo --snapshot out.png [--tab files] [--open src/a.rs] [--mode file] [--size 1180x720] [--scroll 400]
# Print launch time and memory as JSON once the first frame is up, then quit:
MicroDiff /path/to/repo --bench
```

## Layout

| Path | What |
|---|---|
| `Sources/MicroDiffCore` | Everything without UI: running git, parsing status and diffs, the row model of the diff view, sidebar trees, syntax coloring, file watching |
| `Sources/MicroDiffUI` | AppKit views (all drawn by hand, only what is visible) and the app state |
| `Sources/MicroDiff` | The executable's entry point |
| `Tests/MicroDiffCoreTests`, `Tests/MicroDiffUITests` | Behaviour tests |
| `Tests/MicroDiffPerfTests` | Speed and memory budgets |
| `Tests/MicroDiffTestSupport` | Temp folders and throwaway git repositories for tests |

## License

MIT, see [LICENSE](LICENSE).

File-type icons are from [Catppuccin for VS Code icons](https://github.com/catppuccin/vscode-icons) (MIT), the small interface glyphs from [Lucide](https://lucide.dev) (ISC), and the syntax colors from [One Dark Pro](https://github.com/Binaryify/OneDark-Pro) (MIT). Their license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
