@_exported import MicroDiffTestSupport
import Foundation

// This machine's Command Line Tools ship a broken `_Testing_Foundation` overlay, so a test file must not
// import both Foundation and Testing. Test files use these module-wide helpers instead of importing Foundation.
typealias Data = Foundation.Data

func isExecutableFile(_ path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
}

func symlinkFolder(_ link: String, to target: String) {
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
}
