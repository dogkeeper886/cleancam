# Host setup

The Linux PC needs these once. Contents: Tools · plumesign · Pairing · RHEL 9 family · RHEL 8 family · Flatpak signers.

## Tools

| Tool | Used for | Check |
|---|---|---|
| `gh`, logged in | the IPA download from a release or a CI run | `gh auth status` |
| usbmuxd | the USB link to the iPhone | `idevice_id -l` lists the phone |
| `idevice_id`, `idevicepair`, `ideviceinfo` (libimobiledevice) | finding and pairing the phone | `command -v idevice_id` |
| `iproxy` (libusbmuxd) | forwarding the stream ports over USB; `tools/iproxy.sh` runs it in podman or docker when the host lacks it | `command -v iproxy` |
| ffmpeg with H.264 and HEVC decoding | decoding the stream; HEVC for the WiFi preset | `ffmpeg -hide_banner -decoders \| grep -wE 'h264\|hevc'` |
| v4l2loopback | the virtual webcam | `modinfo v4l2loopback` |
| `v4l2loopback-ctl`, from v4l2loopback 0.12.5 on | adding the webcam when OBS or another app loaded the module first | `command -v v4l2loopback-ctl` |
| PipeWire as the sound server with `pw-cli`, or PulseAudio with `pactl` and `parec` | the "CleanCam" microphone and speaker, through PipeWire's pipe-tunnel module, or PulseAudio's pipe source and null sink | `wpctl status`, or `pactl list short sources` and `sinks`, lists CleanCam while the receiver runs |
| `python3` | sending the CleanCam speaker's sound to the phone in even 10 ms pieces | `command -v python3` |
| plumesign | signing and installing with an Apple ID | `tools/plumesign.sh --version` |
| podman or docker | running plumesign when the host's glibc is too old for it, running iproxy when the host lacks it, and building CleanCamLegacy | `command -v podman docker` |
| curl and zip | downloading the iOS 11.4 SDK and toolchain, and packing `build/CleanCam-legacy.ipa` | `command -v curl zip` |

Install them with the distribution's packages:

- **Debian / Ubuntu:** `sudo apt install usbmuxd libimobiledevice-utils libusbmuxd-tools ffmpeg v4l2loopback-dkms v4l2loopback-utils pipewire-bin`
- **Fedora**, with RPM Fusion enabled for ffmpeg and v4l2loopback: `sudo dnf install usbmuxd libimobiledevice-utils libusbmuxd-utils ffmpeg v4l2loopback pipewire-utils`
- **RHEL, Rocky or Alma 9:** see RHEL 9 family below.
- **RHEL, Rocky or Alma 8:** see RHEL 8 family below.

When `modinfo v4l2loopback` still fails after a dkms or akmod build, run `sudo depmod -a`. The receiver loads the module itself when `/dev/video${VIDEO_NR:-10}` is missing, or adds the device with `v4l2loopback-ctl` when another app, such as OBS, loaded the module first.

## plumesign

plumesign is the command-line signer from Impactor. `tools/plumesign.sh` runs it natively when the host can, and otherwise in a podman or docker container.

1. Pick a release with a Linux build. Upstream is `claration/Impactor`. When upstream fails Apple sign-in (see `troubleshooting.md`), use a fork that fixes it, such as `bitxeno/PlumeImpactor`; its `v2.7.1-patch.4` defaults to Mac anisette and runs on glibc 2.34.
2. List the assets and digests: `gh release view <tag> -R <owner/repo> --json assets --jq '.assets[] | "\(.digest) \(.name)"'`
3. Download `plumesign-linux-<arch>` (some forks ship it as `.tar.gz`) with `gh release download <tag> -R <owner/repo> -p '<asset>'`.
4. Compare `sha256sum <asset>` with the listed digest.
5. Make it executable and put it on PATH as `plumesign`, or set `PLUMESIGN=/path/to/plumesign`.
6. Run `tools/plumesign.sh --version`.

The Apple ID session lives in `~/.config/PlumeImpactor` for native runs, and in `PLUMESIGN_HOME` (default `~/.local/share/cleancam/plumesign`) for container runs. `PLUMESIGN_IMAGE` picks the container image; the default is `docker.io/library/ubuntu:24.04`.

## Pairing

Plug the iPhone straight into the PC, unlock it and tap "Trust This Computer". `idevicepair validate` then reports success.

## RHEL 9 family

- **Repos:** EPEL provides `libusbmuxd-utils`, `libimobiledevice-utils` and the `-devel` packages. RPM Fusion provides `ffmpeg` and `v4l2loopback`. The base repos provide `pipewire-utils`.
- **usbmuxd:** EPEL has no usbmuxd daemon. Build release 1.1.1, which matches EPEL's libimobiledevice 1.3.0:

