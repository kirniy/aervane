---
name: Aervane
description: A compact native macOS menu-bar instrument for temperature and fan control.
colors:
  accent-light: "#126B57"
  accent-dark: "#8FDBC2"
  caution-light: "#A3630A"
  caution-dark: "#F2BF6B"
  secondary-light: "#5C5C5C"
  secondary-dark: "#ADADAD"
  hairline: "rgba(255,255,255,0.10)"
  ice-mid-light: "#0A789E"
  ice-mid-dark: "#6BD6F5"
  ice-high-light: "#0566A8"
  ice-high-dark: "#DBFAFF"
  rime-light: "#1A75A3"
  rime-dark: "#EDFCFF"
  heat-warm-light: "#996B00"
  heat-warm-dark: "#F5CC6B"
  heat-hot-light: "#B8540A"
  heat-hot-dark: "#FF9E57"
  heat-peak-light: "#BD291F"
  heat-peak-dark: "#FF786B"
typography:
  display:
    fontFamily: "SF Rounded, system-ui, sans-serif"
    fontSize: "52pt"
    fontWeight: 300
  title:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "13pt"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "12pt"
    fontWeight: 500
  label:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "11pt"
    fontWeight: 400
  numeric:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "30pt"
    fontWeight: 500
rounded:
  control: "8pt"
  glass: "24pt"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  lg: "16pt"
  xl: "20pt"
  section: "32pt"
components:
  panel:
    rounded: "{rounded.glass}"
    width: "344pt"
  primary-action:
    backgroundColor: "rgba(143,219,194,0.16)"
    textColor: "{colors.accent-dark}"
    rounded: "{rounded.control}"
    height: "32pt"
  preset:
    backgroundColor: "rgba(255,255,255,0.05)"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    height: "40pt"
  quiet-action:
    textColor: "{colors.accent-dark}"
    rounded: "{rounded.control}"
    height: "28pt"
---

# Design System: Aervane

## Overview

**Creative North Star: "The Native Instrument"**

Aervane is a small, precise macOS instrument: temperature leads, fan control follows, and the panel stays light enough to feel like a menu-bar utility. It is AppKit throughout: system glass, SF type, dynamic colours, cached Core Animation artwork. There is no web-style dashboard vocabulary.

The first viewport is a 344 pt glass panel. It holds a mark and name, a large rounded temperature with its unit and sensor tag, a heat-coloured trend, then the requested percentage, the Auto · Smart · Manual selector, the cooling slider and presets. Settings and preset editing stay inline. **Minimal copy:** state is carried by layout and controls, and words appear only for exceptions (Not applied, Applying…, No reading, External control, errors). Detail lives in tooltips and accessibility values.

**Point of view: warm light behind the glass, frost on it.** Heat glows from behind the reading at the top. The fan's *measured* speed sends a faint cold wash up from the lower edge. The cooling *command* runs as coolant light through a channel cut into the glass, where miniature rotors turn with the fan's actual RPM. Rime grows on its lips from about 45%, and at 100% the whole track freezes over and the ice keeps flowing. There are no literal snowflakes and no decorative glow.

**Key characteristics:**
- Native frosted material. One `NSVisualEffectView` with `.popover` material is masked to the continuous panel-and-pointer outline using public AppKit APIs. It uses the same shape on macOS 14+. This custom shape does not use `NSGlassEffectView` lensing.
- Two colour families that never mix: **ice** (mint → glacier cyan → ice white) is cooling power; **heat** (amber → orange → coral) is the measured temperature.
- Event-driven motion only: no timers, display links, per-frame code or particle systems. The slider answers the hand (grab, speed, release) with finite reactions. Two kinds of motion repeat, both bounded Core Animation loops that run on the compositor only while the slider is on screen (panel shown, Settings closed), enabled and fed fresh telemetry, and only with Effects on and Reduce Motion off: the Channel's miniature rotors, which mirror the real fan's RPM, and the full-cooling ice flow at 100%. Both freeze in place when they stop.
- Keyboard-complete: every core action has a plain key, and text fields keep their own keys.

