#!/bin/bash
# Builds a small throwaway git repository that shows every case from the design:
# modified, added, deleted, renamed and binary files, plus a submodule with changes inside.
#
#   scripts/make-demo-repo.sh [target-dir]      (default: $TMPDIR/microdiff-demo)
#
# Prints the path of the repository to open: <target-dir>/micro-diff
set -euo pipefail

TARGET="${1:-${TMPDIR:-/tmp}/microdiff-demo}"
rm -rf "$TARGET"
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd -P)"

# Never touch the user's git config, and never sign.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() {
  git -c user.name=Demo -c user.email=demo@example.com -c commit.gpgsign=false \
      -c protocol.file.allow=always -c init.defaultBranch=main -c advice.detachedHead=false "$@"
}

# --- the library that becomes the submodule ---------------------------------
LIB="$TARGET/libgit-origin"
mkdir -p "$LIB/include" "$LIB/src"
g -C "$LIB" init -q
cat > "$LIB/include/git.h" <<'EOF'
#ifndef LIBGIT_H
#define LIBGIT_H

#include <stddef.h>

typedef struct git_repo git_repo;

int git_open(git_repo **out, const char *path);
int git_status(git_repo *repo, char *buffer, size_t size);
void git_close(git_repo *repo);

#endif
EOF
cat > "$LIB/src/status.c" <<'EOF'
#include "git.h"
#include <stdio.h>
#include <string.h>

int git_status(git_repo *repo, char *buffer, size_t size) {
    if (repo == NULL || buffer == NULL) {
        return -1;
    }
    /* porcelain v2 keeps the output stable between versions */
    const char *command = "git status --porcelain=v2";
    snprintf(buffer, size, "%s", command);
    return (int)strlen(buffer);
}
EOF
g -C "$LIB" add -A
g -C "$LIB" commit -q -m "libgit: first version"

# --- the main repository ----------------------------------------------------
REPO="$TARGET/micro-diff"
mkdir -p "$REPO/src/git" "$REPO/src/ui" "$REPO/notes" "$REPO/assets"
g -C "$REPO" init -q

cat > "$REPO/Cargo.toml" <<'EOF'
[package]
name = "micro-diff"
version = "0.1.0"
edition = "2021"

[dependencies]
anyhow = "1"
EOF
cat > "$REPO/README.md" <<'EOF'
# micro-diff

A slim viewer for git changes.

- `changes` shows what differs from the last commit
- `files` shows the folder as it is on disk

```sh
microdiff .
```
EOF
cat > "$REPO/notes/old.txt" <<'EOF'
todo
- split view
- stage / unstage hunks
- commit box
- blame

ideas
- one window per repo
- remember open tabs
- theme switcher

done
- file tree
- unified diff
EOF
cat > "$REPO/src/main.rs" <<'EOF'
mod app;

fn main() -> anyhow::Result<()> {
    let repo = git::Repo::open(".")?;
    app::App::run(&repo)
}
EOF
cat > "$REPO/src/app.rs" <<'EOF'
use crate::git::{Repo, Status};
use crate::ui::{Tree, View};

mod git;
mod ui;

pub struct App {
    repo: Repo,
    split: bool,
}

impl App {
    pub fn run(repo: &Repo) -> Result<()> {
        let status = repo.status()?;
        let mut tree = Tree::new();
        for entry in status.entries() {
            tree.push(entry.path());
        }

        let view = View::new(tree);
        view.render()
    }

    fn toggle_split(&mut self) {
        self.split = !self.split;
    }

    fn reload(&mut self) -> Result<()> {
        let status = self.repo.status()?;
        self.apply(status)
    }

    fn apply(&mut self, status: Status) -> Result<()> {
        // Rebuild the tree from scratch: it is cheap.
        let mut tree = Tree::new();
        for entry in status.entries() {
            tree.push(entry.path(), entry.kind());
        }
        Ok(())
    }

    fn keymap(key: Key) -> Action {
        match key {
            Key::Char('j') => Action::Down,
            Key::Char('k') => Action::Up,
            Key::Char('h') => Action::Collapse,
            Key::Char('l') => Action::Expand,
            Key::Tab => Action::SwitchPane,
            Key::Char('q') => Action::Quit,
            _ => Action::None,
        }
    }
}
EOF
cat > "$REPO/src/git/diff.rs" <<'EOF'
pub struct Hunk {
    pub old_start: usize,
    pub new_start: usize,
    pub lines: Vec<String>,
}

