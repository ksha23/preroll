# Preroll: technical notes

Reference for how macOS AirPlay audio latency works and where the controls live.
Everything here was measured on macOS 26.5.1, Apple Silicon.

## The 2000 ms

`kAudioStreamPropertyLatency` on the AirPlay output device, unmodified:

    AirPlay   transport=airp   44100 Hz   2 ch
    deviceLatency = 0    safetyOffset = 0    streamLatency = 88200    bufferFrames = 512

88200 frames at 44.1 kHz is exactly 2.000 s, the AirTunes constant from 2004.

Note the latency is reported in **stream** scope. `kAudioDevicePropertyLatency` and
`kAudioDevicePropertySafetyOffset` are both zero, so anything summing only
device-scope properties sees 0 ms.

The receiver does not require it. Every stream creation logs:

    Created remote audio stream. arrivalToRenderLatencyMs=84

A HomePod needs 84 ms from packet arrival to render. The other 1916 ms is sender
scheduling policy. A Sonos Era 100 SL and an Apple TV 4K all report the same
88200, confirming the number comes from the sender, not the receiver.

## The control

    domain:  com.apple.airplay
    key:     audioLatencyMs     (integer, milliseconds)

Read by AirPlaySupport inside `/usr/libexec/AirPlayXPCHelper`. Confirmed in the log:

    [com.apple.airplay:APSLatency] Overriding audio latency: 350 ms
    RTAE ['HLA'] AudioEngineRealTime using audio latency 350 ms, audio latency min
                 250 ms, audio latency adjust -250 ms, audio latency offset 0 ms
    RTAE ['HLA'] maxAudioLatency = 15435, maxAudioLatencyAdjust = -11025
    Resuming endpoint stream with latency 0.350000 seconds.

`HLA` is Apple's own label: High Latency Audio.

### Which file to write

`AirPlayXPCHelper` runs as **root**, so its CFPreferences search list resolves
`kCFPreferencesCurrentUser` to `/var/root/Library/Preferences/`, which **outranks**
`/Library/Preferences/`. A value in root's own domain silently wins.

    /var/root/Library/Preferences/com.apple.airplay.plist    highest priority
    /Library/Preferences/com.apple.airplay.plist             lower
    ~/Library/Preferences/com.apple.airplay.plist            never consulted

The console user's own domain is irrelevant. Write root's domain by running
`defaults write com.apple.airplay ...` **as root**; the app writes the system
domain alongside it only so it can read the value back for display.

### When it takes effect

The helper builds one realtime engine for system audio, on the first AirPlay route
after it starts, and keeps it for its whole life. Every later route change resumes
that same engine at the latency it was created with. The helper is started at boot
and lives until killed. So:

    route change (deselect/reselect)  ->  resumes the old engine, old latency
    suspend/resume (play/pause)       ->  same engine, old latency
    killall AirPlayXPCHelper          ->  next route builds a new engine; drops the route

It is not a preference cache. With both domains at 1000, one helper pid logged:

    Overriding audio latency: 1000 ms
    RTAE ['HLA'-0x01CE] Resuming endpoint stream with latency 0.400000 seconds.

The value was re-read (other engines were built at 1000), but the system-audio
engine 0x01CE, created hours earlier at 400 ms, was resumed on every re-select, and
the device kept reporting 17640 frames. After a restart:

    RTAE ['HLA'-0xF36D] Resuming endpoint stream with latency 1.000000 seconds.

A route change alone looks like it works only when the engine's latency happens to
equal what is on disk, so a test of it must make the two differ.

### Bounds

    audio latency min      250 ms   (stated floor)
    audio latency adjust  -250 ms   (maxAudioLatencyAdjust = -11025 frames)
    audio latency offset     0 ms
    DynamicLatencyManager  variant=B238, latencyTierIdx=0

350 ms was the lowest stable value on the test network. Below that produced
audible problems. Lower latency trades directly against Wi-Fi jitter tolerance.

## Stream renegotiation