*Implementation status (2026-10-23):* The target/three-mode checkpoint passes 226 Mac tests with Xcode 26.2 and is installed with Developer ID signing. Both slider styles and the attached pointer are rendered in the installed app. Real fan control, temperature-driven Smart changes, and animated slider updates have been exercised; the user confirmed physical dragging and immediate Smart → Manual takeover. The outer rectangular outline was also confirmed fixed by the user. The subsequent Smart regulation/sensor-display correction is being verified before publication. Real VoiceOver, system Reduce Motion/Transparency, 1× and multiple displays still need broader device verification.

## Colors

The palette is dynamic by appearance. `Theme.ink` is the system label colour; `faint` and `hairline` are alpha layers over it.

### Primary
- **Muted mint** (`#8FDBC2`) / **Spruce** (`#126B57`): applied Manual state, selected controls, the airflow mark, primary setup action, and the low end of the cooling ramp.

### Ice (cooling power)
- **Glacier cyan** (`#6BD6F5` dark / `#0A789E` light) through **ice white** (`#DBFAFF` dark / `#0566A8` light): coolant, thumb core, halo, wake and ripples. On dark glass the coolant stops at 60% of the way from cyan to ice white, so white light and the ice sheet still read on top of it.
- **Rime** (`#EDFCFF` dark / `#1A75A3` light): grains and crystals outside the channel, rim needles and the frozen thumb. Inside the channel, frost and ice are drawn in white over the coolant in both appearances.

### Heat (measured temperature)
Cool readings use mint; normal readings stay neutral ink, so colour appears only when it says something. **Warm** is amber, **hot** is orange and **peak** is coral (never alarm red). Heat colour tints the figure (warm and above), the aura, the trend line (pinned to absolute temperatures) and, at hot and above, the menu bar reading. *Heat color* in Settings turns all of it off.

### Named Rules
**The State Must Speak Rule.** Colour never carries state alone. The mode switch position, the measured-speed mark, exception words and accessibility values carry it too.
**The Two Families Rule.** Cooling is never warm and heat is never icy.
**The Measured Air Rule.** Atmosphere that describes the fan (the cold wash) follows measured speed, never the request. The request lives on the slider.

## Typography

**Display Font:** SF Rounded system design, with the system fallback.
**Body Font:** SF Pro system font.
**Label/Mono Font:** SF Pro with monospaced digits for changing percentages and preset values.

### Hierarchy
- **Display** (light, 52 pt): temperature figure.
- **Numeric** (medium, 30 pt, monospaced digits): requested fan percentage.
- **Title** (semibold, 13 pt): Aervane.
- **Body** (medium, 12 pt): button labels, preset names, settings row labels.
- **Label** (medium, 10–11 pt): exception state, floor mark, sensor tag, preset figures.

### Named Rules
**The Stable Number Rule.** Values that change during adjustment use monospaced digits; temperature uses the larger rounded display face.

## Layout

The panel is 344 pt wide with 16 pt margins. `PanelView.arrange` is the single source for frames and window height, on a 4/8 pt rhythm. The order is: header row, then the temperature block (figure; unit and sensor tag stacked beside it; trend at the right), then one lower section. That section is either the fan controls or the Settings page; they swap in place rather than stacking, so the panel stays compact.

The fan section has the percentage and the 186 pt Auto · Smart · Manual selector on one row, the selector centred on the figure's optical middle with room for 100%. Below it is the slider: its hit area extends 16 pt beyond the margins, and a small floor percentage sits under the hardware-minimum tick. Exception words (No reading, Applying…, Not applied, External control, and Smart's saturation status) sit right-aligned on that floor-label line, never floating beside the figure. Then come presets (one row for up to three, wrapping 2×2, 3+2, 3×2 up to six), the setup action while needed, and a compact error line.

