import Foundation
import ExtensionFoundation
import FSKit
import OSLog

struct PassthroughAppEx: UnaryFileSystemExtension {

    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations

    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        PassthroughFileSystem()
    }
}

extension Logger {
    static let passthroughfs = Logger(subsystem: "com.apple.fskit.PassthroughFS", category: "default")
}

/// Returns the current `errno` value as a `POSIXError`.
var posixErrno: POSIXError {
    POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
}

/// Returns the result of the given block, or throws an error if `errno` is nonzero.
/// - Parameter block: The block to execute.
func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    let ret = try block()
    guard ret >= 0 else {
        guard errno != 0 else {
            Logger.passthroughfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

/// Returns a volume name made from the directory name of given path with a `_passthroughfs` suffix.
/// - Parameter path: The path to use to generate a volume name.
func createVolumeNameFromPath(_ path: String) -> FSFileName {
    let dirName = (path as NSString).lastPathComponent
    return FSFileName(string: dirName + "_passthrough")
}

/// A file system that passes through all operations to the underlying file system from a given FSPathURLResource.
@objc
class PassthroughFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {

    var resource: FSPathURLResource?

    public override init() {
        Logger.passthroughfs.debug("\(#function): init")
    }

    /// Performs an operation to load a resource.
    /// - Parameters:
    ///   - resource: The resource to load.
    ///   - options: The options to use when loading the resource.
    ///   - replyHandler: The handler to call when load operation is complete with the volume, and any error.
    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Invalid resource type")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        /// Handle any options present.
        ///
        /// This Module doesn't make use of options for loading. The only option to handle
        /// is `-f`, and that is because this Module doesn't support formatting:
        ///   If the force option is present and the file system doesn't support
        ///   formatting, this method should reply with the POSIX error ENOTSUP.
        ///
        for opt in options.taskOptions {
            if opt.contains("-f") {
                return replyHandler(nil, POSIXError(.ENOTSUP))
            }
        }

        guard urlResource.url.startAccessingSecurityScopedResource() else {
            Logger.passthroughfs.error("\(#function): Can't start accessing security scoped resource")
            return replyHandler(nil, POSIXError(.EACCES))
        }

        self.resource = urlResource
        do {
            self.containerStatus = .ready
            return replyHandler(try PassthroughFSVolume(rootPath: urlResource.url.path), nil)
        } catch let error {
            urlResource.url.stopAccessingSecurityScopedResource()
            self.resource = nil
            return replyHandler(nil, error)
        }
    }

    ///  Performs an operation to unload a resource.
    /// - Parameters:
    ///   - resource: The resource to unload.
    ///   - options: The options to use when unloading the resource.
    ///   - replyHandler: The handler to call when unload is complete.
    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.error("\(#function): Can't cast resource")
            return reply(POSIXError(.EINVAL))
        }
        guard let loadedResource = self.resource else {
            Logger.passthroughfs.error("\(#function): No resource was loaded")
            return reply(POSIXError(.EINVAL))
        }
        guard loadedResource.url == urlResource.url else {
            Logger.passthroughfs.error("\(#function): Invalid resource was given to unload")
            return reply(POSIXError(.EINVAL))
        }
        loadedResource.url.stopAccessingSecurityScopedResource()
        self.resource = nil
        return reply(nil)
    }

    /// Performs a probe operation on a resource.
    /// - Parameters:
    ///   - resource: The resource to probe.
    ///   - replyHandler: The handler to call when the probe operation is complete.
    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Can't cast resource")
            return replyHandler(nil, POSIXError(.ENODEV))
        }

        let name            = createVolumeNameFromPath(urlResource.url.path())
        let containerUUID   = NSUUID()
        let containerIdentifier = FSContainerIdentifier(uuid: containerUUID as UUID)
        let probeResult = FSProbeResult.usable(name: name.string ?? "", containerID: containerIdentifier)
        return replyHandler(probeResult, nil)
    }

}

/// Defined item open modes.
enum PassthroughFSItemOpenMode: Int32 {
    /// Close mode
    case close = -1
    /// Read-only mode
    case readOnly = 0
    /// Read and write mode
    case readWrite = 1
}

/// A PassthroughFSItem represents a file system item.
class PassthroughFSItem: FSItem {

    /// File descriptor of the item
    var fileDescriptor: Int32
    /// Open mode of the item
    var openMode: PassthroughFSItemOpenMode
    /// Parent item (for a root item, the parent is nil)
    var parent: PassthroughFSItem?
    /// Name of the item
    var name: String
    /// Item type
    var itemType: FSItem.ItemType
    /// Inode of the item (used to cache items in PassthroughFSVolume)
    var inode: UInt64
    /// Dispatch queue for changing the item's PassthroughFSItemOpenMode
    var openModeQueue: DispatchQueue

    /// Creates a new instance of PassthroughFSItem, to create the root item.
    /// - Parameters:
    ///   - name: The name of the item.
    ///   - fileDescriptor: The file descriptor of the item.
    ///   - type: The type of the item.
    ///   - openFlags: The open mode of the item.
    init(name: String, fileDescriptor: Int32, type: FSItem.ItemType, openFlags: PassthroughFSItemOpenMode) {
        self.name           = name
        self.parent         = nil
        self.fileDescriptor = fileDescriptor
        self.itemType       = type
        self.openMode       = openFlags
        self.inode          = 0
        self.openModeQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.item.\(name).openmode.queue")
        super.init()
        try? self.initInode()
    }

    /// Creates a new instance of PassthroughFSItem.
    /// - Parameters:
    ///   - name: The name of the item.
    ///   - parent: The parent item.
    ///   - type: The type of the item.
    init(name: String, parent: PassthroughFSItem, type: FSItem.ItemType) throws {
        self.name           = name
        self.parent         = parent
        self.openMode       = .close
        self.fileDescriptor = -1
        self.itemType       = type
        self.inode          = 0
        self.openModeQueue  = DispatchQueue(label: "com.apple.fskit.passthroughfs.item.\(name).openmode.queue")
        super.init()
        try self.upgradeOpenMode(mode: .readOnly)
        try self.initInode()
        try self.closeItem()
    }