With the 2000 ms removed, the remaining cost is that the AirPlay endpoint stream
is suspended whenever audio goes quiet, and a new remote stream is negotiated on
every start:

    audio endpoint stream suspending...
    Resuming endpoint stream with latency 0.350000 seconds
    Created remote audio stream. streamID=<new> arrivalToRenderLatencyMs=84

Measured cost of that renegotiation, against the old 2000 ms baseline:

    cold, after 25 s silence : engine.start() 368.8 ms, first render cb 377.9 ms
    hot, keep-alive running  : engine.start()  95.6 ms, first render cb 105.9 ms
    cold again (control)     : engine.start() 359.5 ms, first render cb 368.5 ms

The keep-alive holds the stream open by feeding continuous inaudible dither at
-78 dBFS. It must be **non-zero** noise, not silence: the HAL driver reads
`enableSilenceDetection` and `enableNonZeroPCMSampleDetection` and logs
`Event: 'Detected non-zero PCM sample'`.

## Preference surface

Extracted with `src/resolve.py`, which resolves CFString operands at the
preference call sites in a Mach-O, applied to
`/System/Library/Audio/Plug-Ins/HAL/AirPlay.driver`, plus the AirPlaySupport
latency table located in the dyld shared cache.

Read by the HAL driver:

| key | reader | notes |
|---|---|---|
| `enableSilenceDetection` | `FigGetCFPreferenceNumberWithDefault`, default 1 | gated behind `_IsAppleInternalBuild`, inert on retail macOS |
| `enableNonZeroPCMSampleDetection` | `APSSettingsGetIntWithDefault` | live, unexplored |
| `mediumLatencyPathway` | `APSSettingsGetIntWithDefault` | **breaks device creation** |
| `fixedIOFrameSize` | `APSSettingsGetIntWithDefault` | works; 1024 froze playback |
| `maxRateOfChange` | `APSSettingsGetDouble` | live, unexplored |
| `HALStreamAudioTapEnabled` | `APSSettingsGetIntWithDefault` | live, unexplored |

The AirPlaySupport latency table:

    audioLatencyMs                "Overriding audio latency: %d ms"
    audioLatencySystemMs          not consulted on this route
    audioLatencyAdjustMs          default -250
    audioLatencyOffsetMs          default 0
    audioLatencyScreenMs / ScreenHighMs / ScreenLowMs
    screenLatencyMs / ForHighLatencyConnectionMs / ForLowLatencyConnectionMs
    mediaPresentationLatencyMs / UDPMs
    mediumLatencyPathwayLatencyMs

### Why mediumLatencyPathway breaks things