Settings rows put short labels on the left and native controls on the right: Sensor, Units, Menu bar, Spacing, Effects, Slider (Channel / Dot Grid), Heat color, Smart target (a native help button beside the label, a 60–95 °C slider in whole °C or °F, and its value; the help button expands the live curve for that target and a short explanation), Return to Auto (a 5–120 min slider in 5 min steps when on; manual speeds only), Open at login, Low power. A final action row holds Source code (GitHub mark), Edit Presets and Quit. When the screen is too short for the whole page, Settings scroll inside the panel, which never grows past the space below the status item.

### Menu bar item
The status item hugs its content: icon and/or reading plus 4 pt (compact, default) or 8 pt (comfortable) per side. The title is digits and a degree sign with no padding characters. Its width reserves "88°" so two-digit readings never shift neighbouring items. The content options are icon + temperature (default), temperature, and icon.

## Elevation & Depth

Depth comes from system glass, tonal fills and light rather than shadow. The panel has the AppKit window shadow. The slider channel is recessed: shade under its upper lip and a light catch along its lower one. The thumb is the one raised object, with a soft drop shadow (1 pt down, 3 pt blur). The heat aura is a soft radial light behind the temperature; it changes only when the heat band does.

### Named Rules
**The Material First Rule.** Let native glass and tonal separation establish depth; light is reserved for meaning (heat, cooling energy).

## Shapes

The panel has 24 pt continuous corners and an 11 pt rounded pointer. A 4 pt tip gap creates 15 pt of space between the menu bar and the panel body; the preferred screen-edge margin is 20 pt (8 pt when space is constrained). Soft buttons use a 9 pt radius, or half their height when shorter; the mode switch is a full capsule with an inset pill. The Channel slider is a 28 pt glass tube in a 52 pt frame; its knob is a 20×38 pt glass capsule with a 6×20 pt coolant window. The Dot Grid is a 7-row lattice in a recessed tray (9 pt corners) in a 50 pt frame; its handle is a 9×38 pt glass bar.

## Components

### Cooling slider
The **Slider** setting chooses how it is drawn: **Dot Grid** (default) or **Channel**. Both styles are the same control (`PercentSlider`) with one input path and different skins (`ChannelSkin`, `DotGridSkin`). Value, hardware floor, measured mark, previews, commits, haptics, keys and accessibility are identical. Switching style is presentation-only: it never sends anything to the fan, keeps the value and the enabled, stale and focus state, settles every transient, and resumes permitted visible motion without replaying formation. The floor label follows the selected style's geometry.

**Miniature rotors (Channel only).** A small row of rotors sits in the coolant. They turn in proportion to the fan's *actual* RPM from the hardware (`RotorMotion`), never the slider, the Smart target or Smart's request, so they visibly spin up and down with the real fan in Manual and Smart alike. Scale: 1 visual rev/s per 2000 RPM (1/33 of the real fan; 1200 RPM → 0.6 rev/s, 4900 RPM → 2.45 rev/s), capped at 4 rev/s. Literal 1000–4900 RPM would alias at 60/120 Hz; at this scale a five-blade rotor turns at most 24° per 60 Hz frame, under the 36° limit of its 72° symmetry. The scale is the same on Subtle and Expressive (intensity changes only how present they look). Zero RPM, unknown or stale telemetry, Off, Reduce Motion, a disabled control, a hidden panel or open Settings stand them still. Each new sample re-times a shared clock layer's speed with continuous phase; an unchanged sample changes nothing, and stopping freezes each rotor at its current angle. Cost: one cached rotor bitmap, at most a dozen layers, one repeating rotation per rotor. The Dot Grid has no fan graphics.

