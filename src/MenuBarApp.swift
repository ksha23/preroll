// Preroll - lower AirPlay audio latency on macOS. Menu bar app.

import AppKit
import SwiftUI
import AVFoundation
import CoreAudio

let kAirPlay: UInt32 = 0x61697270            // 'airp'
let kDomain  = "com.apple.airplay"
let kKey     = "audioLatencyMs"

// ------------------------------------------------------------------ CoreAudio

enum CA {
    static func addr(_ s: AudioObjectPropertySelector,
                     _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
    }
    static func defaultOutput() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var d: AudioDeviceID = 0; var z = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d)
        return d
    }
    static func name(_ d: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        guard AudioObjectHasProperty(d, &a) else { return "No output" }
        var s: CFString? = nil; var z = UInt32(MemoryLayout<CFString?>.size)
        let r = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(d, &a, 0, nil, &z, $0) }
        return r == noErr ? (s as String? ?? "No output") : "No output"
    }
    static func u32(_ d: AudioObjectID, _ s: AudioObjectPropertySelector,
                    _ sc: AudioObjectPropertyScope) -> UInt32 {
        var a = addr(s, sc)
        guard AudioObjectHasProperty(d, &a) else { return 0 }
        var v: UInt32 = 0; var z = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? v : 0
    }
    static func f64(_ d: AudioObjectID, _ s: AudioObjectPropertySelector) -> Double {
        var a = addr(s)
        guard AudioObjectHasProperty(d, &a) else { return 0 }
        var v: Double = 0; var z = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? v : 0
    }
    static func transport(_ d: AudioDeviceID) -> UInt32 {
        u32(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
    }
    static func latency(_ d: AudioDeviceID) -> (total: UInt32, stream: UInt32, sr: Double) {
        let sr   = f64(d, kAudioDevicePropertyNominalSampleRate)
        let dev  = u32(d, kAudioDevicePropertyLatency,         kAudioDevicePropertyScopeOutput)
        let safe = u32(d, kAudioDevicePropertySafetyOffset,    kAudioDevicePropertyScopeOutput)
        let buf  = u32(d, kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput)
        var a = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var z: UInt32 = 0
        AudioObjectGetPropertyDataSize(d, &a, 0, nil, &z)
        var sl: UInt32 = 0
        if z > 0 {
            var ids = [AudioStreamID](repeating: 0, count: Int(z)/MemoryLayout<AudioStreamID>.size)
            AudioObjectGetPropertyData(d, &a, 0, nil, &z, &ids)
            if let s = ids.first { sl = u32(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) }
        }
        return (dev + safe + sl + buf, sl, sr)
    }
}

// ------------------------------------------------------------------ keep-alive

/// Inaudible NON-ZERO dither so the AirPlay HAL never idles the stream.
/// Non-zero matters: the driver reads enableSilenceDetection and
/// enableNonZeroPCMSampleDetection, so digital silence would not hold it open.
final class KeepAlive {
    private var engine: AVAudioEngine?
    private var seed: UInt32 = 0x9E3779B9
    private(set) var device: AudioDeviceID = 0
    private(set) var level: Float = -78
    var isRunning: Bool { engine?.isRunning ?? false }

    func stop() { engine?.stop(); engine = nil; device = 0 }

    func start(on dev: AudioDeviceID, dbfs: Float) {
        stop()
        let e = AVAudioEngine()
        var d = dev
        guard let au = e.outputNode.audioUnit else { return }
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        let fmt = e.outputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        let amp = powf(10, dbfs / 20)
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, ablPtr in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for f in 0..<Int(frames) {
                self.seed ^= self.seed << 13
                self.seed ^= self.seed >> 17
                self.seed ^= self.seed << 5
                let v = (Float(self.seed % 2001) - 1000) / 1000 * amp
                for b in abl { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
            }
            return noErr
        }
        e.attach(src); e.connect(src, to: e.mainMixerNode, format: fmt); e.prepare()
        do { try e.start(); engine = e; device = dev; level = dbfs } catch { engine = nil }
    }
}

// ------------------------------------------------------------------ prefs