It is argument 3 of four to `APSAudioFormatDescriptionListCreateSenderDefaultList`.
Disassembly at 0x4dc0-0x4e08 of the HAL driver:

    4dc0  ldr  w8, [x28, #0x54]        ; device/stream type
    4dc8  cset w24, eq                 ; -> arg 2
    4dcc  adrp x0, "mediumLatencyPathway"
    4dd8  bl   _APSSettingsGetIntWithDefault
    4de0  cset w2, ne                  ; -> arg 3   <<< the pref
    4df0  cset w3, eq                  ; -> arg 4
    4dfc  bl   _APSAudioFormatDescriptionListCreateSenderDefaultList
    4e04  bl   _APSAudioFormatDescriptionListGetFormatCount
    4e08  cbz  x0, 0x4eac              ; count == 0 -> bail

Args 2 and 4 derive from the device type. Setting the preference asks for
low-latency formats on a device created as `DeviceType_Audio`, the format list
comes back empty, and no stream or device is created. Verified to fail identically
on a HomePod pair and an Apple TV 4K.

The device type family, from the GOT bindings:

    DeviceType_Audio            what an audio route always gets
    DeviceType_LowLatencyAudio
    DeviceType_AVConference
    DeviceType_AggrAudio
    DeviceType_Screen
    kAPHALAudioDeviceCreationOption_AudioDeviceType
    kFigEndpointStreamType_LowLatencyAudio   (CoreMedia)

`AudioDeviceType` is a creation option passed by AirPlaySender over XPC. No
preference in the HAL driver controls it.

## The two AirPlay audio engines

AirPlaySender exports both a buffered engine and the realtime one above:

    _APAudioEngineBufferedCreate        _APEndpointStreamBufferedAudioCreate
    _APAudioHoseManagerBufferedCreate   _APAudioEngineBufferedAdapterCreate

Which one is used depends on the content, not on any setting.

- **System audio output is live.** Samples do not exist until produced, so nothing
  can be sent ahead and the receiver's buffer depth *is* the latency. This is the
  realtime engine, and `audioLatencyMs` is the only lever.
- **A media player** hands AirPlay a stream plus a timeline. The receiver
  pre-fetches ahead of the playhead, so buffer depth costs nothing. The
  system-audio route logs the value even while unused:

      Setting media presentation latency to 120 ms and media presentation mode to inactive

Play, pause and seek also differ: realtime means flush then refill, buffered means
re-anchor a timeline.

Consequence: live audio (Discord, Zoom, games, system sounds) can never use the
buffered path. For video, Safari's own player AirPlay button does. See
[lookahead](https://github.com/ksha23/lookahead).

## Why patching was never attempted

SIP and Authenticated Root are enabled and the system boots from a sealed
snapshot. `AirPlaySender` and `AirPlaySupport` have no on-disk binaries; they live
in the dyld shared cache. `coreaudiod` is a platform binary with library
validation. Reaching that code would mean permanently breaking the system security
model, and it is unnecessary: the preference surface is reachable at runtime.

## Privilege design

`SMAppService` and `SMJobBless` both require a real Developer ID, and would make
shipping a bug fix depend on keeping that membership current. A `NOPASSWD` sudoers
rule would remove the prompt but is a standing root grant. Neither is used.

Per change, the app writes the root-owned preference and restarts
`AirPlayXPCHelper`, both in one standard macOS authorization dialog, and does
nothing else privileged. The keep-alive needs no privileges at all.

### The optional helper

Automatic per-speaker switching cannot put a password dialog in front of every
speaker change, so there is an opt-in helper, installed with one prompt. It is a
standing root service, so it is kept as narrow as possible:

    /Library/LaunchDaemons/com.ksha23.preroll.helper.plist     root:wheel 644
    /Library/PrivilegedHelperTools/com.ksha23.preroll.helper   root:wheel 755, the script
    /Library/Application Support/Preroll/                     root:wheel 755
        request    owned by the installing user, 600: the only thing they can write
        done       root, 644: the last request handled, for the app to confirm

- launchd starts the script when `request` changes (`WatchPaths`). Nothing runs
  otherwise.
- The request is one line, `<sequence> <ms|off>`, read with a 64-byte cap. The
  sequence must be digits; the value must be `off` or an integer from 100 to 4000
  with no leading zero. Anything else is ignored, and the only thing that reaches
  a command is that validated integer.
- The directory is root's, so the user owns only the file's contents: they cannot
  swap it for a link to something else.
- Root only runs copies in root-owned locations. The app bundle is writable by
  its user, so the install step copies the script out of it and never points
  launchd at it.
- What a user with write access to `request` can do: set the AirPlay latency and
  restart `AirPlayXPCHelper`, as often as they like. That is the whole surface.

The app writes a fixed 64-byte record at offset 0 in one `pwrite`, so the script
never reads half a line, and then waits for `done` to show its sequence. Measured
through launchd with `ThrottleInterval` 1: five back-to-back requests each
confirmed in 1.1 to 1.25 s.

## Identifying the speaker

CoreAudio calls every AirPlay route "AirPlay". Its UID is minted when
`AirPlayXPCHelper` starts and then reused for whatever is picked next: one UID
carried Bedroom, Desk Stereo Pair and Back Stereo Pair in turn. So neither names
a speaker.

`AVOutputContext`'s system-wide context would, and could even re-route, but it
returns nil without an Apple entitlement.

The system log has it. `audioaccessoryd` logs every route change with the UID
and the name the user picked:

    Received manual route change uid 4c779229-...-432418906370041-Audio type output
      name Bedroom source ControlCenter ...

The app streams that line with `log stream`, which needs no privileges, and at
launch looks back for the route already up: one hour takes about 2 s, a week
about 17 s. The `AirPlayXPCHelper` endpoint lines are no good for this: a stereo
pair shows up as its two halves, parented to the pair's cluster rather than to the
system-audio aggregate.

The engine is built before that line is logged (engine at 01:06:07.211, name at
01:06:08.265), so the name always arrives too late to set the latency of the
route it names. That is why a switch costs one extra pick.

## macOS 27

Observed on macOS 27.0.1 (26A434), sender AirPlay 980.77.5, against HomePods on
HomePod OS 27.0 (AirPlay 980.77.2), a Sonos Era 100 SL (366.0) and an Apple TV on
tvOS 26.6. Every Preroll setting was removed and the Mac rebooted before these
observations, so none of them involve Preroll.

### A new engine

macOS 26 used one realtime engine for system audio, `RTAE ['HLA']`, at 2000 ms.
macOS 27 adds a buffered one. The two show up in the log as stream engine types:

    engineType=AudioEngineType_RTAudio      the old realtime engine
    engineType=AudioEngineType_Buffered     the new one, engineTypeBufferedRealTime in its options

HomePods on OS 27 get the buffered engine, usually over Wi-Fi Aware (`NANDS`
data sessions on `nan0` and `llw1`, "Activation succeeded over NAN"). The AirPlay
output device then reports:

    transport=airp  sr=48000  bufferFrames=128  streamLatency=9600     (200 ms)

The Sonos and, at times, HomePods reached over the regular network get the old
engine at 88200 frames, 2000 ms. The sender still reads the preference on 27:

    [com.apple.airplay:APSLatency] Overriding audio latency: 400 ms

### Stereo pairs and feature bit 96

The engine type is chosen per speaker. A stereo pair's stream takes the type of
the first route built after `AirPlayXPCHelper` starts, and a speaker whose type
differs is refused:

    Cannot add subStream [0x41EC] with engineType=AudioEngineType_RTAudio
      to stream [0x23ED] with engineType=AudioEngineType_Buffered

That speaker is activated, so it lights up, but it gets no audio. Picking a
HomePod first leaves the buffered stream, and the old-engine speaker is silent.
Picking the Sonos first leaves an old-engine stream, and the other speaker is
silent. No order plays both.

Which speaker gets which engine follows its advertised extended feature flags,
the `fex` field of its `_airplay._tcp` Bonjour record (base64, little-endian):

    speaker                 bit 96, day 1   bit 96, later
    White HomePod Left      missing         present after a night of uptime
    White HomePod Right     present         present
    OG HomePod Left Back    missing         present after a restart
    OG HomePod Right Back   present         present

Every refused speaker was one missing bit 96, both pairs went to stereo once both
halves had it, and no software version changed in between. What bit 96 means is
not documented. The evidence is that correlation plus one confirmed prediction.
`pair-check.py` reads the flags and flags a mismatched pair.

### Crashes on 27.0.1, with no Preroll settings

- `AirPlayXPCHelper` and `audiomxd` killed by the CoreMedia XPC watchdog
  (`figXPC_ServerTimeout_Endpoint`, `figXPC_ServerTimeout_RoutingContext`). The
  thread everything waited on was blocked in `APTNANDataSessionRetainActivation`,
  opening a Wi-Fi Aware session to a stereo pair.
- `AirPlayXPCHelper` SIGABRT, `-[NSMutableDictionary __addObject:forKey:]: object
  cannot be nil` in `audioStream_resumeInternal`. Twice, both times in the Sonos
  route's own stream, one to two seconds after it started.

### Red herrings

`coreaudiod` logs this at every start, yet AirPlay devices are created normally:

    _XPCHelperCopyAirPlayPref:817: got error -6753/0xFFFFE59F kConnectionErr
    HALS_UCPlugIn::Construct_New: couldn't create the IUnknown interface

### Restarting

`killall AirPlayXPCHelper` reported success once and left the same pid running.
`killall -9` worked. `launchctl kickstart -k system/com.apple.audio.coreaudiod` is
refused while SIP is on, so `killall -9 coreaudiod` is the way to restart it.
