import Testing
import MicroDiffCore

@Suite("LanguageRegistry")
struct LanguageRegistryTests {
    static func lang(_ name: String) -> LanguageDefinition? { LanguageRegistry.language(forFileName: name) }

    /// Every extension (as "file.<ext>") and file name from the spec with the language it must resolve to.
    static let table: [(file: String, language: String)] = {
        func rows(_ language: String, _ files: String) -> [(String, String)] {
            files.split(separator: " ").map { (String($0), language) }
        }
        return [
            rows("Swift", "a.swift"),
            rows("Objective-C", "a.m a.mm"),
            rows("C", "a.c a.h"),
            rows("C++", "a.cc a.cpp a.cxx a.hpp a.hh a.hxx"),
            rows("Rust", "a.rs"),
            rows("Go", "a.go"),
            rows("Zig", "a.zig"),
            rows("JavaScript", "a.js a.mjs a.cjs a.jsx"),
            rows("TypeScript", "a.ts a.mts a.cts a.tsx"),
            rows("Python", "a.py a.pyi"),
            rows("Ruby", "a.rb Gemfile Rakefile Podfile"),
            rows("Java", "a.java"),
            rows("Kotlin", "a.kt a.kts"),
            rows("Scala", "a.scala"),
            rows("C#", "a.cs"),
            rows("PHP", "a.php"),
            rows("Dart", "a.dart"),
            rows("Lua", "a.lua"),
            rows("Elixir", "a.ex a.exs"),
            rows("Erlang", "a.erl"),
            rows("Haskell", "a.hs"),
            rows("OCaml", "a.ml a.mli"),
            rows("R", "a.r"),
            rows("Perl", "a.pl a.pm"),
            rows("Shell", "a.sh a.bash a.zsh a.fish .bashrc .zshrc .profile .bash_profile .zprofile"),
            rows("PowerShell", "a.ps1"),
            rows("SQL", "a.sql"),
            rows("GraphQL", "a.graphql a.gql"),
            rows("Protobuf", "a.proto"),
            rows("Dockerfile", "Dockerfile Containerfile a.dockerfile"),
            rows("Makefile", "Makefile makefile GNUmakefile a.mk"),
            rows("CMake", "a.cmake CMakeLists.txt"),
            rows("Terraform", "a.tf a.hcl"),
            rows("Nix", "a.nix"),
            rows("HTML", "a.html a.htm a.xhtml"),
            rows("XML", "a.xml a.svg a.plist a.xib a.storyboard a.xcscheme a.entitlements a.mjml"),
            rows("Vue", "a.vue"),
            rows("Svelte", "a.svelte"),
            rows("Pug", "a.pug a.jade"),
            rows("CSS", "a.css"),
            rows("SCSS", "a.scss a.sass"),
            rows("Less", "a.less"),
            rows("JSON", "a.json a.jsonc a.json5 .prettierrc .eslintrc .babelrc Package.resolved a.jsonl"),
            rows("YAML", "a.yml a.yaml"),
            rows("TOML", "a.toml Cargo.lock Pipfile"),
            rows("INI", "a.ini a.cfg a.conf a.properties a.env .env .gitconfig .gitmodules .editorconfig .npmrc .nuxtrc .yarnrc .env.local .env.production"),
            rows("Git Ignore", ".gitignore .gitattributes .dockerignore .npmignore .git-blame-ignore-revs"),
            rows("Markdown", "a.md a.markdown a.mdx a.mdc"),
            rows("Plain Text", "a.txt a.text a.log"),
        ].flatMap { $0 }
    }()

    @Test(arguments: table.indices)
    func resolvesToExpectedLanguage(index: Int) throws {
        let (file, expected) = Self.table[index]
        let found = try #require(Self.lang(file), "\(file) is unknown")
        #expect(found.name == expected, "\(file) -> \(found.name), expected \(expected)")
    }

