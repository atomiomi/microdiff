import AppKit
import MicroDiffCore

/// File-type and folder icons (Catppuccin shapes, 16x16 grid). Shape data and credits: see FileIconData.swift.
enum FileIcon: UInt8, CaseIterable {
    case file, folder, folderOpen, repo, submodule, typescript, javascript, vue
    case json, yaml, markdown, text, svg, typescriptReact, javascriptReact, bash
    case sass, html, css, python, pug, image, env, git
    case docker, dockerCompose, lock, typescriptDef, typescriptConfig, xml, toml, npm
    case nuxt, vite, eslint, prettier, readme, license, makefile, config
    case less, svelte, graphql, http, mjml, rust, swift, go
    case ruby, php, java, c, cpp, csharp, kotlin, lua
    case database, log, csv, pdf, font, zip, video, audio
    case binary

    /// One icon ready to stroke: a path per stroke on the 16x16 grid.
    private struct Prepared {
        let path: CGPath
        let color: CGColor
        let width: CGFloat
        let cap: CGLineCap
        let join: CGLineJoin
    }

    /// Prepared icons, filled on first use (at most one entry per icon, so the cache cannot grow).
    private static var prepared = [[Prepared]?](repeating: nil, count: allCases.count)
    private static var colors = [CGColor?](repeating: nil, count: FileIconTint.allCases.count)

    private static func color(_ tint: FileIconTint) -> CGColor {
        if let cached = colors[tint.rawValue] { return cached }
        let hex = tint.hex
        let color = CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        colors[tint.rawValue] = color
        return color
    }

