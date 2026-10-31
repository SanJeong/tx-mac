# tx-mac

A macOS mixer controlled with a teenage engineering TX-6 over USB or Bluetooth MIDI.

![tx-mac](assets/mixer.png)

Requires macOS 26 and Xcode Command Line Tools.

```sh
./install.command
```

## TX-6 setup

| Setting | Value |
| --- | --- |
| USB | 12 IN |
| MIDI → CTRL | OUT |
| BLE | ACCEPT for wireless MIDI |
| SOLO | MUTE |
| SYNTH | OFF |
| DJ | OFF |

The app follows the macOS default output unless you select a device. If that device disconnects, it returns to the system output. Allow system audio access on first launch. USB carries audio and MIDI; Bluetooth carries MIDI controls only.

Keep **USB 12 IN** selected. Enable **TX-6 USB channel meters** in settings to send app audio, including Chrome-wide audio, to the six stereo inputs while listening through the Mac or AirPlay. Separate meter mirroring is unavailable in individual Chrome tab mode or when TX-6 is selected as an audio output. Mac mixing continues if the meter connection fails.

Meters show signal level, not the master volume number. The TX-6’s own faders still affect its USB mix return.

Choose a separate MONITOR output and set each channel to Main, Monitor, Both or Off. Preview follows EQ, fader, channel mute and master volume. FX2 silences both outputs. A disconnected monitor stays silent until the same device returns.

TX-6 audio output currently uses one stereo pair. Independent six-track output routing and native AUX/CUE control are still under investigation.

Faders and EQ work when MIDI connects. On the TX-6 home screen, press and release SHIFT to enable the SELECT master knob. FX1 unmutes master; FX2 mutes it. The device's own master value is separate; the setup field aligns the Mac value manually.

Chrome-wide volume and EQ work without an extension. Enable individual Chrome tab channels in settings to use tabs instead of the Chrome-wide channel. For individual tabs, load `BrowserExtension` in Chrome. Audible tabs are detected automatically; per-tab volume and EQ require the extension button or `Command+Shift+6` once in that tab.

Noncommercial use, modification and redistribution are permitted under the [PolyForm Noncommercial License](LICENSE).
