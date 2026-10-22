import AppKit
import ServiceManagement
import SMC
import ZephyrCore

/// Explicit developer verification command. No UI, no automatic invocation.
/// Exercises the installed signed XPC path, including a short maximum-cooling
/// command and confirmed Auto restoration. Run only with permission to test.
func verifyFanControl() -> Never {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
        fputs("Quit Macs Fan Control before running the control verification.\n", stderr); exit(1)
    }
    do {
        guard try SMCReader().readFan().automatic else {
            fputs("Restore Auto before running the control verification.\n", stderr); exit(1)
        }
        guard try HelperInstaller().enable() == .enabled else {
            fputs("Approve Aervane in Login Items before running this test.\n", stderr); exit(1)
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }

    let client = HelperClient()
    func report(_ stage: String, _ value: FanSnapshot) {
        let target = value.targetPercent.map { String(format: "%.2f%%", $0) } ?? "Auto"
        print("\(stage): mode=\(value.automatic ? "Auto" : "Manual") target=\(target) actual=\(String(format: "%.1f", value.currentRPM / value.maximumRPM * 100))% hottest=\(String(format: "%.1f", value.temperatureCelsius))°C")
        fflush(stdout)
    }
    func fail(_ error: Error) -> Never {
        fputs("Verification failed: \(error.localizedDescription)\n", stderr)
        client.invalidate() // The helper restores any owned lease on disconnect.
        exit(1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fail(FanControlError.unavailable) }
    client.snapshot { result in DispatchQueue.main.async {
        switch result {
        case .failure(let error): fail(error)
        case .success(let before):
            guard before.automatic else { fail(FanControlError.unavailable) }
            report("Before", before)
            client.set(percent: 100) { result in DispatchQueue.main.async {
                switch result {
                case .failure(let error): fail(error)
                case .success(let applied):
                    report("Applied", applied)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        client.automatic { result in DispatchQueue.main.async {
                            switch result {
                            case .failure(let error): fail(error)
                            case .success(let restored):
                                guard restored.automatic else { fail(FanControlError.unavailable) }
                                report("Restored", restored); client.invalidate(); exit(0)
                            }
                        } }
                    }
                }
            } }
        }
    } }
    RunLoop.main.run()
    fail(FanControlError.unavailable)
}