    /// Initializes the inode number of the item.
    private func initInode() throws {
        var statResult = stat()
        _ = try throwErrno { fstat(self.fileDescriptor, &statResult) }
        self.inode = statResult.st_ino
    }

    /// Opens the item with given mode using `openat`, and if successful, returns a new file descriptor, otherwise throwing errno.
    ///
    /// In order for `openat` to work, the file system needs the parent's item file descriptor. If the parent doesn't have one,
    /// this method opens the parent item to get its file descriptor. After opening the item,
    /// this closes the parent item file descriptor, if it wasn't open before.
    private func openWithMode(mode: PassthroughFSItemOpenMode) throws -> Int32 {
        guard let parent = self.parent else {
            Logger.passthroughfs.error("\(#function): The parent is nil, can't open the item (\(self.name))")
            return -1
        }
        var parentFD = parent.fileDescriptor
        let oldParentFD = parentFD

        // Check if the parent is open; if not, open it also.
        if oldParentFD == -1 {
            try parent.upgradeOpenMode(mode: .readOnly)
            parentFD = parent.fileDescriptor
        }

        // Convert PassthroughFSItemOpenMode to O_RDONLY/O_RDWR.
        var convertedMode = O_RDONLY
        if mode == .readWrite {
            convertedMode = O_RDWR
        }
        // Open the file.
        let fileDescriptor = try throwErrno { openat(parentFD, self.name, convertedMode | O_SYMLINK) }

        // If the parent was closed, before opening the file, close it.
        if oldParentFD == -1 {
            try parent.closeItem()
        }

        // Return the file descriptor of the item.
        return fileDescriptor
    }

    /// Upgrades the open mode of the item to the given mode.
    ///
    /// Upgrade means that the item can go from .close to .readOnly to .readWrite.
    /// If the item was opened to a .readOnly and needs to upgrade to .readWrite, this method creates a new file descriptor for the .readWrite mode,
    /// and closes the old .readOnly file descriptor.
    func upgradeOpenMode(mode: PassthroughFSItemOpenMode) throws {
        if mode == .close {
            Logger.passthroughfs.error("\(#function): Can't pass .close as mode")
            throw POSIXError(.EINVAL)
        }
        if (self.fileDescriptor != -1) && (self.openMode == .readWrite || self.openMode == mode) {
            // The item already has a file descriptor and mode is set, so there is nothing to do.
            return
        }

        try self.openModeQueue.sync {
            let oldFD = self.fileDescriptor
            try self.fileDescriptor = self.openWithMode(mode: mode)

            // With a new fileDescriptor set, close the old file descriptor if it exists.
            if oldFD > 0 {
                _ = try throwErrno { Darwin.close(oldFD) }
            }
            self.openMode = mode
        }
    }

