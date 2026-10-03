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

Build it yourself. This needs the Xcode command line tools, downloads nothing,
and is the path with no Gatekeeper prompt, because code you compiled is not
quarantined:

    git clone https://github.com/ksha23/preroll.git
    cd preroll
    ./build-app.sh
    cp -R "Preroll.app" /Applications/
    open -a Preroll

A wave icon appears in the menu bar showing the current latency. There is no Dock
icon; it is a menu bar app only.

Or with Homebrew:

    brew install --cask ksha23/tap/preroll

The app is not notarized yet, so the first launch is refused: open **System
Settings > Privacy & Security**, and press **Open Anyway**. Homebrew removed
its `--no-quarantine` option in version 5.

The measurement tools live inside the bundle. Homebrew puts `preroll-latency`
and `aplat` on your PATH; a local build reaches them at
`Preroll.app/Contents/MacOS/`.

## Use

1. Select your AirPlay speakers as the Mac's sound output.
2. Click the menu bar icon.
3. Set the latency with the slider or by typing a value, then press
   **Apply and activate**. You will be asked for an admin password.
4. Your AirPlay speakers disconnect. Re-select them and the new latency is
   live.

The dot turns green and the readout drops to your chosen value.

**Active / Inactive** turns everything off and back on. Inactive removes the
override entirely, so macOS returns to its stock 2000 ms. Both directions
disconnect the speakers the same way.

If the panel ever shows **Needs switch**, AirPlay is running a different value
from the one the current speaker should have. Press **Switch** and re-select
your speakers.

Start at 350 ms. If audio stutters or drops out, raise it. Lower latency means
less buffer to absorb Wi-Fi jitter, so the right value depends on your network.
The sender reports a floor of 250 ms.

### A latency per speaker

The **Speakers** card is a list of every speaker you have used. The first time
you pick a speaker, it is added at the latency it plays at. Change its value in
the list, or with the latency card while it is playing, to give it its own; the
× removes it. Speakers are known by the name you picked them as, so a stereo pair
is one entry ("Desk Stereo Pair").

macOS can only run one AirPlay latency at a time, and changing it means
restarting AirPlay, which drops the route. So when you pick a saved speaker whose
latency differs from what is running, Preroll switches, the speaker disconnects,
and you pick it once more. The menu bar says which one.

Switching by itself needs the **helper**: press **Install…** in the Speakers
card and enter your password once. After that no change asks for a password.
Without it, a mismatch shows a **Switch** button, and each switch asks.

## Uninstall

Turn the master switch to **Inactive**. If you installed the helper, press
**Remove helper…** in the Speakers card. Then quit the app and delete it from
`/Applications`. That removes the preference and the helper and leaves nothing
behind.

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
in a root-owned file. Each change writes that file and restarts
`AirPlayXPCHelper`, in one prompt, and does nothing else privileged.

The optional Preroll helper does the same two things without the prompt. It is a
short shell script (35 lines of code) that launchd runs as root when one request
file changes. The request is a single number, which it checks against 100 to 4000
ms before using, and only the user who installed the helper can write that file.
Read it in `helper/`.

## Why you have to re-select your speakers

The helper builds one audio engine for system audio, on the first AirPlay route
after it starts, and it starts at boot. Every route after that resumes the same
engine at the latency it was created with, so re-selecting your speakers alone
never picks up a change. The only way to get a new engine is to restart the
helper, and restarting it drops the AirPlay route.

---

## Tools

Shipped inside `Preroll.app`, and put on your PATH by the Homebrew cask. A local
`./build.sh` puts them in `bin/` instead; `./install.sh` installs the whole set
along with a LaunchAgent that runs the keep-alive without the menu bar app.

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
