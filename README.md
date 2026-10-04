# NineFin

NineFin is a native Jellyfin client for legacy iPhone and iPad devices running
iOS 9. It is built with Objective-C and Theos and targets 32-bit ARMv7 devices.

## Features

- Jellyfin server login with credentials and sessions stored in the iOS Keychain
- Multiple saved servers and a selectable default server
- Home sections for continue watching, next up, recent movies, and recent series
- Library browsing, discovery, and search
- Native playback with configurable streaming quality
- Audio-track and subtitle selection
- iPhone and iPad icon assets for iOS 9

## Compatibility

- Deployment target: iOS 9.0
- Architecture: ARMv7
- Toolchain SDK target: iOS 9.2
- Package format: IPA

The project intentionally keeps its legacy deployment settings in the
`Makefile`. Changing the target SDK, deployment target, or architecture can
break compatibility with the devices this app is intended to support.

## Build

Install [Theos](https://theos.dev/docs/installation) with an iOS 9.2 SDK, then
run:

```sh
make package
```

The generated IPA is written to `packages/`. Build output, IPA files, local
logs, and backup files are excluded from version control.

## Server security

NineFin permits arbitrary network loads so it can connect to legacy and local
Jellyfin deployments. Prefer HTTPS whenever the server supports it, especially
outside a trusted local network.

## License

NineFin is available under the [MIT License](LICENSE).
