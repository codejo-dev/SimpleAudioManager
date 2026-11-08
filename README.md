# Simple Audio Manager

Gives fixed-volume outputs (S/PDIF, HDMI, DisplayPort) a working **native** macOS volume control, and lets you rename, re-icon and hide audio devices.

- A small Core Audio driver publishes a **proxy** output device with a real volume and mute control. Apple's volume keys, the on-screen volume indicator and the Control Center slider work with it unchanged.
- The proxy forwards audio to the physical device **inside Core Audio** (its driver service process). There is no loopback input, so no microphone permission and no orange mic indicator. Audio keeps working when the app is not running.
- An optional menu bar **Sound picker** (styled like Control Center's Sound module) shows only the devices you want, with your names and icons.

## Install a release

1. Download `SimpleAudioManager-<version>.zip` from [Releases](https://github.com/codejo-dev/SimpleAudioManager/releases) and unzip it.
2. In Terminal, in the unzipped folder:

   ```bash
   ./install.sh
   ```

   It copies the app to `/Applications`, installs the audio driver into `/Library/Audio/Plug-Ins/HAL` and restarts Core Audio (sound drops for about a second). It asks for your administrator password.

To remove everything again: `./uninstall.sh`. Add `--purge` to also delete settings, icons and saved proxies.

## Build from source

Requirements:

- macOS 15 or later (built and tested with Xcode 27.2 / Swift 6.4; CI uses the `macos-26` runner)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- After cloning: `git submodule update --init` (pulls libASPL)

```bash
make app      # builds "build/Debug/Simple Audio Manager.app" (driver embedded)
make test     # unit tests: SAMKit (Swift Testing) + driver core (XCTest)
make run      # build and launch
```

Install the driver from a local build with **Install Driver…** in the app, or:

```bash
make install  # copies the driver to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod (sudo)
```

Audio drops for about a second while Core Audio restarts. To remove it: `make uninstall`.

## Releasing

Push a version tag; the [Release workflow](.github/workflows/release.yml) runs the tests, builds a universal (Apple Silicon + Intel) release and publishes it as a GitHub Release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

- The tag sets the version (`v0.2.0` → 0.2.0); the workflow run number becomes the build number.
- Tags with a suffix (`v0.2.0-beta.1`) are published as pre-releases.
- To build the same package locally: `make release VERSION=0.2.0` (writes `dist/`).

Releases are ad-hoc signed by default; `install.sh` clears the download quarantine so macOS lets them run. For Developer ID signing and notarization, add these repository secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of your *Developer ID Application* certificate (.p12) |
| `MACOS_CERTIFICATE_PASSWORD` | password of that .p12 |
| `APPLE_TEAM_ID` | your team ID |
| `NOTARY_APPLE_ID` | Apple ID used for notarization |
| `NOTARY_PASSWORD` | app-specific password for that Apple ID |

## Use

1. Open the app and pick an output without volume control (for example *USB SPDIF Adapter*).
2. Click **Create Proxy**. Leave "Hide the original device" on.
3. Select the proxy as output. The volume keys now work.
4. Optional: turn off *System Settings › Control Center › Sound › Show in Menu Bar*, so only the SimpleAudioManager picker remains.

### What "hide" means

macOS does not let any app hide or rename a physical device; those properties are read-only. A hidden device disappears from the menu bar picker. If it gets selected anyway (in Control Center or System Settings), the app switches straight to its proxy, or to your fallback device. Proxies themselves can be renamed and given icons freely.

## Command line

```bash
swift run --package-path Packages/SAMKit samctl devices   # all devices, UIDs, volume support
swift run --package-path Packages/SAMKit samctl status    # proxies, forwarding state, dropouts, clock
swift run --package-path Packages/SAMKit samctl add <target-uid> "Living Room"
make logs                                                  # driver log stream
```

## Layout

| Path | What |
|---|---|
| `Driver/` | AudioServerPlugIn (C++20, [libASPL](https://github.com/gavv/libASPL)): proxy device, target output, manager |
| `Driver/Core/` | Real-time core: lock-free ring buffer, gain ramp, clock servo |
| `Packages/SAMKit/` | Swift package: Core Audio model (`AudioHardwareSystem`), driver link, device policy, `samctl` |
| `App/` | SwiftUI app: settings window, menu bar picker, driver installer |
| `Tests/DriverCoreTests/` | XCTest for the driver core (drift simulation included) |

## Known limits

- Calling the HAL client API from inside `coreaudiod` is not officially supported by Apple (proxy-audio-device has relied on it for years).
- The proxy carries LPCM only. AC3/DTS passthrough players should output to the physical device directly; the redirect only affects the system default device.
- Custom icons appear where macOS reads `kAudioDevicePropertyIcon` (Audio MIDI Setup); Control Center may use its own glyphs.
- Below 100% volume the output is not bit-perfect (it is at 100%).

## License

MIT © 2026 [codejo](https://codejo.com). See [LICENSE](LICENSE).

Third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and on the app's About page.