enum Pref {
    /// The AirPlay sender helper runs as ROOT, so its CFPreferences search list
    /// resolves com.apple.airplay from the SYSTEM domain. A user-domain write is
    /// ignored. Verified: /Library/Preferences held 350 while the user domain held
    /// 500, and the helper used 350.
    static let systemPlist = "/Library/Preferences/com.apple.airplay"

    static var override: Int? {
        guard let d = NSDictionary(contentsOfFile: systemPlist + ".plist") else { return nil }
        return (d[kKey] as? NSNumber)?.intValue
    }
    @discardableResult
    static func sh(_ c: String) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", c]
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
    /// AirPlayXPCHelper runs as ROOT, so kCFPreferencesCurrentUser resolves to
    /// /var/root/Library/Preferences, which OUTRANKS /Library/Preferences in the
    /// search list. Writing only the system domain is silently overridden by any
    /// value sitting in root's own domain. Verified: a freshly started helper read
    /// 350 while /Library/Preferences held 325.
    ///
    /// So both are written, always together: root's domain because that is what the
    /// helper actually reads, and the system domain because this app runs as the
    /// console user and can read it back for display.
    ///
    /// Deliberately does NOT restart the helper or touch the audio route. Changing
    /// the user's speakers without asking is not this app's business; it reports
    /// what is needed and lets the user choose when to reconnect.
    static func apply(_ ms: Int?) -> String? {
        let cmd: String
        if let ms {
            cmd = "/usr/bin/defaults write \(kDomain) \(kKey) -int \(ms); "
                + "/usr/bin/defaults write \(systemPlist) \(kKey) -int \(ms)"
        } else {
            cmd = "/usr/bin/defaults delete \(kDomain) \(kKey) 2>/dev/null || true; "
                + "/usr/bin/defaults delete \(systemPlist) \(kKey) 2>/dev/null || true"
        }
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?
            .executeAndReturnError(&err)
        if let err {
            let m = (err["NSAppleScriptErrorMessage"] as? String) ?? "authorization failed"
            return m.contains("-128") ? nil : m          // -128 == user cancelled
        }
        return nil
    }
}

// ------------------------------------------------------------------ model

enum Health { case off, live, pending, noOverride, notAirPlay }

final class Model: ObservableObject {
    @Published var deviceName = "-"
    @Published var isAirPlay  = false
    @Published var latencyMs  = 0.0
    @Published var streamFrames: UInt32 = 0
    @Published var sampleRate = 0.0
    @Published var health: Health = .notAirPlay
    @Published var target: Double = 350
    @Published var busy = false
    /// True once the user drags the slider. While set, refresh() must NOT pull the
    /// slider back to the system value, or the 2 s poll overwrites the pending edit.
    @Published var userDirty = false
    @Published var note: String?

    /// Derived from reality, never a stored flag: the app is "Active" exactly when
    /// the latency override is present. If an auth prompt is cancelled, this simply
    /// reflects that nothing changed, instead of showing a state that is not true.
    @Published var masterOn = false

    var savedLatency: Int { UserDefaults.standard.object(forKey: "savedLatency") as? Int ?? 350 }

    /// Master switch: ALL effects. Off removes the latency override AND stops the
    /// keep-alive. On restores the last latency used and resumes the keep-alive.
    /// Removing the override is a root-owned preference write, so this prompts.
    func setMaster(_ on: Bool) {
        if on {
            apply(Int(target))
        } else {
            if let cur = Pref.override { UserDefaults.standard.set(cur, forKey: "savedLatency") }
            apply(nil)
        }
    }

    @Published var keepEnabled = UserDefaults.standard.object(forKey: "keepEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepEnabled, forKey: "keepEnabled"); sync() }
    }
    @Published var airplayOnly = UserDefaults.standard.object(forKey: "airplayOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(airplayOnly, forKey: "airplayOnly"); sync() }
    }
    @Published var dither: Double = UserDefaults.standard.object(forKey: "dither") as? Double ?? -78 {
        didSet { UserDefaults.standard.set(dither, forKey: "dither") }
    }

    let keep = KeepAlive()
    var keepRunning: Bool { keep.isRunning }
    /// The override is live only when the stream latency in frames matches the
    /// requested milliseconds exactly. 350 ms at 44100 Hz == 15435 frames.
    var expectedFrames: UInt32? {
        guard let o = Pref.override, sampleRate > 0 else { return nil }
        return UInt32((Double(o) / 1000.0 * sampleRate).rounded())
    }