#### Channel
A thick glass cryo tube with an etched scale and a knob that stands proud of it. The panel gives it a 52 pt frame (`SliderGeometry.frameHeight`).
- **Tube:** a 28 pt glass capsule spanning the content margins, with a soft contact shadow and tinted, cylindrically shaded interior. In front of the coolant sit a crisp rim, a long specular band and a hot spot, a refraction line along the bottom, etched scale marks every 10% (longer at 50%), and the hardware-floor line. Below the floor the coolant is muted, hatched mint: the fan always runs there and the knob cannot reach it. The hit area spills 16 pt into the margins.
- **Coolant:** sits 3 pt inside the glass wall. It cools from mint (floor) through glacier cyan (60%) toward ice (100%) and thickens from 50% to 96% opacity (`SliderEnergy.tone`, `.coolant`), shaded like liquid in a cylinder: a bright meniscus line, a light top and a deep belly. Its rounded end runs on under the knob, and it always shows the requested value immediately.
- **Rotors:** 16 pt five-blade rotors on a 34 pt pitch ride in the coolant (so they show only where it has reached), brighter with energy, turning with the real fan's RPM; faint etched twins wait in the empty glass.
- **Energy:** cold sparks (with four-point glints near the top) crowd toward full cooling, a cold aura glows around the filled glass, and a white-hot head and halo gather at the knob. All of it follows one energy curve, stronger while dragging and with drag speed. The aura has no edge of its own: a fixed 30 pt fade that slides with the knob, starting under it.
- **Knob:** 20×38 pt sculpted glass: off-white body cooling toward the foot, front-lit side shading, a specular crest, a refracted cyan glow at the base, a bevel, grip ridges, and a recessed 6×20 pt window onto the coolant colour. Hover grows it 7%. A grab squashes it (1.24×0.9) and flashes the sparks. Drag speed leans it up to 8° and stretches it up to 35%; it springs upright when the pointer stops. Release springs back with a small overshoot.
- **Hand reactions:** on Expressive, a moving knob leaves a cold wake, a preset or track click shoots light to the target, grabs, releases and preset stops ripple along the tube, and the coolant sloshes against fast moves. Speed has a 40 pt/s dead zone (`SliderMotion`). Every reaction is a finite additive animation; there is no timer.
- **Rime and fog:** from about 45% (`Frost.amount`) dendrites grow inward from both glass walls, grains and needles cling outside, and frost fog clouds the coolant under the upper wall. Lowering by drag melts the rime back behind the knob (550 ms).
- **Total frost at 100%:** the *whole* tube freezes into smooth, milky frosted ice (`IceCover`: coverage applied as opacity, never below 85%, densest at the knob end): a dense translucent body thickest against both glass walls, soft clouds of accumulated frost, a cold shade under the upper wall and a soft sheen, the tube's rim redrawn crisp on top. No cracks, triangulated plates, ferns or needles; outside, only a soft frost halo hugs the glass. **The ice keeps flowing** while the slider is shown (`IceFlow`): soft cold currents with one pulse of light per 104 pt tile drift from the knob toward the floor (4 s per tile), fine bright streaks ride them faster (60 pt per 1.25 s, a parallax layer), and two sparse sets of crystal glints breathe out of phase (2.3 s and 3.1 s) so the ice glitters rather than blinks. The rotors still turn underneath as shapes. Subtle runs every loop 1.8× slower and fainter; Off and Reduce Motion keep the ice still. Any crossing into full cooling the person can see (a drag, click or preset, or Smart gliding to 100% while the panel is open) plays the formation: the front crawls the full length from the knob in growth spurts (`IceCover.crawl`, 1.1 s, starting as a glide lands) while the halo grows and a bar of light rides it, a breath of cold vapor rises, and the light runs back to the knob, which frosts over with a soft rime glow (1.8 s in all; a soft bloom of cold light marks user actions). The flow lives inside the ice, so the front reveals it. Expressive only. Lowering recedes it (700 ms) from what is on screen. Keyboard, VoiceOver, hidden or startup refreshes and unchanged 100% polling show or keep the ice without replaying anything. On Subtle the ice fades in with a lighter bloom.
- **Measured speed:** a slim, pixel-snapped ghost mark inside the tube shows where the fan actually runs when it differs from the request by at least 3%, also in the tooltip and accessibility value.
- **Interaction:** pointer, keyboard and accessibility changes preview immediately; release, or a pause in key presses, commits; nothing commits per frame. A release sends a light sweep back along the coolant and the sparks twinkle. Keys are never animated.
- **Cost:** every bitmap (aura, interior with etched rotors, coolant, rotor, sparks, head, fog, rime, glass, ice, halo, light bar, currents, streaks, glints, vapor, bloom, knob, window gloss, frozen knob) is rendered once per size, scale, appearance or floor change. Interaction only moves, masks, transforms and fades layers. The flow is four repeating compositor animations on cached tiles (scrolling tiles wrap within one period when frozen). Hiding the panel removes every transient and freezes the rotors and the flow.

