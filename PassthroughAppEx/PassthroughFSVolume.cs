#pragma warning disable APL0002

using FSKit;
using System;
using System.Collections.Generic;
using System.Text;

namespace PassthroughAppEx
{
    public class PassthroughFSVolume : FSVolume
    {
        private static NSUuid _defaultVolumeUuid = new NSUuid();

        public PassthroughFSVolume(string path)
            : base(
                  new FSVolumeIdentifier { Uuid = _defaultVolumeUuid },
                  new FSFileName(PassthroughFileSystem.CreateVolumeNameFromPath(path)))
        {
        }
    }
}
