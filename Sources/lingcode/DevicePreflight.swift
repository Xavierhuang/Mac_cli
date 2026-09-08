import Foundation

/// Device-deploy preflight for the headless path.
///
/// The Mac app has run `SigningPreflightService` before an iOS deploy for a long
/// time, but that service lives in the app target, so `lingcode ask` and
/// `lingcode build` — the CLI and every CI job — got none of it. The agent
/// discovered each broken fact by failing into it, one build at a time.
///
/// Measured cost of that gap (benchmarks/xcode Lane 1, physical iPhone, same
/// model both sides): with Developer Mode switched off, plain Claude Code spent
/// 51 turns, $1.14 and 2.1M cached tokens and never once identified Developer
/// Mode as the cause. With an Xcode too old to target the handset, it burned 855
/// seconds and never got the app onto the phone. Neither failure is the model's
/// fault: nothing in the prompt told it these things were true, and both errors
/// name the wrong cause when you hit them cold.
///
/// This is deliberately NOT a port of the app's 13-check service. It covers the
/// checks that block getting a build onto a connected device, it never mutates
/// anything, and it degrades to silence: any probe that fails is omitted rather
/// than guessed at. A preflight that invents state is worse than none.
enum DevicePreflight {

    /// Returns a prompt block describing what is wrong with this machine right
    /// now, or nil when there is nothing useful to say.
    static func contextBlock(cwd: URL) -> String? {
        guard looksLikeAppleProject(cwd) else { return nil }
        // Say nothing at all about a project that cannot target a device.
        guard targetsADevicePlatform(cwd) else { return nil }

        var findings: [String] = []
        let devices = connectedDevices()

        // ---- Developer Mode ------------------------------------------------
        // No command can turn this on; it is a physical toggle that reboots the
        // phone. Saying so up front is the entire value — an agent that does not
        // know will keep trying until it runs out of turns.
        for d in devices where d.developerMode == "disabled" {
            findings.append("""
            Developer Mode is DISABLED on \(d.name) (iOS \(d.osVersion)). No app can be \
            installed for development until it is on, and NO COMMAND CAN ENABLE IT — the \
            user must do it on the device: Settings > Privacy & Security > Developer Mode, \
            then reboot. Do not spend turns trying to work around this; tell the user.
            """)
        }

        // ---- Toolchain vs device OS ---------------------------------------
        // The failure mode this exists for: Xcode reports "iOS <ver> is not
        // installed. Please download and install the platform from Xcode >
        // Settings > Components" when that platform IS installed and the real
        // problem is that the ACTIVE Xcode's SDK is older than the phone.
        // Following the message wastes a large download and fixes nothing.
        if let maxSDK = activeXcodeMaxIOSSDK() {
            for d in devices {
                guard let devMajor = Int(d.osVersion.split(separator: ".").first.map(String.init) ?? ""),
                      devMajor > maxSDK else { continue }
                var msg = """
                The active Xcode's iOS SDK is \(maxSDK), which CANNOT target \(d.name) on iOS \
                \(d.osVersion). Builds will fail with "iOS \(maxSDK).x is not installed. Please \
                download and install the platform" — that message is misleading: the platform IS \
                installed, and installing it again will not help.
                """
                if let alt = xcodeThatCanTarget(devMajor) {
                    msg += " Use the newer Xcode already on this machine instead: " +
                           "DEVELOPER_DIR=\(alt)/Contents/Developer"
                } else {
                    msg += " No installed Xcode can target it; the user needs a newer Xcode."
                }
                findings.append(msg)
            }
        }

        // ---- Signing team --------------------------------------------------
        if let spec = projectSpec(cwd), !spec.contains("DEVELOPMENT_TEAM") {
            var msg = "No DEVELOPMENT_TEAM is set in this project, so a device build cannot be signed."
            if let team = firstProvisioningTeam() {
                msg += " A profile for team \(team) exists on this machine and is the likely value."
            }
            findings.append(msg)
        }

        // ---- Provisioning profile specifier --------------------------------
        // Manual signing pinned to a profile that is not installed. xcodebuild's
        // error names the profile but not the remedy.
        if let spec = projectSpec(cwd),
           let named = value(of: "PROVISIONING_PROFILE_SPECIFIER", in: spec),
           !installedProfileNames().contains(named) {
            findings.append("""
            This project requests provisioning profile "\(named)", which is NOT installed on this \
            machine. Manual signing cannot succeed against a profile that does not exist. Either \
            switch to automatic signing (CODE_SIGN_STYLE: Automatic with a DEVELOPMENT_TEAM) or \
            install that profile.
            """)
        }

        // ---- a newer Xcode is installed than the active one ---------------
        // The device-versus-SDK check above only fires when a handset is
        // attached. Archiving for the App Store needs no device, and this machine
        // still could not archive at all: the active Xcode had no usable iOS
        // platform and reported "iOS 26.5 is not installed" while iOS 26.5 was
        // installed. A strictly newer Xcode sitting in /Applications is worth
        // naming whenever an Apple project is in play, device or not.
        if let activeSDK = activeXcodeMaxIOSSDK(), let newer = xcodeThatCanTarget(activeSDK + 1) {
            findings.append("""
            The active Xcode's iOS SDK is \(activeSDK), but \(newer) is installed with a newer \
            one. If a build fails with "iOS \(activeSDK).x is not installed. Please download and \
            install the platform", that message is misleading — the platform is installed and the \
            active toolchain is simply too old. Use DEVELOPER_DIR=\(newer)/Contents/Developer.
            """)
        }

        // ---- rsync shadowing (App Store export) ---------------------------
        // `xcodebuild -exportArchive` shells out to rsync for
        // IDEDistributionCreateIPAStep and needs APPLE's openrsync at both ends.
        // A Homebrew rsync 3.x earlier on PATH answers as the server, rejects
        // openrsync's --extended-attributes, and the whole export dies with
        // nothing but "error: exportArchive Copy failed" — the real cause is
        // buried in a temp .xcdistributionlogs bundle nobody thinks to read.
        //
        // This is not hypothetical: it silently broke Magic Deploy in the Mac app
        // for every machine with Homebrew rsync until 2026-08-22, and it blocked
        // this benchmark's own first App Store export.
        //
        // Deliberately NOT phrased as "remove Homebrew rsync": the website deploy
        // script requires it, because macOS's openrsync segfaults on that push.
        // Two pipelines on one machine genuinely need different rsyncs, so the
        // only correct fix is per-command PATH ordering.
        if let which = run("/bin/zsh", ["-l", "-c", "which -a rsync"], timeout: 10) {
            let first = which.split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty, first != "/usr/bin/rsync" {
                findings.append("""
                \(first) shadows /usr/bin/rsync on PATH. `xcodebuild -exportArchive` needs \
                Apple's openrsync and will fail with a bare "error: exportArchive Copy failed" \
                that names no cause. Prefix the export command with \
                `PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH` — set it INSIDE the command, because \
                a login shell re-sources the profile and discards an environment assignment. \
                Do not remove the other rsync; other tooling on this machine needs it.
                """)
            }
        }

        guard !findings.isEmpty else { return nil }
        return """
        <device-preflight>
        These facts about THIS machine were checked before you started. They are current and \
        verified — do not re-derive them, and do not assume a build failure has a different cause \
        until you have addressed them.

        \(findings.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n"))
        </device-preflight>
        """
    }

