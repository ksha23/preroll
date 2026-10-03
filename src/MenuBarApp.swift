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
    static func string(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        guard AudioObjectHasProperty(d, &a) else { return nil }
        var s: CFString? = nil; var z = UInt32(MemoryLayout<CFString?>.size)
        let r = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(d, &a, 0, nil, &z, $0) }
        return r == noErr ? s as String? : nil
    }
    static func name(_ d: AudioDeviceID) -> String { string(d, kAudioObjectPropertyName) ?? "No output" }
    static func uid(_ d: AudioDeviceID) -> String { string(d, kAudioDevicePropertyDeviceUID) ?? "" }
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
    /// Single-quotes a string for /bin/sh.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs one shell command as root through the standard macOS authorization
    /// dialog. Returns nil on success, else a message; a cancel says so.
    static func admin(_ cmd: String) -> String? {
        let lit = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(lit)\" with administrator privileges")?
            .executeAndReturnError(&err)
        guard let err else { return nil }
        if (err["NSAppleScriptErrorNumber"] as? Int) == -128 { return "Cancelled." }
        return (err["NSAppleScriptErrorMessage"] as? String) ?? "Authorization failed."
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
    /// The helper restart is NOT optional. The helper builds ONE realtime engine for
    /// system audio on the first route after it starts, and every later route change
    /// resumes that engine at the latency it was created with. The preference itself
    /// is re-read, but that engine is never rebuilt. Verified in the log: with both
    /// domains at 1000, pid 393 logged "Overriding audio latency: 1000 ms", yet every
    /// re-select logged "Resuming endpoint stream with latency 0.400000 seconds" on
    /// the same engine, RTAE 'HLA'-0x01CE. The restarted helper built a new engine at
    /// 1.000000 s.
    ///
    /// Restarting drops the AirPlay route, so the speakers must be re-selected.
    static func apply(_ ms: Int?) -> String? {
        var cmd: String
        if let ms {
            cmd = "/usr/bin/defaults write \(kDomain) \(kKey) -int \(ms); "
                + "/usr/bin/defaults write \(systemPlist) \(kKey) -int \(ms)"
        } else {
            cmd = "/usr/bin/defaults delete \(kDomain) \(kKey) 2>/dev/null || true; "
                + "/usr/bin/defaults delete \(systemPlist) \(kKey) 2>/dev/null || true"
        }
        cmd += "; /usr/bin/killall AirPlayXPCHelper 2>/dev/null || true"
        return admin(cmd)
    }
}

// ------------------------------------------------------------------ privileged helper

/// Optional root helper that applies a latency with no password prompt, which is
/// what lets Preroll switch to each speaker's own latency by itself. It is a short
/// shell script that launchd runs whenever one request file changes; see helper/.
/// Without it, every change goes through Pref.apply and its admin prompt.
enum Helper {
    static let label   = "com.ksha23.preroll.helper"
    static let dir     = "/Library/Application Support/Preroll"
    static let request = dir + "/request"
    static let done    = dir + "/done"
    static let script  = "/Library/PrivilegedHelperTools/" + label
    static var resources: String { Bundle.main.resourcePath ?? "" }

