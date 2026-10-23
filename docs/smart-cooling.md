# Smart cooling

Smart is one of three modes in the main selector: **Auto · Smart · Manual** (keys **A**, **S**, **M**). It is never on unless you choose it. Smart regulates the fan around a **target temperature** you choose in Settings → Smart target: 80 °C by default, adjustable 60–95 °C in whole degrees of your unit (°C or °F). The target is a working point, not a trigger for maximum cooling:
- the base curve is 70 % at the target; a small deadband avoids constant adjustments;
- it speeds up as the temperature climbs or rises quickly;
- full speed is reserved for genuine overshoot (5 °C over) or a fast rise projected there;
- it eases off as soon as the temperature falls.

The target is kept while Smart is off, and editing it never turns Smart on.

Smart is a fixed, deterministic rule in plain code (`Sources/ZephyrCore/SmartCooling.swift`). It does not learn and has no randomness. **It cannot guarantee a cap.** A fan can only move so much heat, and under some workloads the temperature passes the target even at full speed. When that happens, the panel says so ("Above 80° · max cooling") and the Smart pill takes the attention tone. Aervane never throttles the CPU or limits power.

## What it follows

- The **hottest CPU core**, read on every poll, whatever the menu bar shows. The menu bar can show the CPU average, the GPU or the warmer of the two; Smart reads its own input.
- The **GPU** when this Mac has readable GPU sensors. `SMCReader.readGPUTemperature()` reports the average of the GPU sensors mapped for the model. Smart uses that average when it is hotter than the hottest CPU core.
- A valid CPU reading is required: plausible values are at least −20 °C and below 130 °C. An absent or implausible GPU is ignored, subject to the grace period below.
- If a GPU that was readable stops reading, its last value is kept for **30 s** (`gpuGrace`), so losing an optional sensor never lowers demand at once. After that, Smart uses the CPU alone.

Readings are taken every 2 s while Smart is on and the panel is closed (1 s while it is open), overriding Low power. There is no artificial cooling-down wait. Measurement filtering, trend estimation and sensor freshness still account for elapsed time.

## The policy (`SmartCoolingPolicy.standard`, target X)