pub fn parse(patch: &str) -> Vec<Hunk> {
    let mut hunks = Vec::new();
    for line in patch.lines() {
        if line.starts_with("@@") {
            hunks.push(Hunk { old_start: 0, new_start: 0, lines: Vec::new() });
        }
    }
    hunks
}
EOF
cat > "$REPO/src/git/status.rs" <<'EOF'
pub enum Kind {
    Added,
    Modified,
    Deleted,
}

pub struct Entry {
    pub path: String,
    pub kind: Kind,
}
EOF
cat > "$REPO/src/git/submodule.rs" <<'EOF'
pub struct Submodule {
    pub path: String,
    pub head: String,
}
EOF
cat > "$REPO/src/ui/view.rs" <<'EOF'
pub struct View {
    width: u16,
    height: u16,
}

impl View {
    pub fn render(&self) -> Result<()> {
        Ok(())
    }
}
EOF
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x10\x00\x00\x00\x10\x08\x06\x00\x00\x00' > "$REPO/assets/logo.png"

g -C "$REPO" add -A
g -C "$REPO" commit -q -m "micro-diff: first version"
g -C "$REPO" submodule --quiet add "$LIB" vendor/libgit
g -C "$REPO" commit -q -m "add libgit"

# --- now the uncommitted changes --------------------------------------------
cat > "$REPO/src/app.rs" <<'EOF'
use crate::git::{Repo, Status};
use crate::ui::{Tree, View};

mod git;
mod ui;

pub struct App {
    repo: Repo,
    split: bool,
}

impl App {
    pub fn run(repo: &Repo) -> Result<()> {
        let status = repo.status()?;
        let mut tree = Tree::new();
        for entry in status.entries() {
            tree.push(entry.path(), entry.kind());
        }

        for sub in repo.submodules()? {
            tree.push_repo(sub.path(), sub.status()?);
        }

        let view = View::new(tree);
        view.render()
    }

    fn toggle_split(&mut self) {
        self.split = !self.split;
    }

    fn reload(&mut self) -> Result<()> {
        let status = self.repo.status()?;
        self.apply(status)
    }

    fn apply(&mut self, status: Status) -> Result<()> {
        // Rebuild the tree from scratch: it is cheap.
        let mut tree = Tree::new();
        for entry in status.entries() {
            tree.push(entry.path(), entry.kind());
        }
        Ok(())
    }

    fn keymap(key: Key) -> Action {
        match key {
            Key::Char('j') => Action::Down,
            Key::Char('k') => Action::Up,
            Key::Tab => Action::SwitchPane,
            Key::Char('s') => Action::ToggleSplit,
            Key::Char('q') => Action::Quit,
            _ => Action::None,
        }
    }
}
EOF
cat >> "$REPO/src/git/diff.rs" <<'EOF'

pub fn is_binary(patch: &str) -> bool {
    patch.lines().any(|line| line.starts_with("Binary files "))
}
EOF
mkdir -p "$REPO/src/ui/widgets"
cat > "$REPO/src/ui/widgets/tree.rs" <<'EOF'
use std::path::Path;

pub enum Kind {
    Added,
    Modified,
    Deleted,
}

pub struct Tree {
    rows: Vec<Row>,
}

impl Tree {
    pub fn new() -> Self {
        Tree { rows: Vec::new() }
    }

    pub fn push(&mut self, path: &Path, kind: Kind) {
        self.rows.push(Row::file(path, kind));
    }

    pub fn push_repo(&mut self, path: &Path, status: Status) {
        self.rows.push(Row::repo(path, status));
    }
}
EOF
g -C "$REPO" mv src/ui/view.rs src/ui/panel.rs
rm "$REPO/notes/old.txt"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x20\x00\x00\x00\x20\x08\x06\x00\x00\x00\x01\x02' > "$REPO/assets/logo.png"

SUB="$REPO/vendor/libgit"
g -C "$SUB" checkout -q -b dev
cat > "$SUB/include/git.h" <<'EOF'
#ifndef LIBGIT_H
#define LIBGIT_H

#include <stddef.h>

typedef struct git_repo git_repo;

int git_open(git_repo **out, const char *path);
int git_status(git_repo *repo, char *buffer, size_t size);
int git_submodules(git_repo *repo, char *buffer, size_t size);
void git_close(git_repo *repo);

#endif
EOF
cat > "$SUB/src/status.c" <<'EOF'
#include "git.h"
#include <stdio.h>
#include <string.h>

int git_status(git_repo *repo, char *buffer, size_t size) {
    if (repo == NULL || buffer == NULL || size == 0) {
        return -1;
    }
    /* porcelain v2 keeps the output stable between versions */
    const char *command = "git status --porcelain=v2 --branch";
    snprintf(buffer, size, "%s", command);
    return (int)strlen(buffer);
}
EOF

echo "$REPO"
