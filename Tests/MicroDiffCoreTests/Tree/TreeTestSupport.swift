import Foundation

// Kept apart from the Testing files: Foundation + Testing in one file does not compile on a Command Line Tools install.
func makeSymlink(_ path: String, to destination: String) throws {
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
}
