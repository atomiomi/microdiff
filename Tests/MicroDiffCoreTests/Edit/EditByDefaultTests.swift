import MicroDiffCore
import Testing

@Suite("EditByDefault")
struct EditByDefaultTests {
    @Test(arguments: [".env", ".env.local", ".env.production", "prod.env", "notes.txt", "a.b.txt", "README.TXT", ".ENV", ".Env.Local", "Prod.ENV"])
    func opensInEditMode(name: String) {
        #expect(EditByDefault.matches(fileName: name))
    }

    @Test(arguments: [".envrc", "env", "txt", "notes.txt.bak", "CMakeLists.txt.in", "x.log", "README.md", ".gitignore", "a.json", ".environment", "", "CMakeLists.txt", "cmakelists.TXT", "src/CMakeLists.txt"])
    func staysInRead(name: String) {
        #expect(!EditByDefault.matches(fileName: name))
    }

    @Test func aFolderPathDoesNotMatter() {
        #expect(EditByDefault.matches(fileName: "config.env/app/.env"))
        #expect(EditByDefault.matches(fileName: "a/b/notes.txt"))
        #expect(!EditByDefault.matches(fileName: "notes.txt/readme.md"))
        #expect(!EditByDefault.matches(fileName: "dir.env/main.swift"))
    }
}