    // MARK: - Probes

    private struct Device { let name: String; let osVersion: String; let developerMode: String }

    /// True only when this project can actually target a device.
    ///
    /// Every finding in this preflight is about DEVICE deployment — Developer Mode,
    /// the iOS SDK, signing teams, provisioning profiles. On a macOS-only project
    /// none of it applies, and saying it anyway is not merely noise: measured on
    /// benchmarks/xcode task 002 (a macOS app), the agent took the toolchain advice
    /// and re-ran its build under a different Xcode. A different Xcode means a
    /// different module cache, so that bought a full cold rebuild for nothing and
    /// made the run 55% slower than plain Claude Code. Irrelevant context is not
    /// free; it gets acted on.
    private static func targetsADevicePlatform(_ cwd: URL) -> Bool {
        guard let spec = projectSpec(cwd) else { return false }
        // xcodegen spec, or pbxproj build settings.
        let markers = ["platform: iOS", "platform: watchOS", "platform: tvOS",
                       "platform: visionOS", "SDKROOT = iphoneos", "SDKROOT = watchos",
                       "SDKROOT = appletvos", "SDKROOT = xros",
                       "\"iphoneos\"", "iOS:"]
        return markers.contains { spec.contains($0) }
    }

    private static func looksLikeAppleProject(_ cwd: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cwd.path) else { return false }
        return entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            || entries.contains("project.yml")
    }

    private static func connectedDevices() -> [Device] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingcode-preflight-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard run("/usr/bin/xcrun",
                  ["devicectl", "list", "devices", "--json-output", tmp.path],
                  timeout: 20) != nil,
              let data = try? Data(contentsOf: tmp),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let list = result["devices"] as? [[String: Any]]
        else { return [] }

        return list.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            if (hw["isSimulated"] as? Bool) == true { return nil }
            guard (conn["pairingState"] as? String) == "paired",
                  ["connected", "available"].contains(conn["tunnelState"] as? String ?? "")
            else { return nil }
            return Device(name: props["name"] as? String ?? "the device",
                          osVersion: props["osVersionNumber"] as? String ?? "?",
                          developerMode: props["developerModeStatus"] as? String ?? "")
        }
    }

    private static func maxIOSSDK(inDeveloperDir dir: String) -> Int? {
        let sdks = dir + "/Platforms/iPhoneOS.platform/Developer/SDKs"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sdks) else { return nil }
        return entries.compactMap { name -> Int? in
            guard name.hasPrefix("iPhoneOS"), name.hasSuffix(".sdk") else { return nil }
            let digits = name.dropFirst("iPhoneOS".count).prefix { $0.isNumber }
            return Int(digits)
        }.max()
    }

    private static func activeXcodeMaxIOSSDK() -> Int? {
        guard let dir = run("/usr/bin/xcode-select", ["-p"], timeout: 10)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return nil }
        return maxIOSSDK(inDeveloperDir: dir)
    }

    /// Any installed Xcode whose iOS SDK is new enough for `major`.
    private static func xcodeThatCanTarget(_ major: Int) -> String? {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(atPath: "/Applications"))?
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") } ?? []
        for app in apps.sorted() {
            let path = "/Applications/" + app
            if let sdk = maxIOSSDK(inDeveloperDir: path + "/Contents/Developer"), sdk >= major {
                return path
            }
        }
        return nil
    }

    /// project.yml plus any pbxproj, concatenated — enough to answer "is this set".
    private static func projectSpec(_ cwd: URL) -> String? {
        var text = ""
        let yml = cwd.appendingPathComponent("project.yml")
        if let s = try? String(contentsOf: yml, encoding: .utf8) { text += s }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cwd.path) {
            for e in entries where e.hasSuffix(".xcodeproj") {
                let pbx = cwd.appendingPathComponent(e).appendingPathComponent("project.pbxproj")
                if let s = try? String(contentsOf: pbx, encoding: .utf8) { text += s }
            }
        }
        return text.isEmpty ? nil : text
    }

    private static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains(key) {
            guard let range = line.range(of: key) else { continue }
            var rest = line[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " :=\t"))
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    private static func profileDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Library/Developer/Xcode/UserData/Provisioning Profiles",
                "\(home)/Library/MobileDevice/Provisioning Profiles"]
    }

    /// Names of installed profiles. `security cms -D` emits the plist followed by
    /// trailing CMS bytes, so this reads the Name value textually rather than
    /// through a strict plist parser, which rejects it.
    private static func installedProfileNames() -> Set<String> {
        var names = Set<String>()
        for dir in profileDirs() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".mobileprovision") {
                guard let out = run("/usr/bin/security", ["cms", "-D", "-i", dir + "/" + e], timeout: 10)
                else { continue }
                if let r = out.range(of: "<key>Name</key>") {
                    let after = out[r.upperBound...]
                    if let s = after.range(of: "<string>"), let e2 = after.range(of: "</string>") {
                        names.insert(String(after[s.upperBound..<e2.lowerBound]))
                    }
                }
            }
        }
        return names
    }

    private static func firstProvisioningTeam() -> String? {
        for dir in profileDirs() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".mobileprovision") {
                guard let out = run("/usr/bin/security", ["cms", "-D", "-i", dir + "/" + e], timeout: 10)
                else { continue }
                if let r = out.range(of: "<key>TeamIdentifier</key>") {
                    let after = out[r.upperBound...]
                    if let s = after.range(of: "<string>"), let e2 = after.range(of: "</string>") {
                        return String(after[s.upperBound..<e2.lowerBound])
                    }
                }
            }
        }
        return nil
    }

    /// Bounded shell-out. Returns nil on timeout or launch failure — every caller
    /// treats nil as "cannot say", never as a negative finding.
    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate(); return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    /// nil when empty, so an absent preflight block does not send an empty
    /// appendSystemPrompt to the bridge.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
