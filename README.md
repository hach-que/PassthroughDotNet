# Build, run and test

1. Change the code signing key in `CodeSigning.Build.props` to match your development key. FSKit extensions can't be ad-hoc signed and `mount` will fail with `errorDomain error 2` if the filesystem extension binary isn't signed properly.
2. Update the application IDs in the projects so that:
  - The PassthroughAppEx uses an identifier you can register in the App Developer Portal and ends with `.AppEx`
  - The Passthrough project uses the same identifier but without the `.AppEx`. You don't need to create a provisioning profile/identifier in the portal for the main app; only the FSKit extension.
3. Go to the Apple Developer portal, and register the identifier you set for PassthroughAppEx with the FSKit Module entitlement enabled.
4. Create a provisioning profile in the developer portal for that new identifier, set the certificates/test devices appropriately, and then save the provisioning profile with a name like "Passthrough .NET FSKit Module".
5. In Xcode -> Settings -> Apple Accounts -> (your account) -> (your account under your team), click "Download Manual Profiles". This will sync the new provisioning profile to your Mac.
6. Update the code signing props file to match the name of your provisioning profile.
7. Run the steps below.

```
# Build the app and FS extension
dotnet publish -c Release -r osx-arm64 -p PublishAot=true Passthrough/Passthrough.csproj

# Make sure everything is code signed properly (you must see the 'TeamIdentifier' set in the output and the appex should have 'Internal requirements count=1')
codesign -dvvv ./Passthrough/bin/Release/net10.0-macos/osx-arm64/Passthrough.app
codesign -dvvv ./Passthrough/bin/Release/net10.0-macos/osx-arm64/Passthrough.app/Contents/PlugIns/PassthroughAppEx.appex

# Start the app to get the FS registered
open -a $(pwd)/Passthrough/bin/Release/net10.0-macos/osx-arm64/Passthrough.app

# Verify the FS extension is registered
pluginkit -m -v | grep PassthroughDotNet

# Attempt to mount the filesystem (you will need to enable the extension in System Settings the first time)
mkdir -p ./test/source
mkdir -p ./test/target
mount -F -t PassthroughDotNet ./test/source ./test/target
```