    /// Installed, and installed for THIS user: only they can write the request file.
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
            && access(request, W_OK) == 0
    }
    /// The installed script is not the one this build ships.
    static var outdated: Bool {
        installed && !FileManager.default.contentsEqual(atPath: script,
                                                        andPath: resources + "/preroll-helper.sh")
    }
    static func install() -> String? {
        let src = resources + "/helper-install.sh"
        guard FileManager.default.fileExists(atPath: src) else {
            return "This build does not include the helper."
        }
        return Pref.admin("/bin/sh \(Pref.shq(src)) \(getuid()) \(Pref.shq(resources))")
    }
    static func uninstall() -> String? {
        Pref.admin("/bin/sh \(Pref.shq(resources + "/helper-uninstall.sh"))")
    }

    /// Hands one value to the helper and waits for it to confirm. Blocks, so call it
    /// off the main thread. The record is a fixed 64 bytes written at offset 0 in a
    /// single call, so the helper never reads half a line, and it is rewritten if
    /// launchd missed the first change.
    static func send(_ ms: Int?) -> String? {
        let seq = String(UInt64(Date().timeIntervalSince1970 * 1000))
        var rec = Array("\(seq) \(ms.map(String.init) ?? "off")\n".utf8)
        rec += Array(repeating: UInt8(ascii: " "), count: max(0, 64 - rec.count))
        for _ in 0..<3 {
            let fd = open(request, O_WRONLY)
            guard fd >= 0 else { return "The helper's request file is not writable. Reinstall the helper." }
            let n = rec.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            close(fd)
            guard n == rec.count else { return "Could not write to the helper." }
            for _ in 0..<15 {
                usleep(100_000)
                let d = try? String(contentsOfFile: done, encoding: .utf8)
                if d?.trimmingCharacters(in: .whitespacesAndNewlines) == seq { return nil }
            }
        }
        return "The helper did not respond. Try reinstalling it."
    }
}

// ------------------------------------------------------------------ speaker names

/// CoreAudio names every AirPlay route just "AirPlay", and its UID is minted per
/// AirPlayXPCHelper session and then reused for whatever speakers are picked next,
/// so neither identifies a speaker. The name the user picked is only in the system
/// log, where audioaccessoryd writes one line per route change:
///
///     Received manual route change uid <UID> type output name Bedroom source ControlCenter ...
///
/// That pairs the UID with the user-facing name, stereo pairs included ("Desk
/// Stereo Pair"). Reading the log needs no privileges.
final class RouteNames {
    private(set) var byUID: [String: String] = [:]
    /// UIDs learned live; always newer than anything the backfill finds.
    private var live: Set<String> = []
    var onLive: ((String) -> Void)?
    var onBackfill: (() -> Void)?
    private var stream: Process?
    private var buffer = Data()
    private var stopped = false

    private static let predicate =
        "process == \"audioaccessoryd\" AND eventMessage CONTAINS \"route change uid\""
    private static let re = try! NSRegularExpression(
        pattern: "route change uid (\\S+) type \\S+ name (.+?) source ")

