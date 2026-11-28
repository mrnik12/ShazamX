# ShazamX

ShazamX restores song recognition in legacy versions of Shazam. Version 0.4.0 supports Shazam 7.2.0 on iOS 7 and Shazam 5.5.1 on iOS 6.

## Install

1. Install Shazam 5.5.1 on iOS 6 or Shazam 7.2.0 on iOS 7.
2. Install ShazamX from the [Cydia repo](https://mrnik12.github.io/repo/) or download the .deb from the releases.
3. Open Shazam and tap the dial. To change the recognition server or turn ShazamX off, use **Settings → ShazamX**.

Netrun is the default recognition server. Upgrades from the public Render-only release switch automatically. Render is still available in Settings.

ShazamX shows Listening and Sending during recognition. On 7.2.0, **Add to Tags** opens My Tags and saved song details display cached artwork. On 5.5.1, My Tags uses consistently sized thumbnails. Pending tags stay until cleared and are recognized when connected to the internet.

Some songs can still save without cover art when the relay can't find suitable artwork.

## Build

Use Theos with an ARMv7-capable toolchain and the iOS 6.1 SDK. On Linux or WSL, run:

```bash
bash tweak/build-hosted.sh https://shazamx-relay-test.de3.netrun.io
```

The build script accepts the HTTPS origin of a compatible relay. See the [relay source](https://github.com/mrnik12/repo/tree/main/source/relay) for its API and deployment files.

## License

The ShazamX tweak source is available under the [MIT license](LICENSE). Shazam must be installed separately.