    func refresh() {
        let d = CA.defaultOutput()
        let l = CA.latency(d)
        deviceName   = CA.name(d)
        isAirPlay    = CA.transport(d) == kAirPlay
        sampleRate   = l.sr
        streamFrames = l.stream
        latencyMs    = l.sr > 0 ? Double(l.total) / l.sr * 1000 : 0
        masterOn = Pref.override != nil
        if !masterOn                        { health = .off }
        else if !isAirPlay                  { health = .notAirPlay }
        else if Pref.override == nil        { health = .noOverride }
        else if l.stream == expectedFrames  { health = .live }
        else                                { health = .pending }
        if !busy, !userDirty {
            target = Double(Pref.override ?? savedLatency)
        }
        sync()
    }

    func sync() {
        let d = CA.defaultOutput()
        let want = masterOn && keepEnabled && d != 0 && (!airplayOnly || CA.transport(d) == kAirPlay)
        if want {
            if keep.device != d || !keep.isRunning || keep.level != Float(dither) {
                keep.start(on: d, dbfs: Float(dither))
            }
        } else if keep.isRunning { keep.stop() }
    }

    func apply(_ ms: Int?) {
        busy = true; note = nil
        DispatchQueue.main.async {
            let err = Pref.apply(ms)
            self.busy = false
            self.userDirty = false
            if let ms { UserDefaults.standard.set(ms, forKey: "savedLatency") }
            self.note = err ?? (ms == nil
                ? "Saved. Re-select your speakers when convenient to return to 2000 ms."
                : "Saved. Re-select your speakers when convenient to activate \(ms!) ms.")
            self.refresh()
            self.sync()
        }
    }
}

// ------------------------------------------------------------------ panel

struct Dot: View {
    let health: Health
    var color: Color {
        switch health {
        case .off:        return .secondary.opacity(0.35)
        case .live:       return .green
        case .pending:    return .orange
        case .noOverride: return .secondary
        case .notAirPlay: return .secondary.opacity(0.5)
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: health == .live ? 4 : 0)
    }
}