#### Dot Grid
A tall lattice of glass dots set into a recessed tray, with a slim glass handle. It keeps its dot identity and stays distinct from the Channel: light and crystals on a lattice, not liquid in a tube. The panel gives it a 50 pt frame (`DotGridGeometry.frameHeight`).
- **Lattice and tray:** seven rows of dots on a 4 pt pitch, centred, 16 pt ends (`DotGridGeometry`). The tray is a shallow recess 5 pt around the lattice: shade under its upper lip, a light catch along the lower one, a hairline edge. Unlit dots are 2 pt dimples with a lit lower lip; lit dots are domes with a specular cap that swell to 3 pt (`SliderEnergy.dotSize` × 1.25) and cool from mint through cyan to ice white. Unlit dots show only past the fill, so lit dots never sit on dim ones.
- **Handle:** 9×38 pt sculpted glass bar: white cooling toward the foot, front-lit side shading, a specular streak, a cold glow at the base, three grip ridges and a soft drop shadow. Hover grows it (1.14×1.03) and lifts the resting dots. A grab squashes it (1.5×0.9 → held 1.3×1.06) and flashes the head. Drag speed leans and stretches it; it springs upright when the pointer stops. Release springs back with a small overshoot (stiffness 420, damping 13).
- **Progressive energy:** a white-hot head trails the handle; its length, the halo and the overall light grow on one curve and are stronger while dragging. The dots under the handle bulge like glass under a lens (a 64 pt soft disc of larger, brighter dots that follows the handle; faint at rest, stronger on hover and while held). On Expressive the head sloshes against fast moves, and grabs, releases and preset stops send a ring of glints through the dots; a release sweeps light back toward the floor.
- **Hoarfrost:** from about 45% upward, fine rime grains cling to the lit edges; at most four grains per column edge. Lowering by drag melts it back behind the handle (500 ms).
- **Total frost at 100%:** the whole tray freezes over (`IceCover`, coverage as opacity): a milky glaze fills the recess, thickest against its lips, with soft clouds of accumulated frost, and every dot becomes a white faceted crystal (slightly varied in size and clarity, an inked edge and a shaded facet), so the lattice is visibly transformed while still reading as dots. No cracks, ferns or needles. **The lattice keeps moving** while shown (`IceFlow`): soft waves of light roll through the crystals from the handle toward the start (one band per 84 pt, 2.6 s per band), lighting each crystal from within as they pass, and two sparse sets of crystal glints breathe out of phase (2.1 s and 2.9 s). Subtle is slower and fainter; Off and Reduce Motion keep the crystals still. The same visible crossings as the Channel play the formation: the front crawls from the handle to the start in growth spurts (1.0 s) with a glint riding it, the glint runs back and the handle frosts over with a soft rime glow (1.6 s in all; a bloom of glints marks user actions). Lowering recedes it toward the handle end (600 ms) from what is on screen. On Subtle the crystals fade in with a small bloom.
- **Cost:** tray, dots, lens, head, hoarfrost, crystals, shimmer, glints, bloom, handle and frozen handle are cached bitmaps; 11 root layers; the flow is three repeating compositor animations.