    /// Closes the item by calling `close`.
    func closeItem() throws {
        try self.openModeQueue.sync {
            if self.fileDescriptor == -1 || self.openMode == .close {
                return
            }
            _ = try throwErrno { Darwin.close(self.fileDescriptor) }
            self.fileDescriptor = -1
            self.openMode = .close
        }
    }

}

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A PassthroughFSVolume represents a volume in the passthrough file system.
class PassthroughFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    /// The default UUID for the PassthroughFSVolume.
    static let defaultVolumeUUID = UUID()

    /// The root item of the volume.
    var rootItem: PassthroughFSItem

    /// The item cache stores items previously looked up or created;
    /// items are removed from the dictionary when the volume reclaims or removes the item.
    var itemCache: [UInt64: PassthroughFSItem]

    /// The item cache is accessed concurrently so the volume needs to serialize access to it.
    var itemCacheQueue: DispatchQueue

    /// Creates a new PassthroughFSVolume.
    /// - Parameter rootPath: The path to the root directory of the volume.
    init(rootPath: String) throws {
        let rootFD      = try throwErrno { Darwin.open(rootPath, O_RDONLY) }
        self.rootItem   = PassthroughFSItem(name: ".", fileDescriptor: rootFD, type: .directory, openFlags: .readOnly)
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.itemcache.queue")
        super.init(volumeID: FSVolume.Identifier(uuid: PassthroughFSVolume.defaultVolumeUUID), volumeName: createVolumeNameFromPath(rootPath))
        Logger.passthroughfs.info("\(#function): Created a new volume with ID(\(self.volumeID)) and name(\(self.name)) on path(\(rootPath))")
    }

    /// The PassthroughFS file system doesn't support setting a volume name, so this method does nothing and invokes its reply handler.
    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(name, nil)
    }

    /// Prealocates disk space for the given item using `fcntl`.
    /// - Parameters:
    ///   - item: The item to preallocate space for.
    ///   - offset: The file offset at which to preallocate space.
    ///   - length: The length of the preallocated space.
    ///   - flags: The preallocation flags.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func preallocateSpace(for item: FSItem,
                                 at offset: off_t,
                                 length: Int,
                                 flags: FSVolume.PreallocateFlags,
                                 replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        guard ptItem.itemType == .file else {
            Logger.passthroughfs.error("\(#function): Can only preallocate a file")
            return replyHandler(0, POSIXError(.EPERM))
        }

        var preallocStruct = fstore_t()
        preallocStruct.fst_bytesalloc = 0
        preallocStruct.fst_flags = UInt32(flags.rawValue)
        preallocStruct.fst_length = Int64(length)
        preallocStruct.fst_offset = Int64(offset)
        preallocStruct.fst_posmode = F_PEOFPOSMODE

        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readWrite)
        }
        var err: Error?
        if fcntl(ptItem.fileDescriptor, F_PREALLOCATE, &preallocStruct) == -1 {
            err = posixErrno
        }
        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(Int(preallocStruct.fst_bytesalloc), nil)
    }

    /// Reads the contents of the given file item using `pread`.
    /// - Parameters:
    ///   - item: The file item to read from.
    ///   - offset: The file offset at which to begin reading.
    ///   - length: The number of bytes to read.
    ///   - buffer: The buffer into which to read the data.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func read(from item: FSItem,
                     at offset: off_t,
                     length: Int,
                     into buffer: FSMutableFileDataBuffer,
                     replyHandler: @escaping (Int, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readOnly)
        }
        var err: Error?
        var actuallyRead = 0
        buffer.withUnsafeMutableBytes { rawBufferPointer in
            actuallyRead = pread(ptItem.fileDescriptor, rawBufferPointer.baseAddress, length, offset)

            // Check if the read operation was successful.
            if actuallyRead == -1 {
                err = posixErrno
            }
        }

        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyRead, nil)

    }

    /// Writes contents to the given file item using `pwrite`.
    /// - Parameters:
    ///   - contents: The data to write to the file item.
    ///   - item: The file item to write to.
    ///   - offset: The file offset at which to begin writing.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }

        guard ptItem.itemType != .directory else {
            Logger.passthroughfs.error("\(#function): Can't write to a folder")
            return replyHandler(0, POSIXError(.EISDIR))
        }

        let bytesPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: contents.count)
        contents.copyBytes(to: bytesPtr, count: contents.count)

        var err: Error?
        let actuallyWritten = pwrite(ptItem.fileDescriptor, bytesPtr, contents.count, off_t(offset))
        bytesPtr.deallocate()
        if actuallyWritten == -1 {
            err = posixErrno
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyWritten, nil)
    }

    /// Performs an `open` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to open.
    ///   - modes: The open modes.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func openItem(_ item: FSItem,
                         modes: FSVolume.OpenModes,
                         replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // root item is opened when creating the volume.
            return replyHandler(nil)
        }

        var ptfsMode: PassthroughFSItemOpenMode = .close
        if modes.contains(.read) {
            ptfsMode = .readOnly
        }
        if modes.contains(.write) {
            ptfsMode = .readWrite
        }

        do {
            try ptItem.upgradeOpenMode(mode: ptfsMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Performs a `close` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to close.
    ///   - modes: The open modes (ignored for PassthroughFS).
    ///   - replyHandler: The reply handler to invoke with the result.
    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // Root item is closed in deactivate volume.
            return replyHandler(nil)
        }

        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Get maximum link count using `fpathconf`.
    public var maximumLinkCount: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_LINK_MAX))
    }

    /// Get maximum name length using `fpathconf`.
    public var maximumNameLength: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_NAME_MAX))
    }

    /// Get whether the volume restricts ownership changes based on authorization using `fpathconf`.
    public var restrictsOwnershipChanges: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_CHOWN_RESTRICTED) == 1
    }

    /// Get whether the volume truncates files longer than its maximum supported length using `fpathconf`.
    public var truncatesLongNames: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_NO_TRUNC) == 0
    }

    /// Get the maximum file size in bits using `fpathconf`.
    public var maximumFileSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_FILESIZEBITS))
    }

    /// Get the maximum extended attribute size in bits using `fpathconf`.
    public var maximumXattrSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_XATTR_SIZE_BITS))
    }
}

/// A structure that holds common attributes for all items.
private struct CommonAttributes {
    var length: UInt32
    var backupTime: timespec
    var parentID: UInt64
    var addedTime: timespec

    init() {
        self.length = 0
        self.backupTime = timespec(tv_sec: 0, tv_nsec: 0)
        self.parentID = 0
        self.addedTime = timespec(tv_sec: 0, tv_nsec: 0)
    }
}

/// Implementing FSVolume.Operations.
extension PassthroughFSVolume: FSVolume.Operations {

    /// Returns volume statistics using `fstatfs`.
    public var volumeStatistics: FSStatFSResult {
        var statfsResult = statfs()
        let res = FSStatFSResult(fileSystemTypeName: String("passthroughfs"))
        if fstatfs(self.rootItem.fileDescriptor, &statfsResult) == -1 {
            return res
        }
        // Convert the statfs result to FSStatFSResult
        res.blockSize           = Int(statfsResult.f_bsize)
        res.ioSize              = Int(statfsResult.f_iosize)
        res.totalBlocks         = UInt64(statfsResult.f_blocks)
        res.availableBlocks     = UInt64(statfsResult.f_bavail)
        res.freeBlocks          = UInt64(statfsResult.f_bfree)
        res.usedBlocks          = res.totalBlocks - res.freeBlocks
        res.totalFiles          = UInt64(statfsResult.f_files)
        res.freeFiles           = UInt64(statfsResult.f_ffree)
        res.fileSystemSubType   = Int(statfsResult.f_fssubtype)
        return res
    }

    /// Activates the volume, but PassthroughFS volume activation doesn't need to do anything, so this method just replies with the root item.
    ///
    /// - Parameters
    ///   - options: The activation options.
    ///   - reply: The reply handler to invoke when the activation is complete.
    public func activate(options: FSTaskOptions,
                         replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        return reply(self.rootItem, nil)
    }

    /// Deactivates the volume, by closing the root item.
    /// - Parameters:
    ///   - options: The deactivation options.
    ///   - replyHandler: The reply handler to invoke when the deactivation is complete.
    public func deactivate(options: FSDeactivateOptions = [],
                           replyHandler: @escaping ((any Error)?) -> Void) {
        try? self.rootItem.closeItem()
        return replyHandler(nil)
    }

    /// Mount in PassthroughFSVolume doesn't need to do anything; implementation just replies with nil error.
    public func mount(options: FSTaskOptions,
                      replyHandler: @escaping (Error?) -> Void) {
        return replyHandler(nil)
    }

    /// Unmount closes the root item.
    public func unmount(replyHandler: @escaping () -> Void) {
        try? self.rootItem.closeItem()
        return replyHandler()
    }