**Curve.** Speed (% of the fan's maximum) by distance from the target. Points are relative to X, linear between them:

| Temperature | Speed |
| --- | --- |
| X − 18 °C or cooler | 0 % (shown and run as the hardware floor, e.g. 21 % on the M4 Mac mini) |
| X − 9 °C | 38 % |
| X − 4 °C | 57 % |
| **X (the target)** | **70 %** |
| X + 3 °C | 88 % |
| X + 5 °C or warmer | 100 % |

For the 80 °C default: 62 °C → floor, 71 °C → 38 %, 76 °C → 57 %, 80 °C → 70 %, 83 °C → 88 %, 85 °C → 100 %. For a 73 °C target: 55 °C → floor, 73 °C → 70 %, 78 °C → 100 %. Changing the target moves the whole curve, the graph in Settings and the explanation.

**Why these numbers.**
- **70 % at the target** leaves room to respond in both directions. It is a chosen working point, not a calibrated prediction that every model or workload can hold the target at that speed.
- **Below the target** the gain is gentle, about 3–4 points per °C. Light work stays quiet, and noise near the target moves the fan only a little.
- **Above the target** the gain doubles to 6 points per °C, so an excursion is pushed back firmly, with full speed at 5 °C over.
- **The 1.5 °C deadband** keeps the desired speed at a settled target inside 70–79 %. The four-point command threshold can leave an applied target a few points outside that band; it cannot pin the fan at 100 %.

An earlier draft ran full speed 3 °C *before* the target and treated any reading at the target as full speed. That made "reaching the target" mean "maximum cooling", which is not what a working target means. It is replaced.

**Constants:**

| Constant | Value | Meaning |
| --- | --- | --- |
| `smoothingTimeConstant` | 2 s | A short measurement filter against sensor noise. Its weighting uses the elapsed time between samples; it is not a waiting period. Differently timed samples of a changing signal give similar, not identical, results. |
| Spike rejection | previous reading / median of 3 | A warmer reading counts only as far as the previous reading agrees, so one high spike cannot speed the fan up. A cooler reading counts as the median of the last three, so one low outlier cannot slow it. A genuine rise is followed one reading later, and the trend projection covers that lag. |
| `trendTimeConstant` | 6 s | Smoothing of the rising-trend estimate (°C/s). |
| `lookahead` / `maximumAnticipation` | 8 s / 5 °C | A rising trend is projected ahead, by at most 5 °C. A fast approach to the target can therefore reach full speed before the target. Falling trends are never projected. |
| `immediateOvershoot` / `confirmOvershoot` | X + 5 °C / X + 3 °C | A reading at X + 5 °C or more, with the previous reading at X + 3 °C or more, is full speed at once. This is the curve's own value there; it only skips the filter's lag. One isolated spike is not confirmed. A first reading needs no confirmation. |
| `hysteresis` | 1.5 °C | The thermal deadband (below). |
| `commandStep` | 4 points | Smallest change worth a fan command. Reaching full speed or the hardware floor is always allowed. |
| `resetGap` | 30 s | After a longer gap between samples (sleep, a stalled poll), the history is discarded and the next reading's band decides. |
| `gpuGrace` | 30 s | A GPU that stops reading keeps its last value this long, so losing an optional sensor never lowers demand at once. This is sensor plumbing, not a cooling delay. |

**The rule: a band set by temperature alone.** For each new valid reading, let T be the smoothed temperature plus the bounded rising projection. The requested speed always lies between:
- **low** = curve(T): never less cooling than the temperature calls for;
- **high** = curve(T + 1.5 °C): never more than a slightly warmer reading would call for.

A warmer reading pushes the speed up to *low* at once. A cooler reading that leaves the band pulls it down to *high* at once. A reading inside the band changes nothing, so noise near a steady temperature cannot make the fan hunt. There is no separate "over the target" flag that overrides the curve: full speed comes from the curve itself, or a confirmed large overshoot.

Going down, there is **no hold, no timer, no per-second rate and no per-reading step**. The speed falls as soon as the measured temperature has fallen through the deadband. The only lag is the short measurement filter and spike rejection. A steady temperature keeps a steady speed indefinitely.

**Mode entry, target changes, gaps.** These are resolved by the same band on the next valid reading. Choosing Smart seeds from the fan's present speed: the speed in flight, the owned target, or the measured speed. A seed inside the band is kept; one outside moves to the band's edge at once. Choosing Smart at 100 % while sitting at the target therefore drops to at most 79 % on the first reading. Lowering the target raises the speed on the next reading; raising it may lower the request straight to the new curve. Nothing counts down afterwards: repeated identical readings send nothing. The fan's own inertia, and the slider's eased glide, make changes look smooth; there are no policy ramps for appearance.

**Saturation** ("Above X° · max cooling") is shown only when all of these hold:
- Smart is requesting full speed;
- the helper has confirmed a 100 % target and Aervane owns the fan;
- the current measurement (not the filtered value) is above the target;
- the figure shown is visibly above the target shown, in the user's unit, so a figure equal to the target never says "Above".

A full-speed request below the target, from anticipated rising heat or a recently hotter filtered measurement, is not saturation. The Smart button's tooltip says it is "in response to recent heat". The request (100 %) is distinct from the rotor: the slider shows the request, and the ghost mark shows the measured speed spooling up.

**Timestamps.** Smart uses the monotonic uptime clock. A repeated or out-of-order timestamp does not advance the measurement filter or ordinary command decision; only a confirmed large overshoot can change the command on one. Sensor-source metadata can still update.

## What the panel shows while Smart runs

While Smart is selected, the panel's figure, its heat colour, the glass tint and the trend chart show **the measurement Smart regulates**, so the figure and Smart's behaviour can be compared directly. The tag beside the figure names it:
- **CPU PEAK**: the hottest CPU core;
- **GPU**: the GPU average, when it is hotter;
- **GPU HELD**: the GPU's last valid average, within the 30 s grace after the sensor stopped reading.

If Smart has no fresh measurement (none yet, more than 12 s old, or no valid CPU reading), the figure shows "—". It never falls back to an average.

Smart's chart has its own history, which starts when Smart is chosen. Auto and Manual return to the selected sensor, tagged CPU AVG, GPU AVG, or WARMER (the warmer of the two averages), with that sensor's own history, so the two series never mix. **The menu bar shares the panel’s source**: Smart’s controlling sensor in Smart, and the selected sensor in Auto or Manual.

The reported old panel could therefore show “68 MAX” while Smart saw a much hotter CPU core. The old MAX tag described the warmer average, not the hottest core. The corrected Smart panel shows the controlling reading directly; Auto/Manual now use explicit average-source tags.

## The slider in Smart

The main slider shows Smart's requested speed and moves when it changes. The thumb, coolant and effects glide over 0.85 s, eased, and each newer value retargets the same animations from where they are on screen (no queueing). The figure rolls. With Reduce Motion the slider jumps. Hiding the panel settles animations. Decorative motion follows the selected effects and system accessibility preferences. Both slider styles, Channel and Dot Grid, follow it.

Taking hold of the slider (pointer down, or the first arrow/VoiceOver change) selects **Manual** immediately and sends nothing until your speed is committed. Smart cannot move the fan, or the thumb, under your hand.

## Mode precedence and lifecycle

`FanCommandCoordinator` (ZephyrCore) is the reducer `AppModel` uses for every fan command. Its mode changes and lifecycle behavior are covered by deterministic tests.

- **Commands.** Every command is a ticket with an identity and an origin: user, Smart (with the session's epoch), system, or Smart-stop. Replies are matched by identity. A reply that is not for the command in flight, such as one from a replaced connection, changes nothing.
- **User choices win.**
  - A preset or Manual ends Smart at once. The user's speed is queued behind anything in flight and replaces anything queued.
  - Taking hold of the slider ends Smart at once with no command (`userBeganAdjusting`); the committed speed follows on release.
  - Auto also ends Smart; it is sent when Aervane owns the fan or a command in flight may be about to take it.
  - Smart only sends with an idle queue, so it can never overtake or replace a queued user command, including a queued Auto.
- **Target changes.** A new target never changes a command's identity or epoch. Smart sends only with an idle queue, so a write in flight completes, and the next reading applies the new target. A late reply cannot override a newer intent.
- **Smart sessions.** Turning Smart on starts a new epoch. A reply or failure from an earlier session never counts as the current one's.
- **Return to Auto.** The timer is for manual speeds only. It starts only when a user's speed is applied while Smart is off. Smart's writes, and user replies that arrive after Smart was turned on, never start or renew it.
- **Leaving Smart** with Auto returns the fan to firmware Auto; with Manual, a preset or a slider grab, the user's speed (or the current one) stays.
- **Sleep.** Smart stays on but is suspended: it sends nothing and forgets its history, and Auto follows anything in flight. Telemetry begun before sleep, or during it, is ignored. Smart resumes only from a reading begun after wake.
- **Telemetry generation.** Turning Smart on or off, sleep, wake and reconnection all bump a generation, so a read begun earlier (for example a CPU-only read from before Smart was on) never drives Smart.
- **Faults.** A failed Smart write, a lease the helper ended, no valid CPU temperature, a helper disconnect, or another fan controller running each stop Smart and keep it off. It never resumes on its own after a failure. Smart asks for Auto when Aervane might still hold the fan; the helper has already rolled back a failed write.
- **Startup.** The Smart preference and target persist. Manual hardware control is not restored automatically at launch. If Smart was on at quit, it resumes after launch once the helper is ready and a fresh reading arrives, starting from the measured speed. A fault switches the persisted mode away from Smart.
- **Quit.** The fan returns to Auto as before. The Smart setting is unchanged.

**The stop notice.** It says what happened and, separately, what is known about the fan:
- "Returning the fan to Auto…" while Auto is pending
- "The fan is on Auto." only after the helper's reply or a readback confirms it
- "Waiting to confirm the fan is on Auto." when no command was possible
- "Could not return the fan to Auto: …" if restoring failed

The notice is kept apart from transient errors, so a later successful command does not erase it. It clears with the next mode choice. After a relaunch, the reason is shown without any claim about the fan.

## Safety boundaries (unchanged)

Smart adds no new path to the hardware. Every command goes through the same serial queue, authenticated XPC helper, write transaction, lease, heartbeat, stale-data validation, rollback and recovery journal as a manual speed. The helper ABI and write protocol are unchanged. High temperature never blocks manual control, and Smart never overrides a manual choice.

## Tests

- `Tests/ZephyrCoreTests/SmartCoolingTests.swift` covers:
  - target validation and °C/°F round trips at 60–95 °C
  - the curve: 70 % at the target, steeper above it, full speed at X + 5 °C, and different targets shifting it
  - the reported case: 79.5 °C over a 73 °C target saturates, while 73 °C asks for 70 %
  - steady noisy readings at the target staying moderate and stable
  - cooling from 100 % through the target with no wait or gate
  - a seed of 100 % at the target dropping at once, then nothing more
  - rapid rise anticipated; confirmed overshoot reaching 100 %; isolated high and low spikes rejected
  - target changes while active; deadband crossing
  - floor and boundary targets; invalid and duplicate samples; gaps
  - saturation needing both measured overshoot and full speed
  - which source was used (including a held GPU value); GPU dropout; determinism
- `Tests/ZephyrCoreTests/FanCommandCoordinatorTests.swift` covers:
  - precedence and identity: Manual or Auto during a Smart write, rapid toggles, late replies
  - entry at a high manual speed; raising the target while active
  - a target change during an in-flight Smart write; target edits while off; a slider grab
  - stop notices, sleep/wake, telemetry generations and saturation
- `Tests/InterfaceTests/PanelInteractionTests.swift` covers the panel readout:
  - Smart shows its own measurement, not the selected average (the reported case)
  - missing, stale or old Smart data shows as unavailable
  - GPU and held-GPU tags; °F
  - "Above" consistent with the shown rounding in °C and °F
  - the anticipatory full-speed tooltip
- `Tests/InterfaceTests` (macOS only) covers the selector, the slider's external glide, and the curve's spoken summary and explanation text.

The pure tests run on Linux and macOS. The integrated regulation checkpoint passed **230 tests on the Mac** on 2026-10-23, including AppKit tests.

## Observed on the development Mac

The signed 0.3.0 regulation checkpoint ran Smart with a target of **86°C** on the M4 Mac mini. A 13-sample independent read-only trace over 36 seconds recorded hottest CPU readings of **83.6–86.4°C** while commanded speed fell **80 → 76 → 71%**. Hardware targets read 3920, 3724 and 3479 RPM respectively; measured speed followed as the rotor decelerated. The native Smart slider visibly moved with these updates. This verifies that the corrected controller does not remain at full speed around that working target; it is one short trace on one machine, not a thermal guarantee.

Auto from Smart read mode0 and target1000 RPM. A slider adjustment from Smart to76% selected Manual immediately and read mode1, target3724 and actual3725 RPM. Celsius/Fahrenheit target conversion and a three-digit CPU PEAK header were rendered on the installed app. Physical pointer dragging and immediate Smart-to-Manual takeover were separately confirmed by the user; the UI automation tool did not perform that physical drag.

## Adjust the goal where you see the temperature

While Smart is active, the trend includes a dashed target line and a temperature handle. Drag either vertically; release to save. The mapping remains fixed during the gesture, even as new readings arrive. Closing the panel cancels an unfinished adjustment. Settings stays synchronized.

`[` and `]` adjust the goal by one degree in the selected unit; shifted brackets adjust by five. Accessibility clients can read, set, increment and decrement the numeric target. Editing the target never enables Smart on its own. Hold ⌘ in the main panel to reveal the available shortcuts.

The menu-bar number and panel number use the same source. In Smart, both show Smart’s controlling temperature (CPU peak, or a hotter available GPU). Auto and Manual restore the chosen display sensor. The source is also named in the menu-bar tooltip and accessibility value.