    static func parse(_ line: Data) -> (uid: String, name: String)? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let m = o["eventMessage"] as? String,
              let r = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)),
              let u = Range(r.range(at: 1), in: m), let n = Range(r.range(at: 2), in: m)
        else { return nil }
        return (String(m[u]), String(m[n]))
    }

    /// Streams new route changes, and looks back for the one that named the route
    /// already up at launch: the last hour first (~2 s), then a week (~15 s) only if
    /// that route was older.
    func start(currentUID: @escaping () -> String) {
        // An instance that was killed rather than quit leaves its `log stream`
        // running, reparented to launchd. End any such leftover first.
        let reap = Process()
        reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reap.arguments = ["-P", "1", "-f", "--", "--style ndjson --predicate " + Self.predicate]
        try? reap.run(); reap.waitUntilExit()
        startStream()
        backfill("1h") { [weak self] in
            guard let self else { return }
            let u = currentUID()
            if !u.isEmpty && self.byUID[u] == nil { self.backfill("7d") {} }
        }
    }

    func stop() { stopped = true; stream?.terminate() }

    private func startStream() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.startStream() }
        }
        do { try p.run(); stream = p } catch { stream = nil }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if let (u, n) = Self.parse(line) { byUID[u] = n; live.insert(u); onLive?(u) }
        }
    }

    private func backfill(_ window: String, then: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", window, "--style", "ndjson", "--predicate", Self.predicate]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var found: [String: String] = [:]
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in data.split(separator: 0x0A) {       // oldest first, so the last wins
                    if let (u, n) = Self.parse(Data(line)) { found[u] = n }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (u, n) in found where !self.live.contains(u) { self.byUID[u] = n }
                self.onBackfill?()
                then()
            }
        }
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

    // ---- speakers

    let names = RouteNames()
    var deviceUID = ""
    /// The speaker the current AirPlay route was picked as, e.g. "Bedroom" or "Desk
    /// Stereo Pair". nil when the output is not AirPlay or its name is not known yet.
    @Published var routeName: String?
    /// Each speaker's own latency, keyed by the name it was picked as. A speaker is
    /// added the first time it is picked, at the latency it plays at.
    @Published var profiles: [String: Int] =
        UserDefaults.standard.dictionary(forKey: "profiles") as? [String: Int] ?? [:] {
        didSet { UserDefaults.standard.set(profiles, forKey: "profiles") }
    }
    /// Applied when no saved speaker says otherwise: turning on from Inactive, or
    /// setting a latency with no AirPlay route up.
    var fallbackLatency: Int {
        get { UserDefaults.standard.object(forKey: "savedLatency") as? Int ?? 350 }
        set { UserDefaults.standard.set(newValue, forKey: "savedLatency") }
    }
    @Published var autoSwitch = UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch") }
    }
    @Published var helperInstalled = false
    @Published var helperOutdated = false
    /// After a restart dropped the route: the speaker to pick again, shown in the
    /// menu bar until that route is live.
    @Published var reselect: String?
    private var reselectSince = Date.distantPast
    private var lastSwitch: (ms: Int, at: Date)?
    /// A speaker removed from the list while it was playing. Not re-added until it
    /// is picked again, or × would appear to do nothing.
    private var forgotten: String?

    /// The current speaker's saved latency, if it has one.
    var saved: Int? { routeName.flatMap { profiles[$0] } }

    /// What the current route should run: the speaker's saved latency, else what
    /// was last applied. So a speaker not saved yet, or whose name is not known yet
    /// (the look-back at launch can take ~15 s), is never switched on a guess.
    var wanted: Int { saved ?? Pref.override ?? fallbackLatency }

    /// Master switch: ALL effects. Off removes the latency override AND stops the
    /// keep-alive. On applies what the current route should run and resumes it.
    func setMaster(_ on: Bool) { apply(on ? wanted : nil) }

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
    /// A latency is live only when the stream latency in frames matches it exactly.
    /// 350 ms at 44100 Hz == 15435 frames.
    func frames(_ ms: Int) -> UInt32? {
        sampleRate > 0 ? UInt32((Double(ms) / 1000.0 * sampleRate).rounded()) : nil
    }
    /// The latency the helper is actually running, from the stream frames.
    var streamMs: Int { sampleRate > 0 ? Int((Double(streamFrames) / sampleRate * 1000).rounded()) : 0 }

    func refresh() {
        let d = CA.defaultOutput()
        let l = CA.latency(d)
        deviceName   = CA.name(d)
        deviceUID    = CA.uid(d)
        isAirPlay    = CA.transport(d) == kAirPlay
        routeName    = isAirPlay ? names.byUID[deviceUID] : nil
        sampleRate   = l.sr
        streamFrames = l.stream
        latencyMs    = l.sr > 0 ? Double(l.total) / l.sr * 1000 : 0
        masterOn = Pref.override != nil
        helperInstalled = Helper.installed
        helperOutdated  = Helper.outdated
        if !masterOn                        { health = .off }
        else if !isAirPlay                  { health = .notAirPlay }
        else if l.stream == frames(wanted)  { health = .live }
        else                                { health = .pending }
        if reselect != nil, health == .live || Date().timeIntervalSince(reselectSince) > 90 {
            reselect = nil
        }
        // A speaker picked for the first time is saved at what it plays, provided
        // that is what Preroll last applied. Not mid-switch, when the route about to
        // drop is still up at the old value.
        if health == .live, saved == nil, let n = routeName, n != forgotten,
           reselect == nil, !busy, let o = Pref.override {
            profiles[n] = o
            note = "Saved \(n) at \(o) ms."
        }
        if !busy, !userDirty {
            target = Double(wanted)
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

    /// Sets (nil: removes) the override and restarts AirPlay. Through the helper
    /// when it is installed, which needs no password, else through the prompt.
    func apply(_ ms: Int?) {
        busy = true; note = nil
        let onAirPlay = isAirPlay
        let speaker = routeName
        let finish: (String?) -> Void = { [self] err in
            busy = false
            userDirty = false
            if let err {
                note = err
            } else if let ms {
                if onAirPlay {
                    note = "Set to \(ms) ms. AirPlay restarted; select \(speaker ?? "your speakers") again."
                    reselect = speaker ?? "speakers"; reselectSince = Date()
                } else {
                    note = "Set to \(ms) ms."
                }
            } else {
                note = onAirPlay ? "Removed. Select your speakers again for 2000 ms." : "Removed."
            }
            refresh()
        }
        if Helper.installed {
            DispatchQueue.global(qos: .userInitiated).async {
                let e = Helper.send(ms)
                DispatchQueue.main.async { finish(e) }
            }
        } else {
            DispatchQueue.main.async { finish(Pref.apply(ms)) }
        }
    }

    /// The Apply button. On a known speaker, saves the value as that speaker's and
    /// restarts AirPlay only if it now runs the wrong latency. Otherwise the value
    /// goes to whatever AirPlay route comes next; with no route up the restart
    /// drops nothing.
    func commit() {
        let v = Int(target)
        userDirty = false
        if let n = routeName {
            setProfile(n, v)
            if masterOn && health == .live { note = "Saved for \(n)." }
        } else {
            fallbackLatency = v
            if !masterOn || Pref.override != v || health == .pending { apply(v) }
        }
    }

    /// Sets one speaker's latency from the list or the card. If that speaker is
    /// playing and now runs the wrong latency, switches.
    func setProfile(_ n: String, _ v: Int) {
        profiles[n] = min(max(v, 100), 4000)
        refresh()
        if n == routeName && (!masterOn || health == .pending) { apply(profiles[n]) }
    }

    func removeProfile(_ n: String) {
        profiles[n] = nil
        if n == routeName { forgotten = n }
        refresh()
    }

    /// A route change in the log. If the speaker just picked should run a different
    /// latency from what AirPlay is running, switch: restart AirPlay, after which
    /// the user picks the speaker once more. Only with the helper, since a password
    /// dialog on every speaker change would be worse than the banner's button.
    func routeChanged(_ uid: String) {
        // The log line lands just after CoreAudio activates the device; let it settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            forgotten = nil
            refresh()
            guard autoSwitch, helperInstalled, masterOn, !busy,
                  isAirPlay, deviceUID == uid, routeName != nil, health == .pending else { return }
            // A switch to this same value moments ago did not take. Stop there rather
            // than restart AirPlay on every pick; the banner keeps its button.
            if let s = lastSwitch, s.ms == wanted, Date().timeIntervalSince(s.at) < 30 { return }
            lastSwitch = (wanted, Date())
            apply(wanted)
        }
    }

    func installHelper() {
        busy = true; note = nil
        DispatchQueue.main.async { [self] in
            let e = Helper.install()
            busy = false
            note = e ?? "Helper installed. Changes no longer ask for a password."
            refresh()
        }
    }

    func removeHelper() {
        busy = true; note = nil
        DispatchQueue.main.async { [self] in
            let e = Helper.uninstall()
            busy = false
            note = e ?? "Helper removed."
            refresh()
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
        case .pending:    return "Needs switch"
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
                    Text(m.routeName ?? m.deviceName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
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
                        Text(m.routeName.map { "\($0) is set to \(m.wanted) ms, running \(m.streamMs)" }
                             ?? "Running at \(m.streamMs) ms, set to \(m.wanted) ms")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                            .lineLimit(1)
                        Text("Switch restarts AirPlay; then select your speakers again")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(m.busy ? "Switching…" : "Switch") {
                        m.apply(m.wanted)
                    }.controlSize(.small).disabled(m.busy)
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
                         : "Nothing applied. Turn on to use \(m.wanted) ms")
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
                    Text(m.routeName.map { "Latency for \($0)" } ?? "Latency")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
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
                Text((m.routeName != nil
                      ? "Saved for this speaker. "
                      : "Goes to the next AirPlay speaker you pick. ")
                     + "Lower feels more responsive but leaves less buffer for Wi-Fi jitter, and dropouts are the failure mode. The sender reports a floor of 250 ms; type a value for anything off the slider.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Button(m.busy ? "Applying…" : (m.masterOn ? "Apply" : "Apply and activate")) {
                        fieldFocused = false
                        m.commit()
                    }
                    .disabled(m.busy || (m.masterOn && m.health != .pending && Int(m.target) == m.wanted))
                    .controlSize(.regular)
                    Text(m.helperInstalled ? "No password needed" : "Asks for your admin password")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                if let n = m.note {
                    Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }

            // ---- speakers
            Card {
                Text("Speakers").font(.system(size: 13, weight: .medium))
                if m.profiles.isEmpty {
                    Text("Each speaker you pick is saved here at the latency it plays at. Change a value to give that speaker its own.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(m.profiles.keys.sorted(), id: \.self) { n in
                            HStack(spacing: 6) {
                                Text(n).font(.system(size: 12)).lineLimit(1)
                                if n == m.routeName {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("", value: Binding(get: { m.profiles[n] ?? 0 },
                                                             set: { m.setProfile(n, $0) }),
                                          format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .font(.system(size: 12, design: .rounded)).monospacedDigit()
                                    .frame(width: 56).disabled(m.busy)
                                Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                                Button { m.removeProfile(n) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).disabled(m.busy)
                                .help("Remove \(n)")
                            }
                        }
                    }
                }
                Row(title: "Switch automatically",
                    detail: m.helperInstalled
                        ? "When you pick a saved speaker whose latency differs from what is running, Preroll restarts AirPlay to apply it, and you pick the speaker once more."
                        : "Installs a small root helper, once, so changes never ask for a password. That is what lets Preroll switch by itself when you pick a speaker.") {
                    if m.helperInstalled {
                        Toggle("", isOn: $m.autoSwitch).toggleStyle(.switch)
                            .labelsHidden().controlSize(.small)
                    } else {
                        Button("Install…") { m.installHelper() }
                            .controlSize(.small).disabled(m.busy)
                    }
                }
                if m.helperInstalled {
                    HStack {
                        if m.helperOutdated {
                            Button("Update helper…") { m.installHelper() }
                                .controlSize(.small).disabled(m.busy)
                        }
                        Spacer()
                        Button("Remove helper…") { m.removeHelper() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .disabled(m.busy)
                    }
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

        model.names.onLive = { [weak self] uid in self?.model.routeChanged(uid) }
        model.names.onBackfill = { [weak self] in self?.model.refresh(); self?.icon() }
        model.names.start { [weak self] in
            guard let m = self?.model, m.isAirPlay else { return "" }
            return m.deviceUID
        }

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
        if let r = model.reselect {
            b.title = " Select " + (r.count > 20 ? r.prefix(19) + "…" : r)
        } else {
            b.title = model.isAirPlay ? String(format: " %.0f", model.latencyMs) : ""
        }
        // Last-resort guard: never leave the item with nothing to draw.
        if b.image == nil && b.title.isEmpty { b.title = "AP" }
        b.alphaValue = model.masterOn ? 1.0 : 0.55
        b.toolTip = model.masterOn
            ? "Preroll: active" : "Preroll: inactive"
    }

    func applicationWillTerminate(_ n: Notification) { model.names.stop() }

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
