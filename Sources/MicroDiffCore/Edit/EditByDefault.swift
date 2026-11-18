/// Which files open in edit mode when they are opened from the files tab: plain configuration and text files.
package enum EditByDefault {
    /// `.env`, `.env.<anything>`, and names with the extension `env` or `txt`, in any letter case, except
    /// `CMakeLists.txt`, which is code. Takes a file name (a path works too: only the last part counts).
    package static func matches(fileName: String) -> Bool {
        let name = (fileName.split(separator: "/").last.map(String.init) ?? fileName).lowercased()
        if name == "cmakelists.txt" { return false }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return ext == "env" || ext == "txt"
    }
}