### Smart cooling
- A mode in the main selector, never on unless chosen. It works toward the Smart target. The slider follows Smart's requested speed with a visible 0.85 s eased glide, retargeted by each newer value (immediate with Reduce Motion), and the figure rolls. The ghost mark still shows the measured rotor speed catching up, so a request is never shown as a measurement.
- Taking hold of the slider (pointer or first key) selects Manual at once, with no command, so Smart never moves the fan under the user's hand. A preset, Manual or Auto also leaves Smart.
- Saturation uses the attention tone only when the current controlled temperature exceeds the target and the helper has confirmed the full-speed target. Applying and unconfigured states take precedence; a request alone is not shown as applied cooling.
- When Smart stops on its own (sensor, write, helper or competing-controller fault), the panel's message line explains why and says truthfully whether Auto is pending, confirmed or failed. The note stays until the next mode choice and is separate from transient command errors.
- Policy, constants and lifecycle: `docs/smart-cooling.md`.

### Mode switch
- One capsule holding Auto · Smart · Manual, equal thirds, each a radio button with its own accessibility label. A pill springs to the active mode:
  - Auto: neutral glass.
  - Smart: a cool ice gradient with a hairline rim, in the attention tone when saturated.
  - Manual: mint, or sand for a preview that is not applied.
  - None: absent for an external controller.
- Choosing Smart plays one finite flourish when effects allow: light sweeps across the pill (0.7 s) and a cold bloom breathes once behind it (0.9 s). Nothing animates at rest.
- Smart's tooltip gives its key, target, the current reading and the requested speed. When Return to Auto is on, Manual's tooltip shows the remaining time.

### Buttons
- The fill lives on the backing layer and cross-fades for hover, selection and press. A press scales to 0.96 (0.985 for wide buttons) and springs back on release.
- Presets are 40 pt with the name above and the effective percentage below.

### Temperature
- The figure uses tabular rounded digits, so it, the unit and the sensor tag never shift as digits change. A new reading shows at once; a real change of the same source in the same unit crossfades for 200 ms (`TemperatureMotion`), so only the changed digits visibly fade. No roll, no counting through unmeasured values. A source or unit switch, the first reading, stale ↔ valid, a hidden panel, Effects Off and Reduce Motion change it without motion. The aura cross-fades between heat bands and breathes in once when the band rises.

### Trend
- Pointing at the trend inspects it. A device-pixel hairline and a probe snap to the nearest sample. That sample's exact value (one decimal, in the user's unit, heat-coloured when warm or hotter) appears in a 14 pt band above the plot. Tracking is immediate; the inspector fades in over 120 ms and out over 180 ms. New samples under a still pointer update the readout. Samples carry no timestamps, so no age is claimed. VoiceOver reads the range: "Recent temperature, 64 to 78 °C, now 73".

### Cold air
- A soft radial wash of glacier cyan rises from the panel's lower edge behind the fan controls. Its strength is `Airflow.chill` of the measured fan speed: nearly invisible at firmware idle, full at maximum, absent without a fresh reading. It eases over 0.9 s per sample, so a spinning-up fan reads as one build. Effects Off removes it.

