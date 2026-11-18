# MicroDiff

A slim native macOS viewer for git changes. Two sidebar tabs (`changes`, `files`), file tabs, a unified diff view, a read view of the whole file and a plain-text editor (`edit`) for the open file. Submodules and nested repositories with changes inside show up as their own section. It never stages or commits: the only thing it writes is a file you edit and save.

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

Keys: `⌘1` changes, `⌘2` files, `⌘B` hide / show the sidebar (the choice is remembered; `⌘1` and `⌘2` show it again), `⌘D` diff, `⌘R` read, `⌘E` edit (each goes straight to its mode for the open tab; the key of the current mode does nothing), `⌘S` save, `⌘W` close tab, `⌘⇧W` close window, ``⌘` `` cycle windows, `⌘⇧]` `⌘⇧[` next / previous tab, `⌘⇧R` refresh, `⌘O` open folder. A single click opens a file in a preview tab (italic); a double click (or typing in it) keeps it.

Repository rows (in both sidebar tabs) show the branch, and after it `↓` in red when the remote has commits this clone does not have (something to pull) and `↑` in green when this clone has commits that are not pushed yet (something to push). There is no mark when there is nothing to do, when the branch follows no remote branch, or when HEAD is detached. The marks are never shortened: the repository name and the branch give them room. Every repository of the folder gets the marks: the root, nested repositories and submodules (also inside submodules), with or without local changes. A nested repository or a submodule without local changes is listed in the changes tab, as its header alone, only while it has a mark. A clean submodule on a branch is read from its git folder (a few small files, no `git status`), and git runs for it only when something in it moved. Pointing at a row shows a tooltip with what the marks mean (`to pull: new commits on origin/main (checked 2 minutes ago)`, `to push: commits that are not on origin/main yet`) and, when the name or the branch is shortened, the full `name  ·  branch`.

The marks come from what git already knows (`git status` runs anyway: the last fetch left this clone ahead or behind). On top of that the app asks the remote where the branch is, with `git ls-remote` for that one branch: nothing is downloaded, nothing is written to the repository, and the app never fetches, pulls or pushes. The asking never prompts for anything (no password on a terminal, no password window; your ssh keys and credential helpers work as they do for you) and a call that takes longer than 15 seconds is killed; a failure (offline, no access) just means no mark from the remote, and a repository that fails twice in a row is left alone for 30 minutes. It asks up to 4 remotes at a time. It asks once shortly after a folder is opened, when the window becomes the active one and the last check is older than 5 minutes, every 5 minutes while the window is visible (nothing runs while it is minimized, hidden or covered), and on `⇧⌘R` always. `--snapshot`, `--bench` and `--soak` never contact a remote.

`.env` files (`.env`, `.env.local`, `prod.env`) and `.txt` files (not `CMakeLists.txt`) open in edit mode when opened from the `files` tab. In edit mode the file is plain text: no syntax colors, any UTF-8 text file up to 4 MB (binary, deleted and other files cannot be edited, and `edit` is dimmed for them). A dot in place of a tab's close button means unsaved edits; `diff` and `read` keep showing what is on disk until you save. Closing a tab, the window or the app with unsaved edits asks first. When the file changes on disk under unsaved edits, a strip offers `reload` or `keep mine`; without unsaved edits the editor follows the disk by itself. The editor shows the read view's change bars (green added, yellow modified), kept up to date as you type, and a file's undo history lasts as long as its tab, across saves and modes. Return keeps the indentation of the line; Tab inserts a tab in files indented with tabs and spaces up to the next indent level in files indented with spaces (found from the file's first lines).

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
MicroDiff /path/to/repo --snapshot out.png [--tab files] [--open src/a.rs] [--mode diff|read|edit] [--size 1180x720] [--scroll 400] [--sidebar 220|hidden]
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