```bash
sudo dnf install libusb1-devel libplist-devel libimobiledevice-devel
curl -fsSLO https://github.com/libimobiledevice/usbmuxd/releases/download/1.1.1/usbmuxd-1.1.1.tar.bz2
sha256sum usbmuxd-1.1.1.tar.bz2  # c0ec9700172bf635ccb5bed98daae607d2925c2bc3597f25706ecd9dfbfd2d9e
tar xjf usbmuxd-1.1.1.tar.bz2 && mkdir build && cd build
../usbmuxd-1.1.1/configure --prefix=/usr/local \
  --with-udevrulesdir=/usr/lib/udev/rules.d --with-systemdsystemunitdir=/usr/lib/systemd/system
make && sudo make install
sudo useradd --system --no-create-home --home-dir / --shell /sbin/nologin usbmux
```

- **SHA-1:** libimobiledevice 1.3.0 signs pairing certificates with SHA-1, which OpenSSL 3 rejects. Allow it for usbmuxd only, with `/usr/local/etc/usbmuxd-openssl.cnf`:

```ini
# Lets libimobiledevice 1.3.0 use its SHA-1 pairing certificates under OpenSSL 3 (this process only).
openssl_conf = openssl_init
[openssl_init]
alg_section = evp_properties
ssl_conf = ssl_module
[evp_properties]
rh-allow-sha1-signatures = yes
[ssl_module]
system_default = tls_defaults
[tls_defaults]
CipherString = DEFAULT:@SECLEVEL=0
MinProtocol = TLSv1
```

  Then add `/etc/systemd/system/usbmuxd.service.d/openssl.conf`:

```ini
[Service]
# libimobiledevice 1.3.0 signs pairing certificates with SHA-1, which OpenSSL 3 rejects by default.
Environment=OPENSSL_CONF=/usr/local/etc/usbmuxd-openssl.cnf
```

  Prefix the idevice tools the same way, for example `OPENSSL_CONF=/usr/local/etc/usbmuxd-openssl.cnf idevicepair validate`. `rh-allow-sha1-signatures` exists only in RHEL-family OpenSSL; on other distributions, keep only the `ssl_module` part.

- **Reload:** `sudo udevadm control --reload && sudo systemctl daemon-reload && sudo systemctl restart usbmuxd`
- **glibc:** the family ships glibc 2.34, so upstream plumesign builds run in the container.

## RHEL 8 family

Tested once, on 2026-10-26, with an iPhone 5 on iOS 10.3.4: video, microphone and speaker in a Zoom call over USB. Other RHEL 8 releases, kernels and package versions are untested.

| Part | Version | From |
|---|---|---|
| Rocky Linux | 8.10, kernel 4.18.0-553.170.1.el8_10, glibc 2.28 | |
| ffmpeg | 4.4.8-1.el8 | RPM Fusion free updates |
| kmod-v4l2loopback | 0.15.1-2.el8 | RPM Fusion free updates |
| usbmuxd | 1.1.0-13.el8 | AppStream |
| PulseAudio | 14.0-4.el8 | AppStream |
| docker-ce | 29.8.2 | Docker's repo; podman is untested |
| libimobiledevice-utils, libusbmuxd-tools | 1.3.0, 2.0.2 | Ubuntu 24.04, in a container |
| plumesign | bitxeno v2.7.1-patch.4 | in a container |

- **Repos:** EPEL and RPM Fusion free. `sudo dnf install ffmpeg kmod-v4l2loopback` installs ffmpeg and a v4l2loopback module built for kernel 4.18.0-553.el8_10, which the tested kernel loaded through weak-updates. For a kernel that refuses it, `akmod-v4l2loopback` builds one; that path is untested.
- **usbmuxd:** AppStream's usbmuxd runs as a service.
- **idevice tools:** no enabled repo here (BaseOS, AppStream, PowerTools, EPEL, RPM Fusion free updates) offers `libimobiledevice-utils` or `libusbmuxd-utils`. Run Ubuntu's in a container, against the host's usbmuxd:

```bash
docker build -t cleancam-idevice - <<'EOF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libimobiledevice-utils libusbmuxd-tools \
    && rm -rf /var/lib/apt/lists/*
EOF
idevice() {
  docker run --rm -i --network host --security-opt label=disable \
    --mount type=bind,source=/run/usbmuxd,target=/run/usbmuxd cleancam-idevice "$@"
}
idevice idevicepair validate
```

  Take the sign step's UDID from `idevice idevice_id -l | head -1`. Over USB, the receiver runs iproxy through `tools/iproxy.sh`, which uses this image when the host lacks iproxy, so `receiver/cleancam-receive.sh` runs as on other distributions.
- **Sound:** PulseAudio is the sound server. The receiver makes the CleanCam microphone with a pipe source, and the speaker with a null sink that `parec` reads in 10 ms chunks.
- **glibc:** 2.28 is older than plumesign's Linux builds need (2.34 for the fork above), so plumesign runs in the container.

## Flatpak signers

A Flatpak app such as Impactor sees the usbmuxd socket that existed when it started. When usbmuxd exits on unplug and restarts on plug, the app keeps a dead socket. Keep usbmuxd running with `/etc/systemd/system/usbmuxd.service.d/keep-running.conf`, adjusting the binary path to the installed one:

```ini
[Service]
# Keep running when the iPhone is unplugged, so the socket stays the same for sandboxed apps like Impactor (Flatpak).
ExecStart=
ExecStart=/usr/local/sbin/usbmuxd --user usbmux -f
```
