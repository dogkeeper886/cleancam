# CleanCam

CleanCam turns an iPhone into a clean webcam for a Linux PC. The PC gets only the camera picture, without the grid, timer or buttons the Camera app draws. The phone screen keeps a preview with zoom and a focus/exposure lock.

```
iPhone camera -> CleanCam (H.264, TCP port 5000) -> USB cable -> usbmuxd + iproxy -> ffmpeg -> /dev/video10 "CleanCam"
```

## Install the app

Every push builds an unsigned `CleanCam.ipa` on GitHub Actions (Actions > latest run > Artifacts):

```sh
gh run download -n CleanCam-ipa -D build
```

Sign and install it with [Impactor](https://flathub.org/apps/dev.khcrysalis.PlumeImpactor) and your Apple ID. An app signed with a free Apple ID stops working after 7 days; install it again to renew.

## Receive on Linux

Needs usbmuxd, `iproxy` (libusbmuxd-utils), ffmpeg and v4l2loopback.

```sh
receiver/cleancam-receive.sh            # iPhone on USB
receiver/cleancam-receive.sh 192.0.2.7  # iPhone on the same WiFi, by its IP
```

Open CleanCam on the iPhone, then pick the "CleanCam" camera in OBS, Zoom or the browser. `ffplay /dev/video10` shows it directly.

On Rocky Linux 9, EPEL has `libusbmuxd-utils` but not the usbmuxd daemon. Build [usbmuxd 1.1.1](https://github.com/libimobiledevice/usbmuxd/releases/tag/1.1.1) from source, with `libusb1-devel`, `libplist-devel` and `libimobiledevice-devel` installed, and create its user:

```sh
./configure --prefix=/usr/local --with-udevrulesdir=/usr/lib/udev/rules.d --with-systemdsystemunitdir=/usr/lib/systemd/system
make && sudo make install
sudo useradd --system --no-create-home --home-dir / --shell /sbin/nologin usbmux
sudo udevadm control --reload && sudo systemctl daemon-reload
```

RPM Fusion has `v4l2loopback`.