struct Card<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct Row<C: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: C
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                control
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    @FocusState private var fieldFocused: Bool

    var statusText: String {
        switch m.health {
        case .off:        return "Inactive, macOS default 2000 ms"
        case .live:       return "Active"
        case .pending:    return "Waiting for reconnect"
        case .noOverride: return "Inactive, macOS default 2000 ms"
        case .notAirPlay: return "Not an AirPlay output"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {

            // ---- header
            HStack(spacing: 9) {
                Dot(health: m.health)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.deviceName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(m.isAirPlay ? String(format: "%.0f", m.latencyMs) : "—")
                        .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if m.health == .pending {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Re-select your speakers for \(Pref.override ?? 0) ms")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                        Text("The change applies when the AirPlay route is rebuilt")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Sound…") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    }.controlSize(.small)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12)))
            } else if m.isAirPlay {
                Text("\(m.streamFrames) frames · \(String(format: "%.1f", m.sampleRate/1000)) kHz")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }

            // ---- master
            HStack(spacing: 9) {
                Image(systemName: m.masterOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(m.masterOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.masterOn ? "Active" : "Inactive")
                        .font(.system(size: 14, weight: .semibold))
                    Text(m.masterOn
                         ? "Latency override is set and the stream is held open"
                         : "Nothing applied. Turn on to use \(Int(m.target)) ms")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { m.masterOn }, set: { m.setMaster($0) }))
                    .toggleStyle(.switch).labelsHidden().disabled(m.busy)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(m.masterOn ? Color.accentColor.opacity(0.12)
                                 : Color(nsColor: .controlBackgroundColor)))

            // ---- latency
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Target latency").font(.system(size: 13, weight: .medium))
                    Spacer()
                    TextField("", value: Binding(
                        get: { Int(m.target) },
                        set: { m.target = Double(min(max($0, 100), 4000)); m.userDirty = true }),
                        format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13, design: .rounded)).monospacedDigit()
                        .frame(width: 62)
                        .focused($fieldFocused)
                    Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { m.target },
                                      set: { m.target = $0; m.userDirty = true }),
                       in: 250...2000, step: 25)
                    .controlSize(.small)
                Text("How far ahead audio is scheduled. Lower feels more responsive but leaves less buffer for Wi-Fi jitter, and dropouts are the failure mode. The sender reports a floor of 250 ms; type a value for anything off the slider.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Button(m.busy ? "Applying…" : (m.masterOn ? "Apply" : "Apply and activate")) {
                        fieldFocused = false
                        m.apply(Int(m.target))
                    }
                    .disabled(m.busy || (m.masterOn && Pref.override == Int(m.target)))
                    .controlSize(.regular)
                    Text("Asks for your admin password")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                if let n = m.note {
                    Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }

            // ---- keep-alive
            Card {
                Row(title: "Keep stream alive",
                    detail: "Feeds inaudible noise so the AirPlay stream never idles. Without it, starting audio renegotiates the stream and the first moment is late.") {
                    HStack(spacing: 6) {
                        Text(m.keepRunning ? "running" : "idle")
                            .font(.system(size: 11))
                            .foregroundStyle(m.keepRunning ? Color.green : Color.secondary)
                        Toggle("", isOn: $m.keepEnabled).toggleStyle(.switch)
                            .labelsHidden().controlSize(.small)
                    }
                }
                if m.keepEnabled {
                    Row(title: "Dither level",
                        detail: "Volume of that noise. Lower is quieter but risks being treated as silence.") {
                        HStack(spacing: 6) {
                            Slider(value: $m.dither, in: -100...(-60), step: 2) { e in if !e { m.sync() } }
                                .controlSize(.mini).frame(width: 90)
                            Text("\(Int(m.dither)) dB")
                                .font(.system(size: 12, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                Row(title: "Only on AirPlay",
                    detail: "Keeps the stream alive only when the output is an AirPlay device, so it costs nothing on built-in speakers.") {
                    Toggle("", isOn: $m.airplayOnly).toggleStyle(.switch)
                        .labelsHidden().controlSize(.small)
                }
            }
            .opacity(m.masterOn ? 1 : 0.45)
            .disabled(!m.masterOn)

            HStack {
                Text("Preroll").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // Sits BEHIND the controls, so children still receive their own clicks and
        // only clicks on empty space fall through to clear focus.
        .background(
            Color.clear.contentShape(Rectangle()).onTapGesture { fieldFocused = false }
        )
    }
}

// ------------------------------------------------------------------ app

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var status: NSStatusItem!
    var popover = NSPopover()
    let model = Model()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.action = #selector(toggle)
        status.button?.target = self

        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: Panel(m: model))
        host.sizingOptions = [.preferredContentSize]   // NSHostingController does NOT auto-size by default
        popover.contentViewController = host

        model.refresh(); icon()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.model.refresh(); self?.icon()
        }
        var a = CA.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _,_ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.model.refresh(); self?.icon()
            }
        }
    }

    func icon() {
        guard let b = status.button else { return }
        // NOTE: every name here is verified to resolve. NSImage(systemSymbolName:)
        // returns nil for an unknown symbol, and a status item with no image and no
        // title collapses to zero width, i.e. vanishes from the menu bar.
        let sym: String
        switch model.health {
        case .off:        sym = "speaker.slash"
        case .live:       sym = model.masterOn ? "airplayaudio.circle.fill" : "airplayaudio.circle"
        case .pending:    sym = "airplayaudio.badge.exclamationmark"
        case .noOverride: sym = "airplayaudio.circle"
        case .notAirPlay: sym = "airplayaudio"
        }
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: "Preroll")
               ?? NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "Preroll")
        img?.isTemplate = true
        b.image = img
        b.title = model.isAirPlay ? String(format: " %.0f", model.latencyMs) : ""
        // Last-resort guard: never leave the item with nothing to draw.
        if b.image == nil && b.title.isEmpty { b.title = "AP" }
        b.alphaValue = model.masterOn ? 1.0 : 0.55
        b.toolTip = model.masterOn
            ? "Preroll: active" : "Preroll: inactive"
    }

    /// Closing the panel discards an unapplied edit, so reopening always shows
    /// the value that is actually live rather than a stale pending one.
    func popoverDidClose(_ notification: Notification) {
        model.userDirty = false
        model.refresh()
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = status.button else { return }
        model.userDirty = false
        model.refresh()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
