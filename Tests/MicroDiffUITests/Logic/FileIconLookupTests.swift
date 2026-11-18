import Testing
@testable import MicroDiffUI

extension UITests {
    @MainActor
    struct FileIconLookupTests {
        private func icon(_ name: String) -> FileIcon { FileIcon.forFile(named: name) }

        @Test(arguments: [
            ("package.json", FileIcon.npm),
            ("package-lock.json", .lock), ("pnpm-lock.yaml", .lock), ("bun.lockb", .lock),
            ("Cargo.lock", .lock), ("yarn.lock", .lock), ("Gemfile.lock", .lock),
            ("tsconfig.json", .typescriptConfig), ("tsconfig.build.json", .typescriptConfig),
            ("tsconfig.app.node.json", .typescriptConfig), ("jsconfig.json", .typescriptConfig),
            ("README", .readme), ("README.md", .readme), ("readme.txt", .readme), ("ReadMe.markdown", .readme),
            ("LICENSE", .license), ("LICENCE", .license), ("COPYING", .license), ("LICENSE.md", .license),
            ("license.txt", .license), ("COPYING.LESSER", .license),
            ("Dockerfile", .docker), ("Dockerfile.dev", .docker), ("app.dockerfile", .docker), (".dockerignore", .docker),
            ("docker-compose.yml", .dockerCompose), ("docker-compose.yaml", .dockerCompose),
            ("docker-compose.override.yml", .dockerCompose), ("docker-compose.prod.yaml", .dockerCompose),
            ("compose.yml", .dockerCompose), ("compose.yaml", .dockerCompose),
            (".gitignore", .git), (".gitattributes", .git), (".gitmodules", .git), (".gitkeep", .git),
            (".git-blame-ignore-revs", .git),
            (".env", .env), (".env.local", .env), (".env.production.local", .env),
            ("nuxt.config.ts", .nuxt), ("nuxt.config.js", .nuxt), (".nuxtrc", .nuxt),
            ("vite.config.ts", .vite), ("vite.config.mjs", .vite), ("vitest.config.ts", .vite),
            ("eslint.config.js", .eslint), (".eslintrc", .eslint), (".eslintrc.json", .eslint), (".eslintrc.cjs", .eslint),
            (".eslintignore", .eslint),
            (".prettierrc", .prettier), (".prettierrc.json", .prettier), ("prettier.config.js", .prettier),
            (".prettierignore", .prettier),
            ("Makefile", .makefile), ("makefile", .makefile), ("GNUmakefile", .makefile), ("rules.mk", .makefile),
            (".editorconfig", .config), (".npmrc", .config), (".yarnrc", .config), (".yarnrc.yml", .config),
        ])
        func namePatterns(name: String, expected: FileIcon) {
            #expect(icon(name) == expected, "\(name)")
        }