    /// Performs synchronize using `fsync` on the root item, ignoring the FSSyncFlags flags, which PassthroughFS doesn't support.
    /// - Parameters
    ///   - flags: The sync flags.
    ///   - reply: The reply handler to invoke when the sync is complete.
    public func synchronize(flags: FSSyncFlags,
                            replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard fsync(self.rootItem.fileDescriptor) == 0 else {
            let err = posixErrno
            Logger.passthroughfs.error("\(#function): Failed to synchronize with error(\(err))")
            return reply(err)
        }
        return reply(nil)
    }

    private func getCommonAttributes(ptItem: PassthroughFSItem,
                                     desiredAttributes: FSItem.GetAttributesRequest) throws -> CommonAttributes {

        var attrgroupFlags: Int32 = 0
        if desiredAttributes.isAttributeWanted(.parentID) {
            attrgroupFlags |= ATTR_CMN_PARENTID
        }
        if desiredAttributes.isAttributeWanted(.addedTime) {
            attrgroupFlags |= ATTR_CMN_ADDEDTIME
        }
        if desiredAttributes.isAttributeWanted(.backupTime) {
            attrgroupFlags |= ATTR_CMN_BKUPTIME
        }
        let commonAttrsWanted = attrgroup_t(attrgroupFlags)
        var attrList = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: commonAttrsWanted,
                                volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var commonAttrsBuf = CommonAttributes()

        if attrgroupFlags != 0 {
            if fgetattrlist(ptItem.fileDescriptor, &attrList, &commonAttrsBuf, MemoryLayout<CommonAttributes>.size, UInt32(FSOPT_NOFOLLOW)) == -1 {
                throw posixErrno
            }
        }
        return commonAttrsBuf
    }