    /// Parses an SVG path into a CGPath.
    static func cgPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        for command in SVGPath.parse(d) {
            switch command {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private var strokes: [Prepared] {
        if let cached = Self.prepared[Int(rawValue)] { return cached }
        let built = FileIconData.strokes(self).map {
            Prepared(path: Self.cgPath($0.d), color: Self.color($0.tint), width: $0.width, cap: $0.cap, join: $0.join)
        }
        Self.prepared[Int(rawValue)] = built
        return built
    }

    /// Strokes the icon into a size x size square whose top-left corner is at (x, y). The context is flipped
    /// (y grows downward), like `Icon.draw` in Icons.swift. `alpha` dims the whole icon (ignored files use 0.5).
    func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = 16, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        // At 16 the grid maps 1:1 to pixels, so the 1 px lines stay sharp.
        if size != 16 { ctx.scaleBy(x: size / 16, y: size / 16) }
        // Like the SVG viewBox: a few shapes (docker, swift, ...) overshoot the grid by a hair at the edge.
        ctx.clip(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let dim = alpha < 1
        if dim {
            ctx.setAlpha(max(0, alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for stroke in strokes {
            ctx.addPath(stroke.path)
            ctx.setStrokeColor(stroke.color)
            ctx.setLineWidth(stroke.width)
            ctx.setLineCap(stroke.cap)
            ctx.setLineJoin(stroke.join)
            ctx.strokePath()
        }
        if dim { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    // MARK: File names

    /// The icon for a file name (name only, no directories).
    ///
    /// Matching ignores case. Order: exact names, then name patterns (prefix/suffix), then the extension.
    /// A name that is only a dot plus an extension (".png") is a dotfile and gets the plain file icon.
    /// Decisions on the open points: any name starting with "readme" gets the readme icon (also "readme-notes.md");
    /// "license", "licence", "copying" match alone or followed by a dot and anything ("LICENSE.md");
    /// `.env.<x>` and `<x>.dockerfile` need something after / before the dot; `.envrc` is a plain file.
    static func forFile(named name: String) -> FileIcon {
        if name.isEmpty { return .file }
        // Only build a lowercase copy when there is a capital letter.
        var hasCapital = false
        for byte in name.utf8 where byte >= 0x41 && byte <= 0x5A {
            hasCapital = true
            break
        }
        let lower = hasCapital ? name.lowercased() : name

        if let icon = exactNames[lower] { return icon }
        if let icon = byPattern(lower) { return icon }

        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return .file }
        let ext = lower[lower.index(after: dot)...]
        if ext.isEmpty || ext.utf8.count > 10 { return .file }
        return extensions[String(ext)] ?? .file
    }

    private static func byPattern(_ n: String) -> FileIcon? {
        if n.hasSuffix(".lock") { return .lock }
        if n.hasPrefix("tsconfig."), n.hasSuffix(".json"), n.utf8.count > 14 { return .typescriptConfig }
        if n.hasPrefix("readme") { return .readme }
        if n.hasPrefix("license.") || n.hasPrefix("licence.") || n.hasPrefix("copying.") { return .license }
        if n.hasPrefix("dockerfile.") || (n.hasSuffix(".dockerfile") && n.utf8.count > 11) { return .docker }
        if n.hasPrefix("docker-compose."), n.hasSuffix(".yml") || n.hasSuffix(".yaml"), n.utf8.count > 20 {
            return .dockerCompose
        }
        if n.hasPrefix(".env.") { return .env }
        if n.hasPrefix("nuxt.config.") { return .nuxt }
        if n.hasPrefix("vite.config.") || n.hasPrefix("vitest.config.") { return .vite }
        if n.hasPrefix("eslint.config.") || n.hasPrefix(".eslintrc.") { return .eslint }
        if n.hasPrefix(".prettierrc.") || n.hasPrefix("prettier.config.") { return .prettier }
        if n.hasSuffix(".mk"), n.utf8.count > 3 { return .makefile }
        if n.hasSuffix(".d.ts") || n.hasSuffix(".d.mts") || n.hasSuffix(".d.cts") { return .typescriptDef }
        return nil
    }

    private static let exactNames: [String: FileIcon] = [
        "package.json": .npm,
        "package-lock.json": .lock, "pnpm-lock.yaml": .lock, "bun.lockb": .lock,
        "tsconfig.json": .typescriptConfig, "jsconfig.json": .typescriptConfig,
        "license": .license, "licence": .license, "copying": .license,
        "dockerfile": .docker, ".dockerignore": .docker,
        "docker-compose.yml": .dockerCompose, "docker-compose.yaml": .dockerCompose,
        "compose.yml": .dockerCompose, "compose.yaml": .dockerCompose,
        ".gitignore": .git, ".gitattributes": .git, ".gitmodules": .git, ".gitkeep": .git,
        ".git-blame-ignore-revs": .git,
        ".env": .env, ".nuxtrc": .nuxt,
        ".eslintrc": .eslint, ".eslintignore": .eslint,
        ".prettierrc": .prettier, ".prettierignore": .prettier,
        "makefile": .makefile, "gnumakefile": .makefile,
        ".editorconfig": .config, ".npmrc": .config, ".yarnrc": .config, ".yarnrc.yml": .config,
    ]

    private static let extensions: [String: FileIcon] = {
        var map: [String: FileIcon] = [:]
        func add(_ icon: FileIcon, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = icon }
        }
        add(.typescript, "ts mts cts")
        add(.typescriptReact, "tsx")
        add(.javascript, "js mjs cjs")
        add(.javascriptReact, "jsx")
        add(.vue, "vue")
        add(.json, "json jsonc jsonl json5")
        add(.yaml, "yaml yml")
        add(.markdown, "md mdc mdx markdown")
        add(.text, "txt")
        add(.svg, "svg")
        add(.bash, "sh bash zsh fish command")
        add(.sass, "scss sass")
        add(.html, "html htm")
        add(.css, "css")
        add(.python, "py pyi")
        add(.pug, "pug jade")
        add(.mjml, "mjml")
        add(.xml, "xml plist xsd xsl")
        add(.toml, "toml")
        add(.config, "ini cfg conf properties")
        add(.less, "less")
        add(.svelte, "svelte")
        add(.graphql, "graphql gql")
        add(.http, "http rest")
        add(.swift, "swift")
        add(.rust, "rs")
        add(.go, "go")
        add(.ruby, "rb")
        add(.php, "php")
        add(.java, "java")
        add(.c, "c h m")
        add(.cpp, "cpp cc cxx hpp hh mm")
        add(.csharp, "cs")
        add(.kotlin, "kt kts")
        add(.lua, "lua")
        add(.database, "sql sqlite db")
        add(.log, "log")
        add(.csv, "csv tsv")
        add(.pdf, "pdf")
        add(.font, "woff woff2 ttf otf eot")
        add(.zip, "zip tar gz tgz bz2 xz 7z rar")
        add(.video, "mp4 mov webm mkv avi")
        add(.audio, "mp3 wav ogg flac m4a aac")
        add(.image, "png jpg jpeg gif webp bmp tiff tif ico icns heic avif")
        add(.binary, "bin exe dll so dylib o a wasm class")
        return map
    }()
}
