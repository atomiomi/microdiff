import Foundation

/// The table of known languages and the lookup from a file name to a language.
package enum LanguageRegistry {
    /// Every known language. Built once.
    package static let all: [LanguageDefinition] = [
        swift, objectiveC, c, cpp, rust, go, zig, javascript, typescript, python, ruby, java, kotlin, scala,
        csharp, php, dart, lua, elixir, erlang, haskell, ocaml, r, perl, shell, powershell, sql, graphql,
        protobuf, dockerfile, makefile, cmake, terraform, nix, html, xml, vue, svelte, pug, css, scss, less,
        json, yaml, toml, ini, ignoreFile, markdown, plainText,
    ]

    private static let byFileName: [String: Int] = index { $0.fileNames }
    private static let byExtension: [String: Int] = index { $0.extensions }

    /// Maps every key to the first definition that claims it (a duplicate must not crash startup).
    private static func index(_ keys: (LanguageDefinition) -> [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (i, language) in all.enumerated() {
            for key in keys(language) where result[key] == nil { result[key] = i }
        }
        return result
    }

    /// The language for a file name (not a path), or nil when unknown.
    ///
    /// Lookup order: exact file name (case-sensitive, e.g. "Makefile", "Dockerfile", ".gitignore"),
    /// then the extension after the last dot, lowercased ("Foo.RS" -> "rs"). Must be O(1): use dictionaries built once.
    package static func language(forFileName fileName: String) -> LanguageDefinition? {
        if let i = byFileName[fileName] { return all[i] }
        // ".env.local", ".env.production", ...: all the same format as ".env".
        if fileName.hasPrefix(".env."), let i = byFileName[".env"] { return all[i] }
        let utf8 = fileName.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")) else { return nil }
        let start = utf8.index(after: dot)
        guard start != utf8.endIndex else { return nil }
        let tail = fileName[start...]
        // Extensions are nearly always lowercase already: only pay for lowercasing when a capital is there.
        let ext = tail.utf8.contains(where: { $0 >= 65 && $0 <= 90 }) ? tail.lowercased() : String(tail)
        return byExtension[ext].map { all[$0] }
    }
}

// MARK: - Building blocks

/// A set from a whitespace-separated list, so the tables below stay readable.
private func words(_ list: String) -> Set<String> {
    Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
}

private func list(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

private let slashComment = ["//"]
private let hashComment = ["#"]
private let cBlock = [BlockComment("/*", "*/")]
private let htmlBlock = [BlockComment("<!--", "-->")]
private let doubleQuote = StringDelimiter("\"")
private let singleQuote = StringDelimiter("'")
private let doubleQuoteMulti = StringDelimiter("\"", multiline: true)
private let singleQuoteMulti = StringDelimiter("'", multiline: true)
private let tripleDouble = StringDelimiter("\"\"\"", multiline: true)
private let tripleSingle = StringDelimiter("'''", multiline: true)

private let cKeywords = """
    auto break case const continue default do else enum extern for goto if inline register restrict return
    sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn
    _Static_assert _Thread_local alignas alignof static_assert thread_local typeof
    """

private let cTypes = """
    char double float int long short signed unsigned void _Bool _Complex _Imaginary bool wchar_t size_t ssize_t
    ptrdiff_t intptr_t uintptr_t intmax_t uintmax_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t
    """

/// `as`, `from`, `of` are left out on purpose: the lexer colors them only in keyword position.
private let jsKeywords = """
    async await break case catch class const continue debugger default delete do else enum export extends
    finally for function if implements import in instanceof interface let new package private protected public
    return static switch throw try typeof var while with yield
    """

// MARK: - Programming languages

private let swift = LanguageDefinition(
    name: "Swift",
    extensions: ["swift"],
    keywords: words("""
        actor any as associatedtype async await borrowing break case catch class consume consuming continue convenience
        copy default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard
        if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating
        open operator optional override package postfix precedencegroup prefix private protocol public repeat required
        rethrows return self set some static struct subscript super switch throw throws try typealias unowned var
        weak where while willSet
        """),
    constants: words("true false nil"),
    lineComments: slashComment,
    blockComments: cBlock,
    nestedBlockComments: true,
    strings: [tripleDouble, doubleQuote]
)

private let objectiveC = LanguageDefinition(
    name: "Objective-C",
    extensions: ["m", "mm"],
    keywords: words(cKeywords + " self super atomic nonatomic readonly readwrite nullable nonnull __block __weak __strong"),
    types: words(cTypes + " id instancetype"),
    constants: words("true false nil NULL YES NO"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote]
)

private let c = LanguageDefinition(
    name: "C",
    extensions: ["c", "h"],
    keywords: words(cKeywords),
    types: words(cTypes),
    constants: words("true false NULL nullptr"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote]
)

private let cpp = LanguageDefinition(
    name: "C++",
    extensions: ["cc", "cpp", "cxx", "hpp", "hh", "hxx"],
    keywords: words("""
        alignas alignof and and_eq asm auto bitand bitor break case catch class compl concept const const_cast
        consteval constexpr constinit continue co_await co_return co_yield decltype default delete do dynamic_cast
        else enum explicit export extern final for friend goto if import inline module mutable namespace new noexcept
        not not_eq operator or or_eq override private protected public register reinterpret_cast requires return
        sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typeid
        typename union using virtual volatile while xor xor_eq
        """),
    types: words("""
        bool char char8_t char16_t char32_t double float int long short signed unsigned void wchar_t size_t ssize_t
        ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t
        """),
    constants: words("true false nullptr NULL"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote]
)

private let rust = LanguageDefinition(
    name: "Rust",
    extensions: ["rs"],
    keywords: words("""
        abstract as async await become box break const continue crate do dyn else enum extern final fn for gen if impl
        in let loop macro match mod move mut override priv pub ref return self Self static struct super trait try type
        typeof unsafe unsized use virtual where while yield
        """),
    types: words("bool char str i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64"),
    constants: words("true false"),
    lineComments: slashComment,
    blockComments: cBlock,
    nestedBlockComments: true,
    // `'` is both a char literal and the lifetime marker (`'a`); the lexer tells them apart.
    strings: [doubleQuoteMulti, singleQuote]
)

private let go = LanguageDefinition(
    name: "Go",
    extensions: ["go"],
    keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map package
        range return select struct switch type var
        """),
    types: words("""
        any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string
        uint uint8 uint16 uint32 uint64 uintptr
        """),
    constants: words("true false nil iota"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote, StringDelimiter("`", escape: nil, multiline: true)]
)

private let zig = LanguageDefinition(
    name: "Zig",
    extensions: ["zig"],
    keywords: words("""
        addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue
        defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or
        orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace
        var volatile while
        """),
    types: words("""
        anyerror anyopaque bool comptime_float comptime_int f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 isize noreturn
        type u8 u16 u32 u64 u128 usize void c_char c_int c_uint c_long c_ulong c_longlong c_ushort c_short
        """),
    constants: words("true false null undefined"),
    lineComments: slashComment,
    strings: [doubleQuote, singleQuote]
)

private let javascript = LanguageDefinition(
    name: "JavaScript",
    extensions: ["js", "mjs", "cjs", "jsx"],
    keywords: words(jsKeywords + " void"),
    // `this` and `super` are colored like the other language variables.
    types: words("this super"),
    constants: words("true false null undefined NaN Infinity"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote, StringDelimiter("`", multiline: true)],
    identifierExtras: "$",
    slashRegexAndTags: true
)

private let typescript = LanguageDefinition(
    name: "TypeScript",
    extensions: ["ts", "mts", "cts", "tsx"],
    keywords: words(jsKeywords + """
         abstract accessor asserts declare infer is keyof module namespace override readonly satisfies type unique
        """),
    types: words("any bigint boolean never number object string symbol unknown void this super"),
    constants: words("true false null undefined NaN Infinity"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote, StringDelimiter("`", multiline: true)],
    identifierExtras: "$",
    slashRegexAndTags: true
)

private let python = LanguageDefinition(
    name: "Python",
    extensions: ["py", "pyi"],
    keywords: words("""
        and as assert async await break class continue def del elif else except finally for from global if import in is
        lambda nonlocal not or pass raise return try while with yield self cls
        """),
    types: words("int float str bool bytes bytearray complex dict frozenset list object range set tuple type"),
    constants: words("True False None Ellipsis NotImplemented"),
    lineComments: hashComment,
    strings: [tripleDouble, tripleSingle, doubleQuote, singleQuote]
)

private let ruby = LanguageDefinition(
    name: "Ruby",
    extensions: ["rb", "rake", "gemspec"],
    fileNames: ["Gemfile", "Rakefile", "Podfile"],
    keywords: words("""
        BEGIN END __FILE__ __LINE__ alias and begin break case class def defined? do else elsif end ensure for if in
        module next not or private protected public redo rescue retry return self super then undef unless until when
        while yield
        """),
    constants: words("true false nil"),
    lineComments: hashComment,
    blockComments: [BlockComment("=begin", "=end")],
    strings: [doubleQuoteMulti, singleQuoteMulti, StringDelimiter("`", multiline: true)],
    identifierExtras: "?!"
)

private let java = LanguageDefinition(
    name: "Java",
    extensions: ["java"],
    keywords: words("""
        abstract assert break case catch class const continue default do else enum extends final finally for goto if
        implements import instanceof interface native new package permits private protected public record return
        sealed static strictfp super switch synchronized this throw throws transient try var volatile while yield
        """),
    types: words("boolean byte char double float int long short void"),
    constants: words("true false null"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [tripleDouble, doubleQuote, singleQuote]
)

private let kotlin = LanguageDefinition(
    name: "Kotlin",
    extensions: ["kt", "kts"],
    keywords: words("""
        abstract actual annotation as break by catch class companion const constructor continue crossinline data do
        else enum expect external final finally for fun if import in infix init inline inner interface internal is
        lateinit noinline object open operator out override package private protected public reified return sealed
        super suspend tailrec this throw try typealias typeof val var vararg when where while
        """),
    constants: words("true false null"),
    lineComments: slashComment,
    blockComments: cBlock,
    nestedBlockComments: true,
    strings: [tripleDouble, doubleQuote, singleQuote]
)

private let scala = LanguageDefinition(
    name: "Scala",
    extensions: ["scala", "sc", "sbt"],
    keywords: words("""
        abstract case catch class def do else enum export extends final finally for forSome given if implicit import
        lazy match new object override package private protected return sealed super then this throw trait try type
        using val var while with yield
        """),
    constants: words("true false null"),
    lineComments: slashComment,
    blockComments: cBlock,
    nestedBlockComments: true,
    strings: [tripleDouble, doubleQuote, singleQuote]
)

private let csharp = LanguageDefinition(
    name: "C#",
    extensions: ["cs"],
    keywords: words("""
        abstract as async await base break case catch checked class const continue default delegate do else enum
        event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new
        operator out override params partial private protected public readonly record ref return sealed sizeof
        stackalloc static struct switch this throw try typeof unchecked unsafe using var virtual volatile where while
        yield
        """),
    types: words("""
        bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort
        void
        """),
    constants: words("true false null"),
    lineComments: slashComment,
    blockComments: cBlock,
    // Verbatim strings have no escapes; `""` inside them is a quote, so they end at the next lone `"`.
    strings: [
        tripleDouble, StringDelimiter("@\"", close: "\"", escape: nil, multiline: true), doubleQuote, singleQuote,
    ]
)

private let php = LanguageDefinition(
    name: "PHP",
    extensions: ["php"],
    keywords: words("""
        abstract and as break case catch class clone const continue declare default die do echo else elseif empty
        enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn for foreach
        function global goto if implements include include_once instanceof insteadof interface isset list match
        namespace new or parent print private protected public readonly require require_once return self static
        switch throw trait try unset use var while xor yield
        """),
    types: words("array bool callable float int iterable mixed never object string void"),
    constants: words("true false null"),
    lineComments: slashComment + hashComment,
    blockComments: cBlock,
    strings: [doubleQuoteMulti, singleQuoteMulti],
    identifierExtras: "$"
)

private let dart = LanguageDefinition(
    name: "Dart",
    extensions: ["dart"],
    keywords: words("""
        abstract as assert async await base break case catch class const continue covariant default deferred do else
        enum export extends extension external factory final finally for get hide if implements import in interface is
        late library mixin new on operator part required rethrow return sealed set show static super switch sync this
        throw try typedef var when while with yield
        """),
    types: words("bool double dynamic int num void"),
    constants: words("true false null"),
    lineComments: slashComment,
    blockComments: cBlock,
    nestedBlockComments: true,
    strings: [tripleDouble, tripleSingle, doubleQuote, singleQuote],
    identifierExtras: "$"
)

private let lua = LanguageDefinition(
    name: "Lua",
    extensions: ["lua"],
    keywords: words("""
        and break do else elseif end for function goto if in local not or repeat return self then until while
        """),
    constants: words("true false nil"),
    lineComments: ["--"],
    blockComments: [BlockComment("--[[", "]]")],
    strings: [StringDelimiter("[[", close: "]]", escape: nil, multiline: true), doubleQuote, singleQuote],
    capitalizedIsType: false
)

private let elixir = LanguageDefinition(
    name: "Elixir",
    extensions: ["ex", "exs"],
    keywords: words("""
        after alias and case catch cond def defdelegate defexception defguard defimpl defmacro defmacrop defmodule
        defoverridable defp defprotocol defstruct do else end fn for if import in not or quote raise receive require
        rescue try unless unquote use when with
        """),
    constants: words("true false nil"),
    lineComments: hashComment,
    strings: [tripleDouble, tripleSingle, doubleQuoteMulti, singleQuoteMulti],
    identifierExtras: "?!"
)

private let erlang = LanguageDefinition(
    name: "Erlang",
    extensions: ["erl", "hrl"],
    keywords: words("""
        after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let maybe not of or orelse
        receive rem try when xor
        """),
    constants: words("true false undefined"),
    lineComments: ["%"],
    strings: [doubleQuoteMulti, singleQuote],
    capitalizedIsType: false
)

private let haskell = LanguageDefinition(
    name: "Haskell",
    extensions: ["hs"],
    keywords: words("""
        case class data default deriving do else forall foreign hiding if import in infix infixl infixr instance let
        mdo module newtype of proc qualified rec then type where
        """),
    constants: words("True False"),
    lineComments: ["--"],
    blockComments: [BlockComment("{-", "-}")],
    nestedBlockComments: true,
    // No `'` delimiter: it is also part of identifiers (`foldl'`).
    strings: [doubleQuote]
)

private let ocaml = LanguageDefinition(
    name: "OCaml",
    extensions: ["ml", "mli"],
    keywords: words("""
        and as assert asr begin class constraint do done downto else end exception external for fun function functor
        if in include inherit initializer land lazy let lor lsl lsr lxor match method mod module mutable new nonrec
        object of open or private rec sig struct then to try type val virtual when while with
        """),
    types: words("array bool bytes char exn float int int32 int64 list nativeint option string unit"),
    constants: words("true false"),
    blockComments: [BlockComment("(*", "*)")],
    nestedBlockComments: true,
    // No `'` delimiter: it also marks type variables (`'a`).
    strings: [doubleQuoteMulti]
)

private let r = LanguageDefinition(
    name: "R",
    extensions: ["r"],
    keywords: words("break else for function if in next repeat return while"),
    constants: words("TRUE FALSE NULL NA NA_integer_ NA_real_ NA_character_ Inf NaN"),
    lineComments: hashComment,
    strings: [doubleQuoteMulti, singleQuoteMulti],
    capitalizedIsType: false,
    identifierExtras: "."
)

private let perl = LanguageDefinition(
    name: "Perl",
    extensions: ["pl", "pm"],
    keywords: words("""
        and bless cmp defined do else elsif eq eval for foreach ge goto gt if last le local lt my ne next no not or our
        package redo ref require return sub undef unless until use while xor
        """),
    lineComments: hashComment,
    strings: [doubleQuoteMulti, singleQuoteMulti]
)

private let shell = LanguageDefinition(
    name: "Shell",
    extensions: ["sh", "bash", "zsh", "fish"],
    fileNames: [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".zshenv", ".bash_aliases"],
    keywords: words("""
        alias begin break case coproc continue declare do done elif else end esac eval exec exit export fi for function
        if in local readonly return select set shift source switch then time trap typeset unset until while
        """),
    lineComments: hashComment,
    // Single quotes never escape in shells.
    strings: [doubleQuoteMulti, StringDelimiter("'", escape: nil, multiline: true)],
    capitalizedIsType: false
)

private let powershell = LanguageDefinition(
    name: "PowerShell",
    extensions: ["ps1", "psm1", "psd1"],
    keywords: words("""
        begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from
        function hidden if in inlinescript param parallel process return sequence static switch throw trap try until
        using while workflow
        """),
    constants: words("$true $false $null"),
    lineComments: hashComment,
    blockComments: [BlockComment("<#", "#>")],
    // Backtick escapes inside double quotes; single quotes only double up.
    strings: [StringDelimiter("\"", escape: "`", multiline: true), StringDelimiter("'", escape: nil, multiline: true)],
    capitalizedIsType: false,
    identifierExtras: "$",
    caseInsensitive: true
)

private let sql = LanguageDefinition(
    name: "SQL",
    extensions: ["sql"],
    keywords: words("""
        add all alter and as asc begin between by case check column commit constraint create cross cursor database
        declare default delete desc distinct drop else end exists explain fetch for foreign from full function grant
        group having if in index inner insert into is join key left like limit loop natural not offset on or order
        outer over partition pragma primary procedure recursive references return returns revoke right rollback schema
        select set table then transaction trigger truncate union unique update using values view when where while
        window with
        """),
    types: words("""
        bigint blob bool boolean bytea char date datetime decimal double float int integer json jsonb numeric
        precision real serial smallint text time timestamp tinyint uuid varchar
        """),
    constants: words("true false null"),
    lineComments: ["--"],
    blockComments: cBlock,
    strings: [
        StringDelimiter("'", escape: nil, multiline: true),
        StringDelimiter("\"", escape: nil),
        StringDelimiter("`", escape: nil),
    ],
    capitalizedIsType: false,
    caseInsensitive: true
)

private let graphql = LanguageDefinition(
    name: "GraphQL",
    extensions: ["graphql", "gql"],
    keywords: words("""
        directive enum extend fragment implements input interface mutation on query repeatable scalar schema
        subscription type union
        """),
    constants: words("true false null"),
    lineComments: hashComment,
    strings: [tripleDouble, doubleQuote]
)

private let protobuf = LanguageDefinition(
    name: "Protobuf",
    extensions: ["proto"],
    keywords: words("""
        edition enum extend extensions import map max message oneof option optional package public reserved repeated
        required returns rpc service stream syntax to weak
        """),
    types: words("""
        bool bytes double fixed32 fixed64 float int32 int64 sfixed32 sfixed64 sint32 sint64 string uint32 uint64
        """),
    constants: words("true false"),
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote]
)

private let dockerfile = LanguageDefinition(
    name: "Dockerfile",
    extensions: ["dockerfile"],
    fileNames: ["Dockerfile", "Containerfile"],
    keywords: words("""
        ADD ARG AS CMD COPY ENTRYPOINT ENV EXPOSE FROM HEALTHCHECK LABEL MAINTAINER ONBUILD RUN SHELL STOPSIGNAL USER
        VOLUME WORKDIR
        """),
    lineComments: hashComment,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false,
    caseInsensitive: true
)

private let makefile = LanguageDefinition(
    name: "Makefile",
    extensions: ["mk"],
    fileNames: ["Makefile", "makefile", "GNUmakefile"],
    keywords: words("""
        define else endef endif export ifdef ifeq ifndef ifneq include override private sinclude undefine unexport
        vpath
        """),
    lineComments: hashComment,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false
)

private let cmake = LanguageDefinition(
    name: "CMake",
    extensions: ["cmake"],
    fileNames: ["CMakeLists.txt"],
    keywords: words("""
        add_executable add_library add_subdirectory block break cmake_minimum_required continue else elseif endblock
        endforeach endfunction endif endmacro endwhile file find_package foreach function if include install list
        macro message option project return set string target_compile_options target_include_directories
        target_link_libraries unset while
        """),
    constants: words("ON OFF TRUE FALSE"),
    lineComments: hashComment,
    strings: [doubleQuoteMulti],
    capitalizedIsType: false,
    caseInsensitive: true
)

private let terraform = LanguageDefinition(
    name: "Terraform",
    extensions: ["tf", "hcl", "tfvars"],
    keywords: words("""
        backend check data dynamic else for if import in lifecycle locals module moved output provider provisioner
        required_providers resource terraform variable
        """),
    types: words("any bool list map number object set string tuple"),
    constants: words("true false null"),
    lineComments: hashComment + slashComment,
    blockComments: cBlock,
    strings: [doubleQuote],
    capitalizedIsType: false,
    identifierExtras: "-"
)

private let nix = LanguageDefinition(
    name: "Nix",
    extensions: ["nix"],
    keywords: words("assert else if in inherit let rec then with"),
    constants: words("true false null"),
    lineComments: hashComment,
    blockComments: cBlock,
    strings: [StringDelimiter("''", escape: nil, multiline: true), doubleQuoteMulti],
    capitalizedIsType: false,
    identifierExtras: "-"
)

// MARK: - Markup, data and config

/// `embeds`: color what is inside `<script>` and `<style>` as code (web pages and single-file components).
private func markup(_ name: String, extensions: [String], embeds: Bool = false) -> LanguageDefinition {
    LanguageDefinition(
        name: name,
        flavor: .markup,
        extensions: extensions,
        blockComments: htmlBlock,
        strings: [StringDelimiter("\"", escape: nil, multiline: true), StringDelimiter("'", escape: nil, multiline: true)],
        capitalizedIsType: false,
        identifierExtras: "-:",
        embedsScriptAndStyle: embeds
    )
}

private let html = markup("HTML", extensions: ["html", "htm", "xhtml"], embeds: true)
private let xml = markup(
    "XML", extensions: list("xml svg plist xib storyboard xcscheme entitlements xsd xsl xslt mjml"))
private let vue = markup("Vue", extensions: ["vue"], embeds: true)
private let svelte = markup("Svelte", extensions: ["svelte"], embeds: true)

/// Pug templates. Approximate: tags with attributes read as calls, `#id` as a directive, the rest as plain words.
private let pug = LanguageDefinition(
    name: "Pug",
    extensions: ["pug", "jade"],
    keywords: words("if else unless each for in while case when default mixin include extends block append prepend doctype"),
    constants: words("true false null undefined"),
    lineComments: slashComment,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false,
    identifierExtras: "-"
)

private let css = LanguageDefinition(
    name: "CSS",
    flavor: .css,
    extensions: ["css"],
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false,
    identifierExtras: "-"
)

private let scss = LanguageDefinition(
    name: "SCSS",
    flavor: .css,
    extensions: ["scss", "sass"],
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false,
    identifierExtras: "-"
)

private let less = LanguageDefinition(
    name: "Less",
    flavor: .css,
    extensions: ["less"],
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false,
    identifierExtras: "-"
)

private let json = LanguageDefinition(
    name: "JSON",
    flavor: .json,
    extensions: ["json", "jsonc", "json5", "jsonl"],
    fileNames: [".prettierrc", ".eslintrc", ".babelrc", "Package.resolved"],
    constants: words("true false null"),
    // JSONC and JSON5 allow comments (and JSON5 single quotes); being lenient is harmless for plain JSON.
    lineComments: slashComment,
    blockComments: cBlock,
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false
)

private let yaml = LanguageDefinition(
    name: "YAML",
    flavor: .keyValue,
    extensions: ["yml", "yaml"],
    constants: words("true false null"),
    lineComments: hashComment,
    // YAML single quotes escape by doubling, not with a backslash.
    strings: [doubleQuoteMulti, StringDelimiter("'", escape: nil, multiline: true)],
    capitalizedIsType: false
)

private let toml = LanguageDefinition(
    name: "TOML",
    flavor: .keyValue,
    extensions: ["toml"],
    fileNames: ["Cargo.lock", "Pipfile"],
    constants: words("true false inf nan"),
    lineComments: hashComment,
    strings: [
        tripleDouble, StringDelimiter("'''", escape: nil, multiline: true), doubleQuote,
        StringDelimiter("'", escape: nil),
    ],
    capitalizedIsType: false
)

private let ini = LanguageDefinition(
    name: "INI",
    flavor: .keyValue,
    extensions: ["ini", "cfg", "conf", "properties", "env"],
    fileNames: [".env", ".gitconfig", ".gitmodules", ".editorconfig", ".npmrc", ".nuxtrc", ".yarnrc"],
    constants: words("true false"),
    lineComments: hashComment + [";"],
    strings: [doubleQuote, singleQuote],
    capitalizedIsType: false
)

/// `.gitignore` and friends: patterns with `#` comments, nothing to color besides that.
private let ignoreFile = LanguageDefinition(
    name: "Git Ignore",
    fileNames: [".gitignore", ".gitattributes", ".dockerignore", ".npmignore", ".prettierignore", ".eslintignore", ".git-blame-ignore-revs"],
    lineComments: hashComment,
    capitalizedIsType: false
)

private let markdown = LanguageDefinition(
    name: "Markdown",
    flavor: .markdown,
    extensions: ["md", "markdown", "mdx", "mdc"],
    blockComments: htmlBlock,
    capitalizedIsType: false
)

private let plainText = LanguageDefinition(
    name: "Plain Text",
    flavor: .plain,
    extensions: ["txt", "text", "log"],
    capitalizedIsType: false
)
