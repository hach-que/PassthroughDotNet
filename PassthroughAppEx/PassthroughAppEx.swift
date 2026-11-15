import Foundation
import FSKit

extension Logger {
    static let passthroughfs = Logger(subsystem: "games.redpoint.PassthroughDotNet", category: "default")
}

// @main
struct PassthroughAppEx: UnaryFileSystemExtension {
    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        PassthroughFileSystem()
    }

    init() {
        Logger.passthroughfs.info("PassthroughAppEx.init called")
    }
}
