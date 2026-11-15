#!/bin/bash

set -e

# This script doesn't do first registration.

cd "$(dirname "$0")"

dotnet publish -c Release -r osx-arm64 -p PublishAot=true Passthrough/Passthrough.csproj

kill $(pidof PassthroughAppEx) || true

mkdir -p ./test/source
mkdir -p ./test/target
mount -F -t PassthroughDotNet ./test/source ./test/target