import AppKit
import CoreServices
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

// Reads this Mac, as one JSON object: what the window draws. It only reads
// (sysctl, IOKit, Spotlight's metadata, system_profiler, the install
// history, launchctl's list of what is switched off); nothing is written or
// changed, and nothing leaves the machine.
//   Machine.read()   everything (when the window opens)
//   Machine.live()   memory, GPU load, uptime, battery charge, thermal state
//                    and devices
//                    (every few seconds)
enum Machine {

    // MARK: - small readers

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0, size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 { return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v) }
        return nil
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return data
    }

    static func ioProps(_ service: io_object_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return d
    }

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    // MARK: - live facts

    // Memory as Activity Monitor counts "Memory Used": app memory (anonymous
    // pages less purgeable ones), wired and compressed.
    static func memory() -> [String: Any] {
        let total = sysctlInt("hw.memsize") ?? 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return ["total": total, "used": NSNull()] }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return ["total": total, "used": max(0, pages) * Int64(page)]
    }

    static func uptime() -> Int? {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return now() - Int(tv.tv_sec)
    }

    // The GPU's load, as the driver reports it (Apple's GPUs: "Device
    // Utilization %"); nil where it doesn't.
    static func gpuUsage() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        var s = IOIteratorNext(iter)
        while s != 0 {
            if let perf = ioProps(s)["PerformanceStatistics"] as? [String: Any],
               let u = (perf["Device Utilization %"] ?? perf["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, u.doubleValue)
            }
            IOObjectRelease(s)
            s = IOIteratorNext(iter)
        }
        return best
    }

    // The battery's charge right now, as the menu bar shows it (IOKit's
    // power sources): how full, whether it is on power and charging, and the
    // minutes left (to empty, or to full while charging; nil while macOS is
    // still working it out). Nil without a battery.
    static func charge() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let mins = (charging ? d[kIOPSTimeToFullChargeKey] : plugged ? nil : d[kIOPSTimeToEmptyKey]) as? Int
            return ["percent": Int((Double(cur) / Double(max) * 100).rounded()), "plugged": plugged, "charging": charging,
                    "charged": (d[kIOPSIsChargedKey] as? Bool) ?? false,
                    "minutes": mins.flatMap { $0 > 0 ? $0 : nil } as Any? ?? NSNull()]
        }
        return nil
    }

    // How hot macOS judges the Mac to be, its own four steps: "nominal",
    // "fair" (it may hold back background work), "serious" (it slows the
    // chip to cool it) and "critical".
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    static func live(devices withDevices: Bool = true) -> [String: Any] {
        var v: [String: Any] = ["memory": memory(), "uptime": uptime() as Any? ?? NSNull(), "now": now(),
                                "gpu": ["usage": gpuUsage() as Any? ?? NSNull()],
                                "charge": charge() as Any? ?? NSNull(), "thermal": thermal()]
        if withDevices { v["devices"] = devices() }
        return v
    }

    // MARK: - hardware

    struct Profile { var hw: [String: Any] = [:]; var gpu: [String: Any] = [:] }

    // system_profiler: the model's name and number, serial, firmware, and the
    // GPU's core count (which nothing else reports without root).
    static func profile() -> Profile {
        var p = Profile()
        guard let data = run("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPDisplaysDataType", "-json", "-detailLevel", "mini"], timeout: 12),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return p }
        p.hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        let gpus = (json["SPDisplaysDataType"] as? [[String: Any]]) ?? []
        p.gpu = gpus.first(where: { ($0["sppci_cores"] as? String) != nil }) ?? gpus.first ?? [:]
        return p
    }

    // The serial number, from IOKit (system_profiler's is the same; this one
    // works even when system_profiler is slow or missing).
    static func serial() -> String? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        return IORegistryEntryCreateCFProperty(s, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    // The marketing name ("MacBook Pro (14-inch, M3, 2023)") where macOS
    // ships one for this model; newer models aren't in the list yet.
    static func marketingName(_ modelId: String) -> String? {
        let path = "/System/Library/PrivateFrameworks/ServerInformation.framework/Versions/A/Resources/en.lproj/SIMachineAttributes.plist"
        guard let d = NSDictionary(contentsOfFile: path) as? [String: Any],
              let e = d[modelId] as? [String: Any], let l = e["_LOCALIZABLE_"] as? [String: Any],
              let name = l["marketingModel"] as? String, !name.isEmpty else { return nil }
        return name
    }

    // Each display, as System Settings lists them: the built-in one first.
    // (Must run on the main thread: NSScreen.)
    static func displays() -> [[String: Any]] {
        var out: [(builtin: Bool, d: [String: Any])] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let builtin = CGDisplayIsBuiltin(id) != 0
            let mode = CGDisplayCopyDisplayMode(id)
            var hz = Double(screen.maximumFramesPerSecond)
            if let r = mode?.refreshRate, r > 0 { hz = max(hz, r) }
            let mm = CGDisplayScreenSize(id)
            let inches: Any = mm.width > 0 && mm.height > 0 ? Double(sqrt(mm.width * mm.width + mm.height * mm.height) / 25.4) : NSNull()
            out.append((builtin, [
                "name": screen.localizedName, "type": builtin ? "Builtin" : "External",
                // What the screen looks like (points), and its real pixels.
                "width": Int(screen.frame.width), "height": Int(screen.frame.height),
                "pixelsW": mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                "pixelsH": mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                "hz": hz > 0 ? hz : NSNull(), "inches": inches
            ]))
        }
        return Array(out.enumerated().sorted { a, b in a.element.builtin != b.element.builtin ? a.element.builtin : a.offset < b.offset }.map { $0.element.d }.prefix(8))
    }

    // The battery's health: how much it holds now against how much it held
    // new (the raw figures, mAh, as coconutBattery shows them; System
    // Settings rounds its own), its cycles, and the same in Wh.
    static func battery() -> [String: Any]? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        let p = ioProps(s)
        func n(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue ?? ((p["BatteryData"] as? [String: Any])?[k] as? NSNumber)?.doubleValue }
        guard let design = n("DesignCapacity"), design > 0,
              let full = n("AppleRawMaxCapacity") ?? n("NominalChargeCapacity") else { return nil }
        let volts = (n("Voltage") ?? 0) / 1000
        var b: [String: Any] = ["health": full / design, "mAh": full, "designMAh": design]
        b["wh"] = volts > 0 ? full * volts / 1000 : NSNull()
        b["designWh"] = volts > 0 ? design * volts / 1000 : NSNull()
        b["cycles"] = (n("CycleCount") ?? 0) > 0 ? Int(n("CycleCount")!) : NSNull()
        b["designCycles"] = n("DesignCycleCount9C").map { Int($0) } as Any? ?? NSNull()
        b["percent"] = n("MaxCapacity").map { Int($0) } as Any? ?? NSNull()
        b["charge"] = charge() as Any? ?? NSNull()
        return b
    }

    // What is plugged in or paired: USB devices (not hubs, nor the Mac's own
    // built-in ones), and Bluetooth devices, connected or only paired.
    // Bluetooth comes from system_profiler, which asks bluetoothd: MacMark
    // itself never touches Bluetooth (that would need its permission).
    static func devices() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS {
            var s = IOIteratorNext(iter)
            while s != 0 {
                let p = ioProps(s)
                let cls = (p["bDeviceClass"] as? NSNumber)?.intValue ?? 0
                let builtIn = (p["Built-In"] as? Bool) == true || (p["non-removable"] as? String) == "yes"
                if cls != 9 && !builtIn {
                    var name = (p["USB Product Name"] ?? p["kUSBProductString"]) as? String ?? ""
                    if name.isEmpty {
                        var buf = [CChar](repeating: 0, count: 128)
                        if IORegistryEntryGetName(s, &buf) == KERN_SUCCESS { name = String(cString: buf) }
                    }
                    out.append(["name": name.isEmpty ? "USB device" : name, "bus": "USB", "kind": "", "connected": true])
                }
                IOObjectRelease(s)
                s = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        if let data = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 6),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let ctl = (json["SPBluetoothDataType"] as? [[String: Any]])?.first {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in (ctl[key] as? [[String: Any]]) ?? [] {
                    for (name, v) in entry.sorted(by: { $0.key < $1.key }) {
                        let kind = ((v as? [String: Any])?["device_minorType"] as? String) ?? ""
                        out.append(["name": name, "bus": "Bluetooth", "kind": kind, "connected": connected])
                    }
                }
            }
        }
        return out
    }

    // The startup disk as Finder and About This Mac count it: the whole APFS
    // container (system and data share it), with purgeable space as free.
    static func storage() -> [String: Any] {
        let url = URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let v = try? url.resourceValues(forKeys: keys)
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? ""
        var fs = "APFS"
        var st = statfs()
        if statfs("/", &st) == 0 { fs = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }.uppercased() }
        guard let total = v?.volumeTotalCapacity, total > 0 else { return ["total": NSNull(), "used": NSNull(), "fs": fs, "name": name] }
        let free = v?.volumeAvailableCapacityForImportantUsage.map { Int($0) } ?? v?.volumeAvailableCapacity ?? 0
        return ["total": total, "used": max(0, total - free), "fs": fs, "name": name]
    }

    // What fills the startup disk, by the categories Storage settings uses
    // (General › Storage). macOS works those out privately; this measures
    // the folders behind each one (du, in parallel; ~10 s), and what isn't
    // in any of them is System Data, as there. A category whose folder
    // privacy protection keeps closed (Messages needs Full Disk Access) is
    // reported as unreadable, and its space stays in System Data.
    static func storageParts(total: Int, used: Int) -> [String: Any] {
        let home = NSHomeDirectory(), fm = FileManager.default
        let cats: [(name: String, paths: [String])] = [
            ("Applications", ["/Applications", home + "/Applications"]),
            ("Documents", [home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Movies"]),
            ("Developer", [home + "/Library/Developer", "/Library/Developer", "/opt/homebrew"]),
            ("Photos", [home + "/Pictures"]),
            ("Music", [home + "/Music"]),
            ("Messages", [home + "/Library/Messages"]),
            ("iCloud Drive", [home + "/Library/Mobile Documents"])
        ]
        var sizes = [Int?](repeating: nil, count: cats.count), partial = [Bool](repeating: false, count: cats.count)
        let group = DispatchGroup(), lock = NSLock()
        for (i, c) in cats.enumerated() {
            let paths = c.paths.filter { fm.fileExists(atPath: $0) }
            if paths.isEmpty { sizes[i] = 0; continue }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                // A folder that can't even be listed: closed by privacy protection.
                let open = paths.filter { (try? fm.contentsOfDirectory(atPath: $0)) != nil }
                if open.isEmpty { return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                p.arguments = ["-skx"] + open
                // (Errors to a file: a full stderr pipe nobody reads would stall du.)
                let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("macmark-du-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                let out = Pipe(), errFile = try? FileHandle(forWritingTo: errURL)
                p.standardOutput = out; p.standardError = errFile ?? FileHandle.nullDevice
                defer { try? errFile?.close(); try? FileManager.default.removeItem(at: errURL) }
                guard (try? p.run()) != nil else { return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                let kib = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
                    .compactMap { Int($0.split(separator: "\t").first ?? "") }.reduce(0, +)
                lock.lock()
                sizes[i] = kib * 1024
                partial[i] = open.count < paths.count || errText.contains("not permitted")
                lock.unlock()
            }
        }
        group.wait()
        // macOS itself: the sealed system volume's own used space (statfs
        // gives the whole APFS container's, shared by every volume in it).
        var system = 0
        if let d = run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 10),
           let info = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
           let n = info["CapacityInUse"] as? NSNumber { system = n.intValue }
        var parts: [[String: Any]] = []
        var known = system
        for (i, c) in cats.enumerated() {
            if let b = sizes[i] {
                known += b
                if b > 0 || c.name == "Applications" { parts.append(["name": c.name, "bytes": b, "partial": partial[i]]) }
            } else {
                parts.append(["name": c.name, "bytes": NSNull(), "partial": true])
            }
        }
        parts.append(["name": "macOS", "bytes": system, "partial": false])
        parts.append(["name": "System Data", "bytes": max(0, used - known), "partial": false])
        return ["parts": parts, "at": now()]
    }

    // MARK: - software

    // Apps in /Applications (and one folder down, as some come in a folder)
    // and ~/Applications: each one's size on disk in KiB, in the order they
    // were added (Spotlight's metadata, as Finder shows it).
    static func apps() -> [String: Any] {
        let fm = FileManager.default
        var urls: [URL] = []
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for u in items {
                if u.pathExtension == "app" { urls.append(u); continue }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                   let sub = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    urls.append(contentsOf: sub.filter { $0.pathExtension == "app" })
                }
            }
        }
        var rows: [(added: Double, kib: Int)] = []
        for u in urls {
            var added = 0.0, bytes = 0
            if let item = MDItemCreateWithURL(kCFAllocatorDefault, u as CFURL) {
                if let d = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date { added = d.timeIntervalSince1970 }
                if let n = MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber { bytes = n.intValue }
                else if let n = MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber { bytes = n.intValue }
            }
            if added == 0, let d = (try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate { added = d.timeIntervalSince1970 }
            rows.append((added, bytes / 1024))
        }
        rows.sort { $0.added < $1.added }
        return ["count": rows.count, "sizes": rows.map { $0.kib }]
    }

    // Homebrew's formulae and casks, where it is installed.
    static func homebrew() -> [String: Any]? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let fm = FileManager.default
            guard fm.fileExists(atPath: prefix + "/bin/brew") else { continue }
            let f = (try? fm.contentsOfDirectory(atPath: prefix + "/Cellar"))?.filter { !$0.hasPrefix(".") }.count ?? 0
            let c = (try? fm.contentsOfDirectory(atPath: prefix + "/Caskroom"))?.filter { !$0.hasPrefix(".") }.count ?? 0
            return ["formulae": f, "casks": c]
        }
        return nil
    }

    // Everything macOS has installed, from its own history: system updates,
    // security responses, App Store apps, packages. Their dates, and which
    // were macOS's own updates.
    struct Install { let date: Double; let name: String; let system: Bool }
    static func installHistory() -> [Install] {
        guard let data = FileManager.default.contents(atPath: "/Library/Receipts/InstallHistory.plist"),
              let arr = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let d = e["date"] as? Date else { return nil }
            let name = e["displayName"] as? String ?? "", proc = e["processName"] as? String ?? ""
            let system = proc == "softwareupdated" || proc == "Software Update" || proc == "macOS Installer" || name.hasPrefix("macOS")
            return Install(date: d.timeIntervalSince1970, name: name, system: system)
        }.sorted { $0.date < $1.date }
    }

    // When this Mac was set up: Setup Assistant marks it done (the root
    // volume's own date moves with every update: it is sealed anew).
    static func setupDate(_ history: [Install]) -> Int {
        for path in ["/private/var/db/.AppleSetupDone", "/var/db/.AppleSetupDone"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: path), let d = a[.modificationDate] as? Date { return Int(d.timeIntervalSince1970) }
        }
        if let first = history.first { return Int(first.date) }
        if let a = try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory()), let d = a[.creationDate] as? Date { return Int(d.timeIntervalSince1970) }
        return 0
    }

    // Background items added by apps (not Apple's own): launch agents and
    // daemons, and which of them are switched off.
    static func backgroundItems() -> [String: Any] {
        let home = NSHomeDirectory()
        let sets: [(dir: String, domain: String)] = [
            (home + "/Library/LaunchAgents", "gui/\(getuid())"),
            ("/Library/LaunchAgents", "gui/\(getuid())"),
            ("/Library/LaunchDaemons", "system")
        ]
        var disabled: [String: Set<String>] = [:]
        for domain in Set(sets.map { $0.domain }) {
            var off = Set<String>()
            if let d = run("/bin/launchctl", ["print-disabled", domain], timeout: 3), let text = String(data: d, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\"")
                    if parts.count >= 3, line.contains("=> disabled") || line.contains("=> true") { off.insert(String(parts[1])) }
                }
            }
            disabled[domain] = off
        }
        var on: [Bool] = [], names: [String] = []
        for s in sets {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: s.dir) else { continue }
            for f in files.sorted() where f.hasSuffix(".plist") && !f.hasPrefix("com.apple.") {
                let plist = NSDictionary(contentsOfFile: s.dir + "/" + f)
                let label = plist?["Label"] as? String ?? String(f.dropLast(6))
                names.append(label)
                on.append(!(disabled[s.domain]?.contains(label) ?? false) && !((plist?["Disabled"] as? Bool) ?? false))
            }
        }
        return ["count": on.count, "on": on, "names": names]
    }

    // Light or dark, and the accent colour (System Settings › Appearance).
    // AppleAccentColor is missing for Multicolour.
    static let accentNames = ["Multicolour", "Graphite", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink"]
    static func appearance() -> [String: Any] {
        // (The standard defaults search the global domain too.)
        let g = UserDefaults.standard
        g.synchronize()
        var dark = (g.string(forKey: "AppleInterfaceStyle") ?? "") == "Dark"
        let readDark = { dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        if Thread.isMainThread { readDark() } else { DispatchQueue.main.sync(execute: readDark) }
        let auto = g.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically")
        // -1 graphite, 0 red … 6 pink; missing: multicolour.
        var index = 0
        if let v = g.object(forKey: "AppleAccentColor") as? NSNumber { index = v.intValue + 2 }
        index = min(max(index, 0), accentNames.count - 1)
        return ["dark": dark, "auto": auto, "mode": auto ? "Auto" : dark ? "Dark" : "Light",
                "accent": accentNames[index], "accentIndex": index, "accents": accentNames.count]
    }

    // MARK: - macOS

    static let codenames: [Int: String] = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
    static func os() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return ["name": "macOS", "version": version, "codename": codenames[v.majorVersion] ?? "",
                "build": sysctlString("kern.osversion") ?? ""]
    }

    // MARK: - everything

    static func read() -> [String: Any] {
        var dsp: [[String: Any]] = []
        if Thread.isMainThread { dsp = displays() } else { DispatchQueue.main.sync { dsp = displays() } }
        let prof = profile()
        let hw = prof.hw
        let history = installHistory()
        let installed = setupDate(history)
        let t = now()

        let chip = (hw["chip_type"] as? String) ?? sysctlString("machdep.cpu.brand_string") ?? ""
        let modelId = (hw["machine_model"] as? String) ?? sysctlString("hw.model") ?? ""
        let machineName = (hw["machine_name"] as? String) ?? "Mac"
        // "MacBook Air (13-inch, M5)": the marketing name where macOS has one,
        // else the name with the built-in screen's size class and the chip.
        var model = marketingName(modelId) ?? ""
        if model.isEmpty {
            var bits: [String] = []
            if let b = dsp.first(where: { $0["type"] as? String == "Builtin" }), let inch = b["inches"] as? Double, machineName.hasPrefix("MacBook") || machineName.hasPrefix("iMac") {
                bits.append("\(Int(inch.rounded(.down)))-inch")
            }
            let short = chip.replacingOccurrences(of: "Apple ", with: "")
            if !short.isEmpty && !short.contains("Intel") { bits.append(short) }
            model = bits.isEmpty ? machineName : "\(machineName) (\(bits.joined(separator: ", ")))"
        }

        // Cores: Apple silicon has two kinds (performance, now "Super" on
        // M5, and efficiency), and no hyper-threading.
        let perf = sysctlInt("hw.perflevel0.physicalcpu"), eff = sysctlInt("hw.perflevel1.physicalcpu")
        let cores = sysctlInt("hw.physicalcpu") ?? 0
        var cpu: [String: Any] = ["name": chip, "cores": cores, "threads": sysctlInt("hw.logicalcpu") ?? cores]
        if let perf = perf, let eff = eff, (sysctlInt("hw.nperflevels") ?? 1) > 1 {
            cpu["perf"] = perf; cpu["eff"] = eff
            cpu["perfName"] = sysctlString("hw.perflevel0.name") ?? "Performance"
            cpu["effName"] = sysctlString("hw.perflevel1.name") ?? "Efficiency"
        }
        if let hz = sysctlInt("hw.cpufrequency_max"), hz > 0 { cpu["mhz"] = hz / 1_000_000 }

        let gpuCores = Int((prof.gpu["sppci_cores"] as? String) ?? "")
        let gpu: [String: Any] = [
            "name": (prof.gpu["sppci_model"] as? String) ?? chip,
            "cores": gpuCores as Any? ?? NSNull(),
            "usage": gpuUsage() as Any? ?? NSNull(),
            "vram": NSNull(), "type": (prof.gpu["sppci_bus"] as? String) == "spdisplays_builtin" ? "Integrated" : "Discrete",
            "driver": chip.hasPrefix("Apple") ? "apple" : ""
        ]

        // The installs in each week since setup, oldest first (the age ring
        // sizes its dots by them).
        var weekly: Any = NSNull()
        if installed > 0 {
            let weeks = min(2600, max(0, (t - installed) / 604800))
            var c = [Int](repeating: 0, count: weeks + 1)
            for h in history { let w = Int((h.date - Double(installed)) / 604800); if w >= 0 && w <= weeks { c[w] += 1 } }
            weekly = c
        }
        let lastSystem = history.last(where: { $0.system }) ?? history.last
        let lastMacOS = history.last(where: { $0.name.hasPrefix("macOS") })

        var out: [String: Any] = [
            "host": SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName,
            "hostname": ProcessInfo.processInfo.hostName,
            "model": model, "machineName": machineName, "modelId": modelId,
            "modelNumber": (hw["model_number"] as? String) ?? "",
            "serial": serial() ?? (hw["serial_number"] as? String) ?? "",
            "firmware": (hw["boot_rom_version"] as? String) ?? "",
            "chip": chip,
            "os": os(), "kernel": sysctlString("kern.osrelease") ?? "",
            "cpu": cpu, "gpu": gpu, "memory": memory(), "disk": storage(),
            "displays": dsp, "display": dsp.first ?? ["width": NSNull(), "height": NSNull(), "hz": NSNull(), "inches": NSNull()],
            "apps": apps(), "homebrew": homebrew() as Any? ?? NSNull(),
            "upgrades": history.count, "systemUpdates": history.filter { $0.system }.count,
            "lastUpgrade": lastSystem.map { Int($0.date) } ?? 0,
            "lastUpgradeName": lastSystem?.name ?? "",
            "lastMacOS": lastMacOS?.name ?? "",
            "installed": installed, "upgradesByWeek": weekly,
            "uptime": uptime() as Any? ?? NSNull(), "now": t,
            "appearance": appearance(), "background": backgroundItems(),
            "battery": battery() as Any? ?? NSNull(),
            "devices": devices(), "thermal": thermal()
        ]
        if out["host"] as? String == "" { out["host"] = "Mac" }
        return out
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
