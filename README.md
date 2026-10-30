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
| USB | 2 CH |
| MIDI → CTRL | OUT |
| BLE | ACCEPT for wireless MIDI |
| SOLO | MUTE |
| SYNTH | OFF |
| DJ | OFF |

Choose an audio output in the app and allow system audio access on first launch. USB carries audio and MIDI; Bluetooth carries MIDI controls only.

Faders and EQ work when MIDI connects. On the TX-6 home screen, press and release SHIFT to enable the SELECT master knob. FX1 unmutes master; FX2 mutes it. The device's own master value is separate; the setup field aligns the Mac value manually.

Chrome-wide volume and EQ work without an extension. Enable individual Chrome tab channels in settings to use tabs instead of the Chrome-wide channel. For individual tabs, load `BrowserExtension` in Chrome. Audible tabs are detected automatically; per-tab volume and EQ require the extension button or `Command+Shift+6` once in that tab.

Noncommercial use, modification and redistribution are permitted under the [PolyForm Noncommercial License](LICENSE).