### Preset editor
- Opened from Settings (Edit Presets) or a preset's context menu. Each preset becomes the same soft tile, now editable in place: name, speed, delete. The tile's accent edge shows where typing goes; there are no bezels or spilled focus rings.
- Works on a draft (`PresetDraft`). **Save** (Return) stores it; **Cancel** (Escape) discards it; closing the panel or opening Settings keeps edits. Speeds below the hardware minimum turn the attention colour while typing and are raised to the floor when the field is left. ↑/↓ step a speed by 1 (⇧ by 10) within the hardware range. Names are single-line and at most 20 characters; a blank name shows and saves as "Custom". Tab runs name → speed → next row → actions.
- **Add 64%** names exactly what it stores (the slider's speed) and is the prominent action when no presets remain. At six it is disabled.
- Right-clicking a preset offers **Set to 64%** (store the current speed) and **Edit Presets…**.

### Keyboard
- Arrows (⇧ for 10), Page Up/Down, Home/End adjust the slider. **1–6** apply presets (by key position, so AZERTY and the keypad work). **A** restores Auto, **S** chooses Smart, **M** takes manual control at the shown speed (the selector's order). **⌘,** toggles Settings. Escape cancels the preset editor first, then closes the panel. Shortcuts with ⌘, ⌥ or ⌃ pass through, and text fields never see quick keys. A preset applied by key flashes its fill without movement, and the thumb jumps instead of gliding.

## Motion & Effects

The Effects setting is **Off / Subtle / Expressive** (default Expressive), resolved into an `EffectsProfile`:
- **Off:** the track and thumb only: no glow, frost, ice, aura, roll, sweep, wake, speed reactions, rotor motion or ice flow (the rotors stand still). Continuity transitions (glide, thumb press and release) remain.
- **Subtle:** reduced light and frost, a gentler speed lean (45%), the rotors at the same RPM scale but quieter in appearance, the ice flow about 1.8× slower and fainter, the ice fading in with a light bloom. No wake, ripples, sweep or formation.
- **Expressive:** everything above, at full strength.
- **Reduce Motion:** removes all movement at every level (glide, press shapes, speed reactions, wake, ripples, roll, sweep, formation, glint, bloom, entrance, rotor spin, ice flow) and keeps static state such as the ice.
- **Reduce Transparency:** halves light and frost and removes the glass tint.

Timing: press 90 ms in, then a spring out. Fills 180 ms. Glide 200 ms. Thumb grab 260 ms squash; release spring (stiffness 380, damping 13); speed lean spring (240, 11). Wake 420 ms. Ripple 440 ms (620 ms on release). Percent roll 220 ms. Section swap 260 ms. Freezing front: Channel 1.1 s, Dot Grid 1.0 s, both in growth spurts; whole formation 1.8 s / 1.6 s. Recede (melt) 700 ms / 600 ms; rime melt-back 550 ms / 500 ms. Rotors at RPM / 2000 rev/s (capped at 4). Ice flow: Channel currents 4 s per 104 pt, streaks 1.25 s per 60 pt, glints 2.3 s / 3.1 s; Dot Grid light waves 2.6 s per 84 pt, glints 2.1 s / 2.9 s; Subtle ×1.8. Cold air 900 ms per sample. Trend inspector 120 ms in, 180 ms out. Easing is strong ease-out `(0.23, 1, 0.32, 1)` or ease-in-out `(0.65, 0, 0.35, 1)`. Nothing else loops; hiding the panel removes every transient animation and freezes the rotors and the ice flow in place.

## Do's and Don'ts

### Do:
- **Do** keep temperature first and the direct percentage adjustment immediately available.
- **Do** preserve the hardware minimum and distinguish requested from measured speed.
- **Do** keep presets, editing and settings inline, and persist changes immediately.
- **Do** let layout and controls speak; use words only for exceptions.

### Don't:
- **Don't** add taglines, footers, section labels or explanatory helper text to the panel.
- **Don't** use warm colours for cooling or icy colours for heat.
- **Don't** add idle animation, timers, display links, particles or network-dependent visuals.
- **Don't** draw literal snowflakes, falling snow or add glow for its own sake; frost is grain, crystal and sheet ice on the channel.
- **Don't** describe a preview as applied or imply that zero is available below the firmware floor.
- **Don't** let a heat state imply that manual control is blocked.
