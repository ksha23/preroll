# Preroll

Lower AirPlay audio latency on macOS. **2000 ms down to ~350 ms**, and no stream
renegotiation every time playback starts.

*Preroll* is the audio and broadcast term for the lead-in before playback begins,
which is exactly what that 2000 ms is: audio scheduled well ahead of when you
hear it.

Menu bar app plus a set of measurement tools. Tested on macOS 26.5.1, Apple
Silicon, against a HomePod (2nd gen) stereo pair, a Sonos Era 100 SL, and an
Apple TV 4K.

---

## Install

    brew install --cask --no-quarantine ksha23/tap/preroll
    open -a Preroll

`--no-quarantine` is needed because the app is not notarized yet: without it
macOS refuses to open anything downloaded that Apple has not seen.

Or build it yourself, which needs the Xcode command line tools and downloads
nothing:

    git clone https://github.com/ksha23/preroll.git
    cd preroll
    ./build-app.sh
    cp -R "Preroll.app" /Applications/
    open -a Preroll

A wave icon appears in the menu bar showing the current latency. There is no Dock
icon; it is a menu bar app only.

The measurement tools live inside the bundle. Homebrew puts `preroll-latency`
and `aplat` on your PATH; a local build reaches them at
`Preroll.app/Contents/MacOS/`.

## Use

1. Select your AirPlay speakers as the Mac's sound output.
2. Click the menu bar icon.
3. Set **Target latency** with the slider or by typing a value, then press
   **Apply and activate**. You will be asked for an admin password once.
4. Re-select your speakers when convenient. The change takes effect when the
   AirPlay route is rebuilt.

The dot turns green and the readout drops to your chosen value.

**Active / Inactive** turns everything off and back on. Inactive removes the
override entirely, so macOS returns to its stock 2000 ms.

Start at 350 ms. If audio stutters or drops out, raise it. Lower latency means
less buffer to absorb Wi-Fi jitter, so the right value depends on your network.
The sender reports a floor of 250 ms.

## Uninstall

Turn the master switch to **Inactive**, quit the app, and delete it from
`/Applications`. That removes the preference and leaves nothing behind.

## License and trademarks

MIT. See `LICENSE`.

Preroll is an independent project, **not affiliated with, authorised, sponsored,
or endorsed by Apple Inc.** AirPlay, HomePod, Apple TV and macOS are trademarks
of Apple Inc., used here only to describe what this software interoperates with.
Sonos and Sonos Era are trademarks of Sonos, Inc.

This software changes an undocumented system preference and asks for
administrator authorisation to do so. It is provided without warranty of any
kind; see the licence for the full disclaimer.

---

## What it does

**1. Lowers the AirPlay sender latency.** macOS schedules AirPlay audio 2000 ms
ahead, a constant inherited from AirTunes in 2004 (88200 frames at 44.1 kHz is
exactly 2.000 s). The undocumented preference `audioLatencyMs` in domain
`com.apple.airplay` overrides it.

This is not a limit your speakers impose. The sender logs the receiver's own
requirement on every stream:

    Created remote audio stream. arrivalToRenderLatencyMs=84

84 ms. The rest was scheduling policy.

**2. Keeps the AirPlay stream alive.** With the 2000 ms gone, the next-largest
cost becomes visible: the stream is suspended when audio goes quiet, and a brand
new remote stream is negotiated on every start. The app feeds continuous
inaudible noise so that never happens.

It feeds *noise*, not silence, deliberately. The AirPlay HAL driver reads settings
named `enableSilenceDetection` and `enableNonZeroPCMSampleDetection` and logs
`Event: 'Detected non-zero PCM sample'`, so digital silence would not hold the
stream open. The generator is an xorshift that never returns zero, run at -78 dBFS.

## Why it needs an admin password

`AirPlayXPCHelper` reads the preference and runs as root, so the value has to live
in a root-owned file. The app writes it once per change and does nothing else
privileged. It never restarts services and never changes your audio output.

## Why you have to re-select your speakers

The helper reads the preference when it builds an audio engine, which happens when
an AirPlay route is established. Playing and pausing is not enough; the route has
to be rebuilt. The app could force this by restarting the helper, but that would
disconnect your speakers without asking, so it tells you instead.

---

## Tools

Built by `./build-app.sh` into `bin/`, or install the whole set with `./install.sh`.

| tool | purpose |
|---|---|
| `preroll-latency` | every output device's reported presentation latency |
| `aplat` | true acoustic latency, measured via mic loopback |
| `apwatch.sh` | live AirPlay latency telemetry from the unified log |
| `set-latency-pref.sh` | set any tunable from the shell and restart the helper |
| `src/resolve.py` | resolves CFString operands at preference call sites in a Mach-O |

To see the driver's own telemetry:

    sudo log config --mode level:debug --subsystem com.apple.airplay
    ./apwatch.sh

## Other preferences found

Extracted from `/System/Library/Audio/Plug-Ins/HAL/AirPlay.driver` and the
AirPlaySupport latency table in the dyld shared cache. Domain `com.apple.airplay`.

| key | status |
|---|---|
| `audioLatencyMs` | **the fix** |
| `audioLatencyAdjustMs` | live, default -250, unexplored |
| `audioLatencyOffsetMs` | live, default 0, unexplored |
| `audioLatencySystemMs` | exists but is not consulted on this route |
| `fixedIOFrameSize` | works, but **1024 froze playback** |
| `mediumLatencyPathway` | **breaks AirPlay device creation entirely, do not set** |
| `enableSilenceDetection` | gated behind `_IsAppleInternalBuild`, inert on retail macOS |
| `screenLatencyMs`, `audioLatencyScreenMs`, `mediaPresentationLatencyMs` | mirroring paths |

`mediumLatencyPathway` is argument 3 of four to
`APSAudioFormatDescriptionListCreateSenderDefaultList`. Setting it makes that
builder return an empty format list, so no stream and no device gets created. It
needs a matching `AudioDeviceType` creation option that no preference controls.

See `NOTES.md` for the full technical detail.

## A better option for video

For video specifically, use the AirPlay button in Safari's own player rather than
routing system audio. That uses a different AirPlay engine which pre-fetches ahead
of the playhead, so its buffer costs nothing: about 120 ms, and play/pause is
instant. It only works where a native player exposes it, so Safari and Apple's
apps, not Chrome or Firefox. See
[lookahead](https://github.com/ksha23/lookahead).

## Caveats

- These are private, undocumented Apple preferences. They can change or disappear
  in any macOS update.
- Nothing here modifies the system volume, disables SIP, or patches any binary. It
  writes a preference file and runs a userland audio process.
- Not tested beyond macOS 26.5.1 on Apple Silicon.
