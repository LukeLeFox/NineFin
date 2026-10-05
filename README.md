# NineFin — Jellyfin client for legacy iOS 9

**NineFin is a native Jellyfin client for legacy iPhone and iPad devices running iOS 9.**  
It is written in Objective-C with Theos and targets 32-bit ARMv7 devices such as the iPhone 4S and older iPads.

NineFin is designed for people who want to keep using Jellyfin on legacy iOS hardware without relying on a modern browser or a current App Store client.

## Download prebuilt IPA

Prebuilt IPA files are provided in the GitHub Releases section, so you do **not** need to compile NineFin yourself if you only want to install the app.

**Latest release:** https://github.com/LukeLeFox/NineFin/releases/latest

Current tested release:

- NineFin 0.7.2
- Bundle ID: `dev.luke.ninefin`
- iOS 9.0+
- ARMv7
- Prebuilt IPA included in the release assets

> On legacy iOS 9 hardware, installation requires a compatible IPA sideload method. A jailbroken device with AppSync Unified is the recommended setup used during NineFin testing.

## Features

- Jellyfin server login with credentials and sessions stored in the iOS Keychain
- Multiple saved servers and a selectable default server
- Home sections for Continue Watching, Next Up, recent movies, and recent series
- Library browsing, discovery, global search, and favorites
- Native HLS playback with configurable streaming quality
- Playback progress synchronization with Jellyfin
- Correct playback-completion reporting and watched-state handling
- Audio-track and subtitle selection
- iPhone and iPad icon assets for iOS 9

## Compatibility

NineFin is specifically intended as a **Jellyfin client for legacy iOS devices**.

- Deployment target: iOS 9.0
- Architecture: ARMv7 / 32-bit
- Toolchain SDK target: iOS 9.2
- Package format: IPA
- Tested on legacy iPhone/iPad hardware

The project intentionally keeps its legacy deployment settings in the `Makefile`. Changing the target SDK, deployment target, or architecture can break compatibility with the devices this app is intended to support.

## Build from source

Install [Theos](https://theos.dev/docs/installation) with an iOS 9.2 SDK, then run:

```sh
FINALPACKAGE=1 make package
```

The generated IPA is written to `packages/`. Build output, IPA files, local logs, and backup files are excluded from version control.

If you do not want to build from source, use the precompiled IPA from:

https://github.com/LukeLeFox/NineFin/releases/latest

## Search keywords

NineFin may also be useful to people searching for:

- Jellyfin iOS 9
- Jellyfin iPhone 4S
- Jellyfin legacy iOS client
- Jellyfin ARMv7
- Jellyfin old iPhone
- Jellyfin old iPad
- Jellyfin IPA
- Jellyfin client for jailbroken iOS

## Server security

NineFin permits arbitrary network loads so it can connect to legacy and local Jellyfin deployments. Prefer HTTPS whenever the server supports it, especially outside a trusted local network.

## Project website

A lightweight project page is included under `docs/` and can be published with GitHub Pages.

Expected GitHub Pages URL:

https://lukelefox.github.io/NineFin/

## Disclaimer

NineFin is an independent community project and is not affiliated with or endorsed by Jellyfin.

Jellyfin is a trademark of its respective owners.

## License

NineFin is available under the [MIT License](LICENSE).
