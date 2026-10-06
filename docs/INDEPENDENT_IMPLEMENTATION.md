# NineFin — Independent Implementation Policy

NineFin is an independently implemented Jellyfin client for legacy iOS 9 devices.

NineFin is distributed under the MIT License.

## Implementation policy

NineFin source code must be written independently using:

- public Jellyfin API documentation;
- Jellyfin's public OpenAPI/generated SDK documentation;
- Apple platform documentation;
- observed behavior of a Jellyfin server;
- original testing performed with NineFin;
- independently designed application architecture.

Other Jellyfin clients may be examined at a feature level to understand what
capabilities exist in the ecosystem.

Their source code must not be copied, translated, adapted, or incorporated into
NineFin when doing so would introduce incompatible licensing requirements.

In particular, GPL-licensed client implementations are not implementation
sources for NineFin.

A feature observed elsewhere may be independently reimplemented in NineFin,
provided the NineFin implementation is derived from public API/platform
documentation and original engineering work.

## Download implementation

NineFin's offline-download implementation is based on public interfaces:

- Jellyfin `GET /Items/{itemId}/Download`
- Apple `NSURLSession` / `NSURLSessionDownloadTask`
- the iOS application sandbox
- Foundation file-management APIs

The implementation is written specifically for NineFin in Objective-C and
targets the existing NineFin compatibility requirements:

- iOS 9.0+
- ARMv7 / 32-bit
- Theos
- iOS 9.2 SDK
- ARC

## Technical references

Jellyfin API:

- https://api.jellyfin.org/
- https://github.com/jellyfin/jellyfin-sdk-typescript

Apple Foundation networking:

- https://developer.apple.com/documentation/foundation/nsurlsession
- https://developer.apple.com/documentation/foundation/nsurlsessiondownloadtask

Apple media frameworks:

- https://developer.apple.com/documentation/avfoundation

## Project rule

When adding a feature inspired by another client:

1. describe the desired behavior;
2. identify the relevant public Jellyfin and Apple APIs;
3. design the NineFin implementation independently;
4. write new NineFin code;
5. test against a real Jellyfin server and legacy device;
6. document non-obvious compatibility decisions.

Do not port code line-by-line between differently licensed clients.
