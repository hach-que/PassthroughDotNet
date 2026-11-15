#pragma warning disable APL0002

using Darwin;
using FSKit;
using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Text;
using CoreFoundation;

namespace PassthroughAppEx
{
    [Register("PassthroughFileSystem")]
    public class PassthroughFileSystem : FSUnaryFileSystem, IFSUnaryFileSystemOperations
    {
        public CoreFoundation.OSLog PassthroughLog = new CoreFoundation.OSLog("games.redpoint.PassthroughDotNet", "default");

        private FSPathUrlResource? _loadedResource;

        public PassthroughFileSystem()
        {
            PassthroughLog.Log("PassthroughFileSystem: init");
        }

        public static string CreateVolumeNameFromPath(string path)
        {
            var dirName = Path.GetFileName(path);
            return dirName + "_passthrough";
        }

        [Export("loadResource:options:replyHandler:")]
        public void LoadResource(FSResource resource, FSTaskOptions options, FSUnaryFileSystemOperationsLoadResourceResult replyHandler)
        {
            PassthroughLog.Log("PassthroughFileSystem: LoadResource");

            if (!(resource is FSPathUrlResource urlResource))
            {
                replyHandler(null, FSKitFunctions.GetErrorForPosixError((int)PosixError.EINVAL));
                return;
            }

            foreach (var opt in options.TaskOptions)
            {
                if (opt.Contains("-f"))
                {
                    replyHandler(null, FSKitFunctions.GetErrorForPosixError((int)PosixError.ENOTSUP));
                    return;
                }
            }

            if (!urlResource.Url.StartAccessingSecurityScopedResource())
            {
                replyHandler(null, FSKitFunctions.GetErrorForPosixError((int)PosixError.EACCES));
                return;
            }

            _loadedResource = urlResource;
            try
            {
                this.ContainerStatus = FSContainerStatus.Ready;
                replyHandler(new PassthroughFSVolume(urlResource.Url.Path!), null);
            }
            catch
            {
                urlResource.Url.StopAccessingSecurityScopedResource();
                _loadedResource = null;
                replyHandler(null, FSKitFunctions.GetErrorForPosixError((int)PosixError.EINVAL));
            }
        }

        [Export("unloadResource:options:replyHandler:")]
        public void UnloadResource(FSResource resource, FSTaskOptions options, FSUnaryFileSystemOperationsUnloadResourceResult reply)
        {
            PassthroughLog.Log("PassthroughFileSystem: UnloadResource");

            if (!(resource is FSPathUrlResource urlResource))
            {
                reply(FSKitFunctions.GetErrorForPosixError((int)PosixError.EINVAL));
                return;
            }
            if (_loadedResource == null)
            {
                reply(FSKitFunctions.GetErrorForPosixError((int)PosixError.EINVAL));
                return;
            }
            if (_loadedResource.Url != urlResource.Url)
            {
                reply(FSKitFunctions.GetErrorForPosixError((int)PosixError.EINVAL));
                return;
            }

            _loadedResource.Url.StopAccessingSecurityScopedResource();
            _loadedResource = null;

            reply(null);
            return;
        }

        [Export("probeResource:replyHandler:")]
        public void ProbeResource(FSResource resource, FSUnaryFileSystemOperationsProbeResourceResult replyHandler)
        {
            PassthroughLog.Log("PassthroughFileSystem: ProbeResource");

            if (resource is FSPathUrlResource urlResource)
            {
                var name = CreateVolumeNameFromPath(urlResource.Url.Path!);
                var containerUuid = new NSUuid();
                var containerIdentifier = new FSContainerIdentifier { Uuid = containerUuid };
                var probeResult = FSProbeResult.CreateUsableProbeResult(name, containerIdentifier);
                replyHandler(probeResult, null);
            }
            else
            {
                replyHandler(null, FSKitFunctions.GetErrorForPosixError((int)PosixError.ENODEV));
            }
        }
    }
}