    /// Fetches attributes for the given item.
    /// The method uses `stat`, and `fgetattrlist` to get the attributes.
    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                              of item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't open given item (\(ptItem.name)) error (\(error))")
                return replyHandler(nil, error)
            }
        }

        var statResult = stat()
        if fstat(ptItem.fileDescriptor, &statResult) == -1 {
            replyHandler(nil, posixErrno)
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
            return
        }

        var commonAttrsBuf: CommonAttributes
        do {
            commonAttrsBuf = try self.getCommonAttributes(ptItem: ptItem, desiredAttributes: desiredAttributes)
        } catch {
            Logger.passthroughfs.error("\(#function): Can't get commont attributes for item (\(ptItem.name))")
            replyHandler(nil, error)
            if oldItemFD == -1 {
                try? ptItem.closeItem()
            }
            return
        }

        let attrs = FSItem.Attributes()

        if desiredAttributes.isAttributeWanted(.uid) {
            attrs.uid = statResult.st_uid
        }

        if desiredAttributes.isAttributeWanted(.gid) {
            attrs.gid = statResult.st_gid
        }

        if desiredAttributes.isAttributeWanted(.mode) {
            attrs.mode = UInt32(Int32(statResult.st_mode) & modeAllBits)
        }

        if desiredAttributes.isAttributeWanted(.linkCount) {
            attrs.linkCount = UInt32(statResult.st_nlink)
        }

        if desiredAttributes.isAttributeWanted(.flags) {
            attrs.flags = statResult.st_flags
        }

        if desiredAttributes.isAttributeWanted(.size) {
            attrs.size = UInt64(statResult.st_size)
        }

        if desiredAttributes.isAttributeWanted(.allocSize) {
            attrs.allocSize = UInt64(statResult.st_blocks) * UInt64(statResult.st_blksize)
        }

        if desiredAttributes.isAttributeWanted(.fileID) {
            attrs.fileID = FSItem.Identifier(rawValue: statResult.st_ino) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.parentID) {
            attrs.parentID = FSItem.Identifier(rawValue: commonAttrsBuf.parentID) ?? .invalid
        }

        if desiredAttributes.isAttributeWanted(.type) {
            attrs.type = ptItem.itemType
        }

        var timeSpec: timespec

        if desiredAttributes.isAttributeWanted(.accessTime) {
            timeSpec = statResult.st_atimespec
            attrs.accessTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.changeTime) {
            timeSpec = statResult.st_ctimespec
            attrs.changeTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.modifyTime) {
            timeSpec = statResult.st_mtimespec
            attrs.modifyTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.addedTime) {
            timeSpec = commonAttrsBuf.addedTime
            attrs.addedTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.birthTime) {
            timeSpec = statResult.st_birthtimespec
            attrs.birthTime = timeSpec
        }

        if desiredAttributes.isAttributeWanted(.backupTime) {
            timeSpec = commonAttrsBuf.backupTime
            attrs.backupTime = timeSpec
        }

        replyHandler(attrs, nil)

        if oldItemFD == -1 {
            try? ptItem.closeItem()
        }
    }

    /// Set item attributes.
    /// The method uses `ftruncate`, `fchmod`, `futimes`, `fchown`, and `fchflags`  to set the attributes.
    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              creatingNewFile: Bool,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        // Check that this request doesn't attempt to change read-only fields, raising an error if it does.
        if (creatingNewFile == false) &&
            (newAttributes.isValid(.type) || newAttributes.isValid(.linkCount) ||
             newAttributes.isValid(.allocSize) || newAttributes.isValid(.fileID) ||
             newAttributes.isValid(.parentID) || newAttributes.isValid(.changeTime)) {
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        if newAttributes.isValid(.mode) && ((Int32(newAttributes.mode) & ~modeAllBits) != 0) {
            // Bits outside of the supported mode bits are specified.
            Logger.passthroughfs.error("\(#function): Invalid mode bits for item (\(ptItem.name)), returning EINVAL")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        var getAttrs: FSItem.Attributes?
        var getAttrsError: Error?
        let getAttrRequest: FSItem.GetAttributesRequest = FSItem.GetAttributesRequest()
        getAttrRequest.wantedAttributes = [.gid, .uid, .mode, .size, .allocSize,
                                           .type, .fileID, .parentID, .flags,
                                           .linkCount, .accessTime, .birthTime,
                                           .modifyTime, .changeTime]

        if newAttributes.isValid(.accessTime) ||
            newAttributes.isValid(.modifyTime) ||
            newAttributes.isValid(.uid)        ||
            newAttributes.isValid(.gid) {
            self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
                getAttrsError = error
                getAttrs = attrs
            }
            if getAttrsError != nil {
                return replyHandler(nil, getAttrsError)
            }
        }

        let oldItemFD = ptItem.fileDescriptor
        if oldItemFD == -1 {
            do {
                try ptItem.upgradeOpenMode(mode: .readOnly)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set item attributes")
                return replyHandler(nil, error)
            }
        }

        if newAttributes.isValid(.size) {
            if ptItem.itemType != FSItem.ItemType.file {
                Logger.passthroughfs.error("\(#function): Can't change size of non file item (\(ptItem))")
                return replyHandler(nil, fs_errorForPOSIXError(EPERM))
            }
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to ftruncate")
                return replyHandler(nil, error)
            }
            if ftruncate(ptItem.fileDescriptor, Int64(newAttributes.size)) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        if newAttributes.isValid(.mode) {
            let updatedMode = ((Int32(newAttributes.mode) & modeAllBits))
            if fchmod(ptItem.fileDescriptor, mode_t(updatedMode)) < 0 {
                return replyHandler(nil, posixErrno)
            }
        }

        if newAttributes.isValid(.accessTime) || newAttributes.isValid(.modifyTime) {
            let times = UnsafeMutablePointer<timeval>.allocate(capacity: 2)
            var accessTime = timespec(tv_sec: 0, tv_nsec: 0)
            var modifyTime = timespec(tv_sec: 0, tv_nsec: 0)

            if newAttributes.isValid(.accessTime) {
                accessTime = newAttributes.accessTime
            } else {
                accessTime = getAttrs!.accessTime
            }

            if newAttributes.isValid(.modifyTime) {
                modifyTime = newAttributes.modifyTime
            } else {
                modifyTime = getAttrs!.modifyTime
            }

            times[0] = timeval(tv_sec: accessTime.tv_sec, tv_usec: (__darwin_suseconds_t)(accessTime.tv_nsec / 1000))
            times[1] = timeval(tv_sec: modifyTime.tv_sec, tv_usec: (__darwin_suseconds_t)(modifyTime.tv_nsec / 1000))
            do {
                try ptItem.upgradeOpenMode(mode: .readWrite)
            } catch {
                Logger.passthroughfs.error("\(#function): Can't upgrade item (\(ptItem.name)) to set futimes")
                return replyHandler(nil, error)
            }
            if futimes(ptItem.fileDescriptor, times) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
            times.deallocate()
        }

        if newAttributes.isValid(.flags) {
            let supportedBSDFlags = (UF_IMMUTABLE | UF_HIDDEN)
            if newAttributes.flags & ~UInt32(supportedBSDFlags) != 0 {
                Logger.passthroughfs.error("\(#function): invalid BSD flags (\(newAttributes.flags))")
                replyHandler(nil, fs_errorForPOSIXError(EINVAL))
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
            if fchflags(ptItem.fileDescriptor, newAttributes.flags) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        // Change the owner attribute last, since doing so earlier may prevent changing other things.
        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            var newUid: uid_t = 0
            var newGid: gid_t = 0

            if newAttributes.isValid(.uid) {
                newUid = newAttributes.uid
            } else {
                newUid = getAttrs!.uid
            }

            newGid = newAttributes.isValid(.gid) ? newAttributes.gid : getAttrs!.gid

            if fchown(ptItem.fileDescriptor, newUid, newGid) < 0 {
                replyHandler(nil, posixErrno)
                if oldItemFD == -1 {
                    try? ptItem.closeItem()
                }
                return
            }
        }

        self.getAttributes(getAttrRequest, of: item) { (attrs, error) in
            getAttrsError = error
            getAttrs = attrs
        }
        replyHandler(getAttrs, getAttrsError)

        if oldItemFD == -1 {
            try? ptItem.closeItem()
        }
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                              on item: FSItem,
                              replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        return self.setAttributes(newAttributes, on: item, creatingNewFile: false, replyHandler: replyHandler)
    }

    /// Performs a lookup on the given directory for the given name.
    /// Lookup is done by `fstatat`. If the item isn't in in the volume's item cache,  add it.
    /// - Parameters:
    ///   - name: The name of the item to lookup.
    ///   - directory: The directory to search.
    ///   - replyHandler: The handler to call when the lookup is complete.
    public func lookupItem(named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast directory")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        guard let nameString = name.string else {
            Logger.passthroughfs.error("\(#function): Can't cast name to string")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        // Check if item exists in item cache.
        let type: FSItem.ItemType
        var statResult = stat()
        let oldFD = dirItem.fileDescriptor
        do {
            if oldFD < 0 {
                try? dirItem.upgradeOpenMode(mode: .readOnly)
            }
            _ = try throwErrno { fstatat(dirItem.fileDescriptor, nameString, &statResult, AT_SYMLINK_NOFOLLOW) }
            if oldFD < 0 {
                try? dirItem.closeItem()
            }
            let inode = statResult.st_ino
            var val: PassthroughFSItem?
            self.itemCacheQueue.sync {
                val = self.itemCache[inode]
            }
            if val != nil {
                return replyHandler(val, nil, nil)
            }
            switch statResult.st_mode & S_IFMT {
            case S_IFDIR:
                type = FSItem.ItemType.directory
            case S_IFLNK:
                type = FSItem.ItemType.symlink
            default:
                type = FSItem.ItemType.file
            }
        } catch {
            return replyHandler(nil, nil, error)
        }

        // Item isn't in the item cache, create a new item, update the cache,  and return it.
        var newItem: PassthroughFSItem
        do {
            newItem = try PassthroughFSItem(name: nameString, parent: dirItem, type: type)
        } catch {
            Logger.passthroughfs.error("\(#function): Can't create new item (\(name.debugDescription)) error (\(error)")
            return replyHandler(nil, nil, error)
        }

        if newItem.inode != 0 {
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
        }
        return replyHandler(newItem, name, nil)
    }

    /// Performs reclamation of an item, by removing the item from the item cache, and closing it.
    /// - Parameters:
    ///   - item: The item to be reclaimed.
    ///   - replyHandler: The reply handler to invoke.
    public func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }

        _ = self.itemCacheQueue.sync {
            self.itemCache.removeValue(forKey: ptItem.inode)
        }
        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Reads a symbolic link, by calling `freadlink`.
    /// - Parameters
    ///   - item: The item to be read.
    ///   - replyHandler: The reply handler to invoke.
    public func readSymbolicLink(_ item: FSItem,
                                 replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readOnly)
        }
        let buf = UnsafeMutablePointer<UTF8>.allocate(capacity: maxSymlinkSize)
        let bytesRead = freadlink(ptItem.fileDescriptor, buf, maxSymlinkSize)
        if bytesRead < 0 {
            buf.deallocate()
            replyHandler(nil, posixErrno)
            if oldFD < 0 {
                try? ptItem.upgradeOpenMode(mode: .close)
            }
            return
        }
        let data = Data(bytes: buf, count: bytesRead)
        buf.deallocate()
        replyHandler(FSFileName(data: data), nil)
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .close)
        }
    }

    /// Performs the creation of a new item in the specified directory, using `mkdirat` and `openat`.
    /// - Parameters:
    ///   - name: The name of the item to create.
    ///   - type: The type of the item to create.
    ///   - directory: The directory in which to create the item.
    ///   - newAttributes: The attributes of the new item.
    ///   - replyHandler: The reply handler to invoke.
    public func createItem(named name: FSFileName,
                           type: FSItem.ItemType,
                           inDirectory directory: FSItem,
                           attributes newAttributes: FSItem.SetAttributesRequest,
                           replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast dirItem")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        guard let nameString = name.string else {
            Logger.passthroughfs.error("\(#function): Invalid name string (\(name.debugDescription))")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        if (type == .file || type == .symlink) && !newAttributes.isValid(.mode) {
            Logger.passthroughfs.error("\(#function): attributes doesn't contain a valid mode.")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        let oldDirItemFD = dirItem.fileDescriptor
        if oldDirItemFD < 0 {
            try? dirItem.upgradeOpenMode(mode: .readOnly)
        }

        var newItem: PassthroughFSItem
        var error: Int32 = -1
        var fileDescriptor: Int32 = -1
        nameString.withCString({ namePtr in
            switch type {
            case FSItem.ItemType.directory:
                error = mkdirat(dirItem.fileDescriptor, namePtr, S_IRWXU)
            case FSItem.ItemType.file:
                let createFlags = O_RDWR | O_CREAT | O_NOFOLLOW | O_SYMLINK | O_EXCL
                fileDescriptor = openat(dirItem.fileDescriptor, namePtr, createFlags, S_IRWXU)
                if fileDescriptor >= 0 {
                    // Closing the fd, as we're about to open the file again when creating the item.
                    // (that way we have the same flow for files and dirs).
                    error = Darwin.close(fileDescriptor)
                } else {
                    error = -1
                }
            default:
                error = -1
                errno = EINVAL
            }
        })
        guard error != -1 else {
            return replyHandler(nil, nil, posixErrno)
        }

        if oldDirItemFD < 0 {
            try? dirItem.closeItem()
        }

        do {
            try newItem = PassthroughFSItem(name: nameString, parent: dirItem, type: type)
        } catch {
            return replyHandler(nil, nil, error)
        }

        self.setAttributes(newAttributes, on: newItem, creatingNewFile: true, replyHandler: { (attrs, error) -> Void in
            guard error == nil else {
                return replyHandler(nil, nil, error)
            }
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, error)
        })
    }

    /// Creates a new symbolic link using `symlinkat`.
    /// - Parameters:
    ///   - name: The name of the file to create.
    ///   - directory: The directory in which to create the symbolic link.
    ///   - newAttributes: The attributes to set on the newly created item.
    ///   - contents: The contents of the symbolic link.
    ///   - replyHandler: The handler to invoke when the operation completes.
    public func createSymbolicLink(named name: FSFileName,
                                   inDirectory directory: FSItem,
                                   attributes newAttributes: FSItem.SetAttributesRequest,
                                   linkContents contents: FSFileName,
                                   replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard contents.data.isEmpty == false else {
            Logger.passthroughfs.error("\(#function): got invalid contents")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast dirItem")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard dirItem != self.rootItem && dirItem.itemType != .directory else {
            Logger.passthroughfs.error("\(#function): Invalid directory given")
            return replyHandler(nil, nil, POSIXError(.ENOTDIR))
        }
        guard newAttributes.isValid(.mode) != false else {
            Logger.passthroughfs.error("\(#function): attributes don't contain a valid mode.")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            Logger.passthroughfs.error("\(#function): Invalid name given")
            return replyHandler(nil, nil, POSIXError(.EINVAL))
        }

        var newItem: PassthroughFSItem
        var error: Int32 = -1
        nameString.withCString({ namePtr in
            let contentsString = String(decoding: contents.data, as: Unicode.UTF8.self)
            error = symlinkat(contentsString, dirItem.fileDescriptor, namePtr)
        })
        if error == -1 {
            return replyHandler(nil, nil, posixErrno)
        }

        do {
            try newItem = PassthroughFSItem(name: nameString, parent: dirItem, type: FSItem.ItemType.symlink)
        } catch {
            return replyHandler(nil, nil, error)
        }

        self.setAttributes(newAttributes, on: newItem, creatingNewFile: true, replyHandler: { (attrs, error) -> Void in
            guard error != nil else {
                return replyHandler(nil, nil, error)
            }
            self.itemCacheQueue.sync {
                self.itemCache[newItem.inode] = newItem
            }
            return replyHandler(newItem, name, error)
        })
    }

    /// Creation of hard links aren't support for PassthroughFS.
    public func createLink(to item: FSItem,
                           named name: FSFileName,
                           inDirectory directory: FSItem,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        return replyHandler(nil, POSIXError(.ENOTSUP))
    }

    /// Performs the actual removal of the given item from the given directory.
    /// - Parameters:
    ///   - item: The item to remove.
    ///   - name: The name of the item to remove.
    ///   - directory: The directory in which the item should be removed.
    ///   - replyHandler: The handler to call when the removal is complete.
    public func removeItem(_ item: FSItem,
                           named name: FSFileName,
                           fromDirectory directory: FSItem,
                           replyHandler: @escaping (Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast dirItem")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard let nameString = name.string else {
            Logger.passthroughfs.error("\(#function): Invalid name given")
            return replyHandler(POSIXError(.EINVAL))
        }

        let unlinkFlags = (ptItem.itemType == FSItem.ItemType.directory) ? AT_REMOVEDIR : 0
        var error: Int32 = -1

        let oldDirItemFD = dirItem.fileDescriptor
        if oldDirItemFD < 0 {
            try? dirItem.upgradeOpenMode(mode: .readOnly)
        }
        nameString.withCString({ namePtr in
            error = unlinkat(dirItem.fileDescriptor, namePtr, unlinkFlags)
        })
        if error == -1 {
            return replyHandler(posixErrno)
        }

        // Remove from item cache the item.
        if ptItem.inode != 0 {
            _ = self.itemCacheQueue.sync {
                self.itemCache.removeValue(forKey: ptItem.inode)
            }
        }
        replyHandler(nil)

        // Close the directory, since it was closed when the call entered this method.
        if oldDirItemFD < 0 {
            try? dirItem.closeItem()
        }
    }

    /// Performs a rename operation on a file system item.
    /// - Parameters:
    ///   - item: The file system item to rename.
    ///   - sourceDirectory: The directory containing the source file system item.
    ///   - sourceName: The name of the item to rename.
    ///   - destinationName: The name of the destination file system item.
    ///   - destinationDirectory: The directory to move the item into.
    ///   - overItem: The item that should be overwritten if it already exists.
    ///   - replyHandler: The reply handler to call when the operation is complete.
    public func renameItem(_ item: FSItem,
                           inDirectory sourceDirectory: FSItem,
                           named sourceName: FSFileName,
                           to destinationName: FSFileName,
                           inDirectory destinationDirectory: FSItem,
                           overItem: FSItem?,
                           replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        guard let fromItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast sourceName")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let fromDir = sourceDirectory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast sourceDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        guard let toDir = destinationDirectory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast destinationDirectory")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        let fromItemInode = fromItem.inode

        var toItemInode: UInt64 = 0
        if overItem != nil {
            guard let toItem = overItem as? PassthroughFSItem else {
                Logger.passthroughfs.error("\(#function): Can't cast toItem")
                return replyHandler(nil, POSIXError(.EINVAL))
            }
            toItemInode = toItem.inode
        }
        // Perform rename call.
        var retVal: Int32 = -1
        let sourceString = sourceName.string
        let destinationString = destinationName.string
        sourceString!.withCString { fromName in
            destinationString!.withCString { toName in
                retVal = renameatx_np(fromDir.fileDescriptor, fromName, toDir.fileDescriptor, toName, 0)
            }
        }

        if retVal == -1 {
            return replyHandler(nil, posixErrno)
        }

        // Update fromItem.
        fromItem.name = destinationString!
        fromItem.parent = toDir
        // Update itemCache
        self.itemCacheQueue.sync {
            // Remove old inode.
            self.itemCache.removeValue(forKey: fromItemInode)
            // Add new inode.
            self.itemCache[fromItem.inode] = fromItem
        }

        // If overItem did exist, remove it from the item cache
        if overItem != nil && overItem != fromItem {
            if toItemInode != 0 {
                _ = self.itemCacheQueue.sync {
                    self.itemCache.removeValue(forKey: toItemInode)
                }
            }
        }
        return replyHandler(destinationName, nil)
    }

    /// Performs an enumeration of the contents of a directory.
    /// - Parameters:
    ///   - directory: The directory to enumerate.
    ///   - cookie: The cookie returned by a previous call to enumerateDirectory().
    ///   - verifier: The directory verifier.
    ///   - attributes: The attributes to request for each item in the directory.
    ///   - packer: The packer to use to serialize directory entries.
    ///   - replyHandler: The handler to call when the enumeration is complete.
    public func enumerateDirectory(_ directory: FSItem,
                                   startingAt cookie: FSDirectoryCookie,
                                   verifier: FSDirectoryVerifier,
                                   attributes: FSItem.GetAttributesRequest?,
                                   packer: FSDirectoryEntryPacker,
                                   replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        guard let dirItem = directory as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast directory")
            return replyHandler(FSDirectoryVerifier(0), POSIXError(.EINVAL))
        }

        if dirItem.itemType != .directory {
            Logger.passthroughfs.error("\(#function): given item isn't a directory")
            return replyHandler(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }

        let oldFD = dirItem.fileDescriptor
        if oldFD == -1 {
            try? dirItem.upgradeOpenMode(mode: .readOnly)
        }

        let dirp = fdopendir(dirItem.fileDescriptor)
        if dirp == nil {
            return replyHandler(FSDirectoryVerifier(0), posixErrno)
        }
        if cookie.rawValue == 0 {
            rewinddir(dirp)
        } else {
            seekdir(dirp, Int(cookie.rawValue))
        }

        var dirent: UnsafeMutablePointer<dirent>? = readdir(dirp)
        while dirent != nil {
            guard let safeDirent = dirent else {
                dirent = readdir(dirp)
                continue
            }

            // Extract the filename from the C structure.
            let filename = withUnsafePointer(to: &safeDirent.pointee.d_name) { namePtr -> String in
                let nameLength = Int(safeDirent.pointee.d_namlen)
                let capacity = MemoryLayout<UInt8>.size * nameLength
                return namePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { arrayPtr in
                    return String(cString: arrayPtr)
                }
            }

            if filename == "." || filename == ".." {
                dirent = readdir(dirp)
                continue
            }

            var fsItemType = FSItem.ItemType.file
            let type = safeDirent.pointee.d_type
            if type == DT_DIR {
                fsItemType = FSItem.ItemType.directory
            }
            let itemID = safeDirent.pointee.d_ino
            let nextCookie = telldir(dirp)
            var itemAttributes: FSItem.Attributes? = nil
            dirent = readdir(dirp)
            if attributes != nil {
                self.lookupItem(named: FSFileName(string: filename), inDirectory: dirItem) { lookupItem, itemName, error in
                    if error == nil {
                        self.getAttributes(attributes!, of: lookupItem!) { innerItemAttributes, innerError in
                            if innerError == nil {
                                itemAttributes = innerItemAttributes
                            } else {
                                Logger.passthroughfs.error("\(#function): Can't get attributes of \(filename)")
                            }
                        }
                    } else {
                        Logger.passthroughfs.error("\(#function): Can't lookup \(filename)")
                    }
                }
            }
            let packerRes = packer.packEntry(name: FSFileName(string: filename),
                                             itemType: fsItemType,
                                             itemID: FSItem.Identifier(rawValue: itemID) ?? FSItem.Identifier.invalid,
                                             nextCookie: FSDirectoryCookie(UInt64(nextCookie)),
                                             attributes: itemAttributes)
            if packerRes == false {
                break
            }
        }

        if oldFD == -1 {
            try? dirItem.closeItem()
        }

        return replyHandler(FSDirectoryVerifier(0), nil)
    }

    /// Returns `true` if the volume supports the specified capability, otherwise returns `false`.
    /// - Parameter capability: The capability to check.
    private func volumeSupportsCapability(capability: Int32) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = UInt32(ATTR_VOL_CAPABILITIES)

        let lenSize = MemoryLayout<UInt32>.size
        let size = lenSize + MemoryLayout<vol_capabilities_attr_t>.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
        defer { buffer.deallocate() }
        if fgetattrlist(self.rootItem.fileDescriptor, &attrs, buffer, size, 0) == -1 {
            return false
        }

        let attrPtr = (buffer + lenSize).assumingMemoryBound(to: vol_capabilities_attr_t.self)
        let validClone = (attrPtr.pointee.valid.1 & UInt32(capability)) != 0
        let capClone = (attrPtr.pointee.capabilities.1 & UInt32(capability)) != 0
        return validClone && capClone
    }

    /// The set of volume capabilities supported by this instance.
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsSymbolicLinks                  = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SYMBOLICLINKS)
        capabilities.supportsHardLinks                      = self.volumeSupportsCapability(capability: VOL_CAP_FMT_HARDLINKS)
        capabilities.supportsHiddenFiles                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_HIDDEN_FILES)
        capabilities.supportsPersistentObjectIDs            = self.volumeSupportsCapability(capability: VOL_CAP_FMT_PERSISTENTOBJECTIDS)
        capabilities.supportsJournal                        = self.volumeSupportsCapability(capability: VOL_CAP_FMT_JOURNAL)
        capabilities.supportsActiveJournal                  = self.volumeSupportsCapability(capability: VOL_CAP_FMT_JOURNAL_ACTIVE)
        capabilities.supportsSparseFiles                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SPARSE_FILES)
        capabilities.supportsZeroRuns                       = self.volumeSupportsCapability(capability: VOL_CAP_FMT_ZERO_RUNS)
        capabilities.supportsFastStatFS                     = self.volumeSupportsCapability(capability: VOL_CAP_FMT_FAST_STATFS)
        capabilities.supports2TBFiles                       = self.volumeSupportsCapability(capability: VOL_CAP_FMT_2TB_FILESIZE)
        capabilities.supportsOpenDenyModes                  = self.volumeSupportsCapability(capability: VOL_CAP_FMT_OPENDENYMODES)
        capabilities.supports64BitObjectIDs                 = self.volumeSupportsCapability(capability: VOL_CAP_FMT_64BIT_OBJECT_IDS)
        capabilities.supportsDocumentID                     = self.volumeSupportsCapability(capability: VOL_CAP_FMT_DOCUMENT_ID)
        capabilities.supportsSharedSpace                    = self.volumeSupportsCapability(capability: VOL_CAP_FMT_SHARED_SPACE)
        capabilities.supportsVolumeGroups                   = self.volumeSupportsCapability(capability: VOL_CAP_FMT_VOL_GROUPS)
        capabilities.doesNotSupportVolumeSizes              = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_VOLUME_SIZES)
        capabilities.doesNotSupportImmutableFiles           = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_IMMUTABLE_FILES)
        capabilities.doesNotSupportRootTimes                = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_ROOT_TIMES)
        capabilities.doesNotSupportSettingFilePermissions   = self.volumeSupportsCapability(capability: VOL_CAP_FMT_NO_PERMISSIONS)
        // Determine caseSensitivity:
        if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_SENSITIVE) {
            capabilities.caseFormat = FSVolume.CaseFormat.sensitive
        } else if self.volumeSupportsCapability(capability: VOL_CAP_FMT_CASE_PRESERVING) {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitiveCasePreserving
        } else {
            capabilities.caseFormat = FSVolume.CaseFormat.insensitive
        }
        return capabilities
    }

}