    @Test func everyLanguageNameInTheTableExists() {
        let names = Set(LanguageRegistry.all.map(\.name))
        for (_, language) in Self.table { #expect(names.contains(language)) }
        #expect(names.count == LanguageRegistry.all.count, "language names must be unique")
    }

    // MARK: Lookup rules

    @Test(arguments: ["MAIN.RS", "Main.Rs", "main.rS", "Foo.SWIFT", "x.TSX"])
    func extensionLookupIsCaseInsensitive(file: String) {
        #expect(Self.lang(file) != nil, "\(file)")
    }

    @Test func extensionCaseMapsToTheRightLanguage() {
        #expect(Self.lang("MAIN.RS")?.name == "Rust")
        #expect(Self.lang("Script.R")?.name == "R")
    }

    @Test func fileNameLookupIsCaseSensitive() {
        #expect(Self.lang("makefile")?.name == "Makefile")
        #expect(Self.lang("MAKEFILE") == nil)
        #expect(Self.lang("dockerfile") == nil)
        #expect(Self.lang("GEMFILE") == nil)
    }

    @Test func fileNameWinsOverExtension() {
        #expect(Self.lang("CMakeLists.txt")?.name == "CMake")
        #expect(Self.lang("CMakeLists.txt")?.name != "Plain Text")
        #expect(Self.lang("notes.txt")?.name == "Plain Text")
        #expect(Self.lang("Cargo.lock")?.name == "TOML")
        #expect(Self.lang("Package.resolved")?.name == "JSON")
    }

    @Test(arguments: ["file.unknownext", "README", "", ".", "..", "...", "foo.", "archive.tar.gz", "Makefile.bak", "noext"])
    func unknownNamesReturnNil(file: String) {
        #expect(Self.lang(file) == nil, "\(file.debugDescription)")
    }

    @Test func multiDotNamesUseTheLastExtension() {
        #expect(Self.lang("foo.test.ts")?.name == "TypeScript")
        #expect(Self.lang("a.b.c.rs")?.name == "Rust")
        #expect(Self.lang("Foo.d.ts")?.name == "TypeScript")
        #expect(Self.lang("foo.ts.bak") == nil)
        #expect(Self.lang("docker-compose.yml")?.name == "YAML")
    }

    @Test func unicodeAndOddNamesDoNotCrash() {
        #expect(Self.lang("файл.rs")?.name == "Rust")
        #expect(Self.lang("名前.未知") == nil)
        #expect(Self.lang("a.\u{1F600}") == nil)
        #expect(Self.lang(String(repeating: "x", count: 10_000) + ".swift")?.name == "Swift")
    }

    @Test(arguments: ["FILE.VUE", "Page.Svelte", "index.HTML", "A.PUG", "a.Jade", "LOG.JSONL", "Rules.MDC", "mail.MJML"])
    func newExtensionsAreCaseInsensitive(file: String) {
        #expect(Self.lang(file) != nil, "\(file)")
    }

    @Test(arguments: [
        ("FILE.VUE", "Vue"), ("x.PUG", "Pug"), ("x.Jade", "Pug"), ("x.JSONL", "JSON"), ("x.MDC", "Markdown"), ("x.MJML", "XML"),
    ])
    func newExtensionsMapToTheRightLanguage(file: String, language: String) {
        #expect(Self.lang(file)?.name == language)
    }

    @Test(arguments: [".env", ".env.local", ".env.production", ".env.development.local", ".env.", ".env.x.y", ".nuxtrc", ".yarnrc"])
    func envAndRcFilesAreIni(file: String) {
        #expect(Self.lang(file)?.name == "INI", "\(file)")
    }

    @Test func gitBlameIgnoreRevsIsGitIgnore() {
        #expect(Self.lang(".git-blame-ignore-revs")?.name == "Git Ignore")
    }

    @Test(arguments: ["env.local", "my.env.local", ".environment", ".env2", ".ENV.local", ".nuxtrc.bak", "nuxtrc", ".git-blame-ignore"])
    func nearMissesOfTheNewFileNamesAreNotMatched(file: String) {
        #expect(Self.lang(file)?.name != "INI", "\(file)")
    }

    @Test func jsAndTsEnableRegexAndTags() {
        for file in ["a.js", "a.jsx", "a.ts", "a.tsx"] { #expect(Self.lang(file)?.slashRegexAndTags == true, "\(file)") }
        for language in LanguageRegistry.all where !["JavaScript", "TypeScript"].contains(language.name) {
            #expect(!language.slashRegexAndTags, "\(language.name)")
        }
    }

    @Test func onlyHtmlVueAndSvelteEmbedScriptAndStyle() {
        let embedding = LanguageRegistry.all.filter(\.embedsScriptAndStyle).map(\.name)
        #expect(Set(embedding) == ["HTML", "Vue", "Svelte"])
    }

    // MARK: Table integrity

    @Test func noExtensionOrFileNameIsClaimedTwice() {
        var extensions: [String: String] = [:]
        var fileNames: [String: String] = [:]
        for language in LanguageRegistry.all {
            for ext in language.extensions {
                if let other = extensions[ext] { Issue.record("extension \(ext) in \(other) and \(language.name)") }
                extensions[ext] = language.name
            }
            for name in language.fileNames {
                if let other = fileNames[name] { Issue.record("file name \(name) in \(other) and \(language.name)") }
                fileNames[name] = language.name
            }
        }
    }

    @Test func extensionsAreLowercaseWithoutDots() {
        for language in LanguageRegistry.all {
            for ext in language.extensions {
                #expect(ext == ext.lowercased() && !ext.contains(".") && !ext.isEmpty, "\(language.name): \(ext)")
            }
        }
    }

    @Test func everyDefinitionIsNamedAndReachable() {
        for language in LanguageRegistry.all {
            #expect(!language.name.isEmpty)
            #expect(!language.extensions.isEmpty || !language.fileNames.isEmpty, "\(language.name) is unreachable")
        }
    }

    @Test func everyDeclaredKeyResolvesBackToItsLanguage() {
        for language in LanguageRegistry.all {
            for ext in language.extensions { #expect(Self.lang("f.\(ext)")?.name == language.name) }
            for name in language.fileNames { #expect(Self.lang(name)?.name == language.name) }
        }
    }

    @Test func wordSetsDoNotOverlap() {
        for language in LanguageRegistry.all where language.flavor == .code && !language.keywords.isEmpty {
            let kt = language.keywords.intersection(language.types)
            let kc = language.keywords.intersection(language.constants)
            let tc = language.types.intersection(language.constants)
            #expect(kt.isEmpty && kc.isEmpty && tc.isEmpty, "\(language.name): \(kt) \(kc) \(tc)")
        }
    }

    @Test func plainDefinitionsCarryNoKeywords() {
        for language in LanguageRegistry.all where language.flavor == .plain {
            #expect(language.keywords.isEmpty && language.types.isEmpty && language.constants.isEmpty)
        }
    }

    @Test func nonCodeFlavorsMatchTheirKind() {
        let expected: [String: LanguageDefinition.Flavor] = [
            "HTML": .markup, "XML": .markup, "Vue": .markup, "Svelte": .markup, "Pug": .code,
            "YAML": .keyValue, "TOML": .keyValue, "INI": .keyValue,
            "JSON": .json, "CSS": .css, "SCSS": .css, "Less": .css,
            "Markdown": .markdown, "Plain Text": .plain, "Git Ignore": .code, "Swift": .code, "Shell": .code,
        ]
        for language in LanguageRegistry.all {
            if let flavor = expected[language.name] { #expect(language.flavor == flavor, "\(language.name)") }
        }
    }

    @Test func ignoreFilesAreCodeWithHashCommentsAndNoKeywords() throws {
        let def = try #require(Self.lang(".gitignore"))
        #expect(def.flavor == .code)
        #expect(def.lineComments == ["#"])
        #expect(def.keywords.isEmpty)
        #expect(def.capitalizedIsType == false)
        for name in [".gitattributes", ".dockerignore", ".npmignore"] { #expect(Self.lang(name)?.name == def.name) }
    }

    @Test func capitalizationMeansNothingOutsideTypedLanguages() {
        for name in ["Shell", "SQL", "Makefile", "CSS", "SCSS", "Less", "HTML", "XML", "JSON", "YAML", "TOML", "INI", "Markdown"] {
            #expect(LanguageRegistry.all.first { $0.name == name }?.capitalizedIsType == false, "\(name)")
        }
        #expect(LanguageRegistry.all.first { $0.name == "C" }?.capitalizedIsType == true)
        #expect(LanguageRegistry.all.first { $0.name == "Swift" }?.capitalizedIsType == true)
    }

    // MARK: Content spot checks

    @Test(arguments: [
        ("Swift", "func guard actor let var if else switch case struct class enum protocol extension import return self super async await try throws"),
        ("C", "if else while for switch case break continue return struct union enum typedef static const sizeof goto"),
        ("C++", "class template namespace virtual override public private protected new delete this try catch throw constexpr"),
        ("Rust", "fn impl match let mut pub struct enum trait use mod where self Self async await unsafe loop"),
        ("Go", "func go chan select defer range package import interface struct map switch fallthrough"),
        ("JavaScript", "function const let var class extends async await yield import export new typeof instanceof"),
        ("TypeScript", "interface type namespace declare readonly abstract implements keyof enum satisfies"),
        ("Python", "def class async await lambda with yield import from as try except finally raise pass is not and or"),
        ("Java", "class interface extends implements public private protected static final abstract throws synchronized new"),
        ("Kotlin", "fun val var when object companion data sealed suspend override open inline"),
        ("C#", "namespace using class struct interface async await foreach readonly virtual override sealed"),
        ("Ruby", "def end class module do if elsif unless yield begin rescue ensure self"),
        ("PHP", "function class namespace use echo foreach endforeach elseif trait extends implements"),
    ])
    func keywordSpotChecks(language: String, words: String) throws {
        let def = try #require(LanguageRegistry.all.first { $0.name == language })
        for word in words.split(separator: " ") {
            #expect(def.keywords.contains(String(word)), "\(language) misses keyword \(word)")
        }
    }

    @Test(arguments: [
        ("Swift", "true false nil"), ("Rust", "true false"), ("Go", "true false nil iota"),
        ("JavaScript", "true false null undefined NaN"), ("TypeScript", "true false null undefined"),
        ("Python", "True False None"), ("Ruby", "true false nil"), ("Kotlin", "true false null"),
        ("PHP", "true false null"), ("C", "NULL"), ("Zig", "undefined null"),
    ])
    func constantSpotChecks(language: String, words: String) throws {
        let def = try #require(LanguageRegistry.all.first { $0.name == language })
        for word in words.split(separator: " ") {
            #expect(def.constants.contains(String(word)), "\(language) misses constant \(word)")
        }
    }

    @Test(arguments: [
        ("C", "int char void unsigned"), ("Rust", "usize u8 i64 bool str f32"), ("Go", "int string bool byte rune error"),
        ("TypeScript", "string number boolean any unknown never void"), ("Java", "int boolean void double"),
        ("C#", "int string bool void object"), ("Python", "int str list dict"),
    ])
    func typeSpotChecks(language: String, words: String) throws {
        let def = try #require(LanguageRegistry.all.first { $0.name == language })
        for word in words.split(separator: " ") {
            #expect(def.types.contains(String(word)), "\(language) misses type \(word)")
        }
    }

    @Test func swiftDetails() throws {
        let def = try #require(Self.lang("a.swift"))
        #expect(def.lineComments == ["//"])
        #expect(def.nestedBlockComments)
        #expect(def.strings.contains { $0.open == "\"\"\"" && $0.multiline })
        #expect(!def.keywords.contains("String"), "capitalized names are typed automatically")
    }

    @Test func rustDetails() throws {
        let def = try #require(Self.lang("a.rs"))
        #expect(def.nestedBlockComments)
        #expect(def.blockComments.contains(BlockComment("/*", "*/")))
        #expect(def.strings.contains { $0.open == "\"" && $0.multiline })
        #expect(def.strings.contains { $0.open == "'" && !$0.multiline }, "char literals; the lexer separates them from lifetimes")
    }

    @Test func pythonDetails() throws {
        let def = try #require(Self.lang("a.py"))
        #expect(def.lineComments == ["#"])
        for quote in ["\"\"\"", "'''"] {
            #expect(def.strings.contains { $0.open == quote && $0.close == quote && $0.multiline })
        }
        // The long delimiters must come before the short ones, so a lexer testing in order finds them first.
        let tripleIndex = def.strings.firstIndex { $0.open == "\"\"\"" }!
        let singleIndex = def.strings.firstIndex { $0.open == "\"" }!
        #expect(tripleIndex < singleIndex)
    }

    @Test func goDetails() throws {
        let def = try #require(Self.lang("a.go"))
        let raw = try #require(def.strings.first { $0.open == "`" })
        #expect(raw.escape == nil && raw.multiline)
    }

    @Test func javascriptDetails() throws {
        for file in ["a.js", "a.ts"] {
            let def = try #require(Self.lang(file))
            #expect(def.identifierExtras.contains("$"))
            let template = try #require(def.strings.first { $0.open == "`" })
            #expect(template.multiline)
        }
        #expect(Self.lang("a.php")?.identifierExtras.contains("$") == true)
    }

    @Test func rubyDetails() throws {
        let def = try #require(Self.lang("a.rb"))
        #expect(def.identifierExtras == "?!")
        #expect(def.lineComments == ["#"])
    }

    @Test func sqlIsCaseInsensitive() throws {
        let def = try #require(Self.lang("a.sql"))
        #expect(def.caseInsensitive)
        #expect(def.lineComments == ["--"])
        #expect(def.keywords.contains("select") && def.keywords.contains("where"))
        for word in def.keywords.union(def.types).union(def.constants) {
            #expect(word == word.lowercased(), "\(word) should be stored lowercase for case-insensitive matching")
        }
        #expect(LanguageRegistry.all.filter(\.caseInsensitive).map(\.name).contains("SQL"))
    }

    @Test func shellSingleQuotesHaveNoEscape() throws {
        for file in ["a.sh", ".zshrc", "a.bash"] {
            let def = try #require(Self.lang(file))
            let single = try #require(def.strings.first { $0.open == "'" })
            #expect(single.escape == nil, "\(file)")
            #expect(def.lineComments == ["#"])
        }
    }

    @Test func luaCommentsAndRawStrings() throws {
        let def = try #require(Self.lang("a.lua"))
        #expect(def.lineComments == ["--"])
        #expect(def.strings.contains { $0.open == "[[" && $0.close == "]]" && $0.multiline })
    }

    @Test func haskellAndOcamlNestBlockComments() throws {
        #expect(Self.lang("a.hs")?.nestedBlockComments == true)
        #expect(Self.lang("a.ml")?.nestedBlockComments == true)
        #expect(Self.lang("a.ml")?.blockComments == [BlockComment("(*", "*)")])
    }

    @Test func identifierExtrasNeverContainQuotes() {
        for language in LanguageRegistry.all {
            #expect(!language.identifierExtras.contains("'"), "\(language.name)")
        }
    }

    @Test func cssAllowsDashesInIdentifiers() throws {
        for file in ["a.css", "a.scss", "a.less"] {
            let def = try #require(Self.lang(file))
            #expect(def.identifierExtras.contains("-"))
            #expect(def.flavor == .css)
        }
    }
}
