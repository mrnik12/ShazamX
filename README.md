# ShazamX

ShazamX restores song recognition in Shazam 5.5.1 on iOS 6. It shows the track title, artist, and available cover art in Shazam's original results screen.

## Install

Install Shazam 5.5.1, then install ShazamX from the [Cydia source](https://mrnik12.github.io/repo/) or download the `.deb` from [GitHub Releases](https://github.com/mrnik12/ShazamX/releases/latest). Open Shazam and tap the blue dial. You can turn the tweak on or off under **Settings → ShazamX**.

Tested on iPhone 4S running iOS 6.1.3. Other iOS 6 devices may work. The tweak needs internet access. The free recognition server can take about a minute to wake after being idle.

## Build

Use Theos with an ARMv7-capable toolchain and the iOS 6.1 SDK. On Linux or WSL, run:

```bash
bash tweak/build-hosted.sh https://legacy-shazam-relay.onrender.com
```

The build script also accepts the HTTPS origin of a self-hosted compatible relay. See the [relay source](https://github.com/mrnik12/repo/tree/main/source/relay) for its API and deployment files.

## License

The ShazamX tweak source is available under the [MIT license](LICENSE). Shazam must be installed separately.
