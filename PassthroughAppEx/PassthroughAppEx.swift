import Foundation
import FSKit

@main
struct PassthroughAppEx: UnaryFileSystemExtension {

    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        PassthroughFileSystem()
    }
}
