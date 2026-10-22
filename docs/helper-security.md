# Helper security and installation

Aervane keeps AppleSMC writes in a separate LaunchDaemon. The application connects to the daemon over the Mach service `dev.kirniy.aervane.helper`; the daemon requires the caller's code-signing requirement to match `identifier "dev.kirniy.aervane"` before accepting an XPC connection. The helper exposes only snapshot, percentage, automatic-restore, and heartbeat methods.

The app registers `dev.kirniy.aervane.helper.plist` with `SMAppService.daemon(plistName:)` on macOS 13 and newer. macOS requires a notarized containing app for a production LaunchDaemon; a locally ad-hoc or development-signed build can compile and run the helper, but should report registration failure instead of attempting to copy files into `/Library/LaunchDaemons`.

The helper writes only firmware-reported `F0Mn`…`F0Mx` percentages through the CSMC bridge. A request is rejected outside 0–100%, on stale or unavailable temperature data, and when the heartbeat lease expires. Any read/write failure triggers automatic control. A `0%` request means the lowest firmware-permitted target; it does not claim that the fan can stop.
