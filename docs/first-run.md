# First run

Aervane opens its menu-bar panel once after a new installation. The temperature is live immediately; the small dot lattice shows the fan’s measured percentage.

- **Control the fan** opens the normal controls. Before setup, the slider and presets are previews. Choose **Set up fan control** (or **Set up & apply …%**) when ready. macOS may require approval in Login Items and a password.
- **Temperature only** keeps just the temperature and trend. No helper is needed to read temperature. Switching to this mode from active control first returns the fan to macOS; a failed restoration keeps the controls visible.

The setup card shows **Connected** only after the signed helper answers. Its percentage is the measured fan speed. The introduction never changes speed on its own.

You can dismiss the panel at any stage. Pending approval is remembered; a failed setup can be retried. Existing installations are not forced through the introduction when updating.

In Settings, **Fan control** brings the controls back, and **Welcome** reopens the introduction. These choices are stored locally. If fan telemetry is unavailable, Aervane keeps working as a thermometer and disables fan setup. This fallback is tested with simulated failures; compatibility with additional Mac models remains unverified.
