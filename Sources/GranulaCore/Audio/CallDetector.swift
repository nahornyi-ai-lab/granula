import Foundation

// Call-app list adapted from amanu (MIT, Copyright (c) 2026 Andrew Jones,
// Samat Galimov), Sources/amanu/Audio/MicActivityMonitor.swift.

/// Polls Core Audio every 2 s for call apps holding the microphone. It only
/// suggests recording; it never starts one by itself.
@MainActor
public final class CallDetector {
    public struct CallApp: Equatable, Sendable {
        /// Bundle-id prefix that matched, e.g. "ru.keepcoder.Telegram".
        public let family: String
        public let name: String
    }

    /// Bundle-id prefixes that mean "a call is happening".
    public static let defaultCallApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "ru.keepcoder.Telegram": "Telegram",
        "com.tdesktop.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.apple.WebKit.GPU": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
    ]

    public static let extraAppsKey = "extraCallApps"
    static let promptAfter: TimeInterval = 3
    static let pollInterval: TimeInterval = 2

    /// A call app has held the mic long enough. Returns whether the prompt was
    /// handled (shown); if not (a recording is running), it is offered again later.
    public var onCallDetected: ((CallApp) -> Bool)?
    /// A call app released the microphone.
    public var onCallEnded: ((String) -> Void)?

    private var timer: Timer?
    private var firstSeen: [String: Date] = [:]
    private var prompted: Set<String> = []
    public private(set) var lastActive: [String: Date] = [:]
    public private(set) var activeNow: Set<String> = []

    public init() {}

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Bundle-id prefix → display name, defaults plus `extraCallApps`.
    public static func callApps() -> [String: String] {
        var apps = defaultCallApps
        for extra in UserDefaults.standard.stringArray(forKey: extraAppsKey) ?? [] {
            let trimmed = extra.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, apps[trimmed] == nil {
                apps[trimmed] = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
            }
        }
        return apps
    }

    /// No prompt for this call any more (it is being or was recorded).
    public func markHandled(_ family: String) {
        if activeNow.contains(family) { prompted.insert(family) }
    }

    /// Whether `family` has been off the microphone for at least `seconds`.
    public func isInactive(_ family: String, for seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard !activeNow.contains(family) else { return false }
        return now.timeIntervalSince(lastActive[family] ?? .distantPast) >= seconds
    }

    private func poll() {
        let now = Date()
        let apps = Self.callApps()
        var active: [String: String] = [:]
        for process in AudioProcesses.all() where process.runningInput {
            guard let family = apps.keys.filter({ process.bundleID.hasPrefix($0) }).max(by: { $0.count < $1.count })
            else { continue }
            active[family] = apps[family]
        }

        for family in active.keys {
            lastActive[family] = now
            if firstSeen[family] == nil {
                firstSeen[family] = now
                Log.event("call.mic_on", "app=\(family)")
            }
        }
        for family in activeNow.subtracting(active.keys) {
            firstSeen[family] = nil
            prompted.remove(family)
            Log.event("call.mic_off", "app=\(family)")
            onCallEnded?(family)
        }
        activeNow = Set(active.keys)

        for (family, name) in active where !prompted.contains(family) {
            if let seen = firstSeen[family], now.timeIntervalSince(seen) >= Self.promptAfter {
                if onCallDetected?(CallApp(family: family, name: name)) ?? false {
                    prompted.insert(family)
                }
            }
        }
    }
}