        @Test(arguments: [
            ("a.d.ts", FileIcon.typescriptDef), ("global.d.mts", .typescriptDef), ("x.d.cts", .typescriptDef),
            ("a.ts", .typescript), ("a.mts", .typescript), ("a.cts", .typescript),
            ("a.tsx", .typescriptReact), ("a.js", .javascript), ("a.mjs", .javascript), ("a.cjs", .javascript),
            ("a.jsx", .javascriptReact), ("App.vue", .vue),
            ("a.json", .json), ("a.jsonc", .json), ("a.jsonl", .json), ("a.json5", .json),
            ("a.yaml", .yaml), ("a.yml", .yaml),
            ("a.md", .markdown), ("a.mdc", .markdown), ("a.mdx", .markdown), ("a.markdown", .markdown),
            ("a.txt", .text), ("a.svg", .svg),
            ("a.sh", .bash), ("a.bash", .bash), ("a.zsh", .bash), ("a.fish", .bash), ("a.command", .bash),
            ("a.scss", .sass), ("a.sass", .sass), ("a.html", .html), ("a.htm", .html), ("a.css", .css),
            ("a.py", .python), ("a.pyi", .python), ("a.pug", .pug), ("a.jade", .pug), ("a.mjml", .mjml),
            ("a.xml", .xml), ("a.plist", .xml), ("a.xsd", .xml), ("a.xsl", .xml), ("a.toml", .toml),
            ("a.ini", .config), ("a.cfg", .config), ("a.conf", .config), ("a.properties", .config),
            ("a.less", .less), ("a.svelte", .svelte), ("a.graphql", .graphql), ("a.gql", .graphql),
            ("a.http", .http), ("a.rest", .http),
            ("a.swift", .swift), ("a.rs", .rust), ("a.go", .go), ("a.rb", .ruby), ("a.php", .php), ("a.java", .java),
            ("a.c", .c), ("a.h", .c), ("a.m", .c),
            ("a.cpp", .cpp), ("a.cc", .cpp), ("a.cxx", .cpp), ("a.hpp", .cpp), ("a.hh", .cpp), ("a.mm", .cpp),
            ("a.cs", .csharp), ("a.kt", .kotlin), ("a.kts", .kotlin), ("a.lua", .lua),
            ("a.sql", .database), ("a.sqlite", .database), ("a.db", .database), ("a.log", .log),
            ("a.csv", .csv), ("a.tsv", .csv), ("a.pdf", .pdf),
            ("a.woff", .font), ("a.woff2", .font), ("a.ttf", .font), ("a.otf", .font), ("a.eot", .font),
            ("a.zip", .zip), ("a.tar", .zip), ("a.gz", .zip), ("a.tgz", .zip), ("a.bz2", .zip), ("a.xz", .zip),
            ("a.7z", .zip), ("a.rar", .zip),
            ("a.mp4", .video), ("a.mov", .video), ("a.webm", .video), ("a.mkv", .video), ("a.avi", .video),
            ("a.mp3", .audio), ("a.wav", .audio), ("a.ogg", .audio), ("a.flac", .audio), ("a.m4a", .audio),
            ("a.aac", .audio),
            ("a.png", .image), ("a.jpg", .image), ("a.jpeg", .image), ("a.gif", .image), ("a.webp", .image),
            ("a.bmp", .image), ("a.tiff", .image), ("a.tif", .image), ("a.ico", .image), ("a.icns", .image),
            ("a.heic", .image), ("a.avif", .image),
            ("a.bin", .binary), ("a.exe", .binary), ("a.dll", .binary), ("a.so", .binary), ("a.dylib", .binary),
            ("a.o", .binary), ("a.a", .binary), ("a.wasm", .binary), ("a.class", .binary),
        ])
        func extensions(name: String, expected: FileIcon) {
            #expect(icon(name) == expected, "\(name)")
        }

        @Test func extensionMatchIgnoresCase() {
            #expect(icon("FILE.VUE") == .vue)
            #expect(icon("Photo.JPG") == .image)
            #expect(icon("Main.Swift") == .swift)
            #expect(icon("DOCKERFILE") == .docker)
            #expect(icon("PACKAGE.JSON") == .npm)
        }

        @Test func nearMissesFallBack() {
            #expect(icon("package.json.bak") == .file)
            #expect(icon("package.jsonx") == .file)
            #expect(icon("tsconfig.txt") == .text)
            #expect(icon("tsconfig.json.bak") == .file)
            #expect(icon("tsconfig") == .file)
            #expect(icon(".envrc") == .file)
            #expect(icon(".environment") == .file)
            #expect(icon("env") == .file)
            #expect(icon("archive.tar.gz") == .zip)
            #expect(icon("Dockerfiles") == .file)
            #expect(icon("licensed.txt") == .text)
            #expect(icon("docker-compose.txt") == .text)
            #expect(icon("docker-compose.yml.bak") == .file)
            #expect(icon("vite.config") == .file)
            #expect(icon("lockfile") == .file)
            #expect(icon("x.lockb") == .file)
        }

        @Test func readmePrefixDecision() {
            // Documented choice: any name that starts with "readme" counts.
            #expect(icon("readme-notes.md") == .readme)
            #expect(icon("README_ES.md") == .readme)
            #expect(icon("my-readme.md") == .markdown)
        }

        @Test func dotfilesAreNotExtensions() {
            #expect(icon(".png") == .file)
            #expect(icon(".zip") == .file)
            #expect(icon(".ts") == .file)
            #expect(icon(".vue") == .file)
            #expect(icon(".hidden") == .file)
            #expect(icon(".a.png") == .image)
        }

        @Test func namesWithoutExtension() {
            #expect(icon("") == .file)
            #expect(icon("Gemfile") == .file)
            #expect(icon("name.") == .file)
            #expect(icon(".") == .file)
            #expect(icon("..") == .file)
            #expect(icon("a.unknownextension") == .file)
            #expect(icon("a.verylongextensionname") == .file)
        }

        @Test func patternsBeatExtensions() {
            #expect(icon("yarn.lock") == .lock)
            #expect(icon("pnpm-lock.yaml") == .lock)
            #expect(icon("docker-compose.yml") == .dockerCompose)
            #expect(icon("vite.config.ts") == .vite)
            #expect(icon("types.d.ts") == .typescriptDef)
            #expect(icon("README.md") == .readme)
        }

        @Test func unicodeNamesDoNotCrash() {
            #expect(icon("файл.vue") == .vue)
            #expect(icon("日本語") == .file)
            #expect(icon("Ünïcode.PNG") == .image)
        }
    }
}
