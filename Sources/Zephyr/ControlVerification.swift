import AppKit
import ServiceManagement
import SMC
import ZephyrCore

/// Explicit developer verification command. No UI, no automatic invocation.
/// Exercises the installed signed XPC path, including a short maximum-cooling
/// command and confirmed Auto restoration. Run only with permission to test.
///
/// Every stage is cross-checked with an unprivileged AppleSMC read of every
/// fan from this process, independent of the helper's own readback.
func verifyFanControl() -> Never {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
        fputs("Quit Macs Fan Control before running the control verification.\n", stderr); exit(1)
    }
    let fans = FanInventoryReader(smc: SMCBridge(), model: SMCBridge.model, platform: SMCBridge.platform)
    do {
        let inventory = try fans.read()
        guard !inventory.fans.isEmpty else { fputs("This Mac reports no fans.\n", stderr); exit(1) }
        guard inventory.control.isSupported else {
            fputs("\(inventory.control.message ?? "Fan control is unavailable on this Mac.")\n", stderr); exit(1)
        }
        guard inventory.fans.allSatisfy(\.automatic) else {
            fputs("Restore Auto before running the control verification.\n", stderr); exit(1)
        }
        guard try HelperInstaller().enable() == .enabled else {
            fputs("Approve Aervane in Login Items before running this test.\n", stderr); exit(1)
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }

    let client = HelperClient()
    func registers() -> String {
        do {
            return try fans.read().fans.map { fan in
                "F\(fan.index) \(fan.mode.rawValue) Tg=\(fan.targetRPM.map { String(Int($0.rounded())) } ?? "-") Ac=\(Int(fan.currentRPM.rounded())) Mx=\(Int(fan.maximumRPM.rounded()))"
            }.joined(separator: ", ")
        } catch { return "independent read failed: \(error.localizedDescription)" }
    }
    func report(_ stage: String, _ value: FanSnapshot) {
        let target = value.targetPercent.map { String(format: "%.2f%%", $0) } ?? "Auto"
        print("\(stage): helper mode=\(value.automatic ? "Auto" : "Manual") target=\(target) actual=\(String(format: "%.1f", value.currentRPM / value.maximumRPM * 100))% hottest=\(String(format: "%.1f", value.temperatureCelsius))°C | independent \(registers())")
        fflush(stdout)
    }
    func fail(_ message: String) -> Never {
        fputs("Verification failed: \(message)\nAfter failure: \(registers())\n", stderr)
        client.invalidate() // The helper restores any owned lease on disconnect.
        // Give the helper's disconnect restore a moment, then show the result.
        Thread.sleep(forTimeInterval: 2)
        fputs("Two seconds later: \(registers())\n", stderr)
        exit(1)
    }
    // snapshot + set + 8 s hold + restore, each bounded by its own deadline.
    let overall = FanSafety.statusReplyTimeout + 2 * FanSafety.commandReplyTimeout + 8 + 5
    DispatchQueue.main.asyncAfter(deadline: .now() + overall) { fail("overall deadline of \(Int(overall)) s passed") }
    client.snapshot { result in DispatchQueue.main.async {
        switch result {
        case .failure(let error): fail(error.localizedDescription)
        case .success(let before):
            guard before.automatic else { fail("helper reports manual mode before the test") }
            report("Before", before)
            client.set(percent: 100) { result in DispatchQueue.main.async {
                switch result {
                case .failure(let error): fail(error.localizedDescription)
                case .success(let applied):
                    report("Applied", applied)
                    guard let now = try? fans.read(), !now.fans.isEmpty, now.fans.allSatisfy({ fan in
                        fan.mode == .manual && fan.targetRPM.map { abs($0 - fan.maximumRPM) <= FanWriteTransaction.rpmTolerance } == true
                    }) else {
                        fail("independent readback does not show every fan at manual maximum")
                    }
                    // Watch the fan respond while the lease is held. The
                    // helper renews on commands; send heartbeats meanwhile.
                    for second in 1...8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(second)) {
                            print("  +\(second)s \(registers())"); fflush(stdout)
                            if second % 4 == 0 { client.heartbeat { if let error = $0 { DispatchQueue.main.async { fail("heartbeat: \(error.localizedDescription)") } } } }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
                        client.automatic { result in DispatchQueue.main.async {
                            switch result {
                            case .failure(let error): fail(error.localizedDescription)
                            case .success(let restored):
                                guard restored.automatic, (try? fans.read().fans.allSatisfy(\.automatic)) == true else {
                                    fail("Auto did not verify independently")
                                }
                                report("Restored", restored); client.invalidate(); exit(0)
                            }
                        } }
                    }
                }
            } }
        }
    } }
    RunLoop.main.run()
    fail("run loop ended")
}
