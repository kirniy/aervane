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
  glass-fallback: "20pt"
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

The first viewport is a 344 pt glass panel. It holds a mark and name, a large rounded temperature with its unit and sensor tag, a heat-coloured trend, then the requested percentage, an Auto/Manual switch, the cooling slider and presets. Settings and preset editing stay inline. **Minimal copy:** state is carried by layout and controls, and words appear only for exceptions (Not applied, Applying…, No reading, External control, errors). Detail lives in tooltips and accessibility values.

**Key characteristics:**
- Native glass. On macOS 26 the glass carries a faint heat tint when the reading is warm or hotter. There is a visual-effect fallback on macOS 14–25.
- Two colour families that never mix: **ice** (mint → glacier cyan → ice white) is cooling power; **heat** (amber → orange → coral) is the measured temperature.
- Event-driven motion only: no idle animation, timers, display links or particles.

*Implementation status (2026-10-23):* Claude's redesign is integrated, compiled with Xcode 26.2, development-signed and installed. Dark appearance, settings persistence, native accessibility value changes, real fan writes, optional timer expiry and three-digit Fahrenheit layout were exercised on the development Mac. Screenshots in `docs/assets` show the installed app. Light mode, 1× displays, system Reduce Motion/Transparency, VoiceOver and physical pointer behavior still need verification; handler tests alone do not establish those results.

## Colors

The palette is dynamic by appearance. `Theme.ink` is the system label colour; `faint` and `hairline` are alpha layers over it.

### Primary
- **Muted mint** (`#8FDBC2`) / **Spruce** (`#126B57`): applied Manual state, selected controls, the airflow mark, primary setup action, and the low end of the cooling ramp.

### Ice (cooling power)
- **Glacier cyan** (`#6BD6F5` dark / `#0A789E` light) through **ice white** (`#DBFAFF` dark / `#0566A8` light): lit slider dots, halo and spark head.
- **Rime** (`#EDFCFF` dark / `#1A75A3` light): frost crystals, the crown flake and the frozen thumb rim.

### Heat (measured temperature)
Cool readings use mint; normal readings stay neutral ink, so colour appears only when it says something. **Warm** is amber, **hot** is orange and **peak** is coral (never alarm red). Heat colour tints the figure (warm and above), the aura, the trend line (pinned to absolute temperatures) and, at hot and above, the menu bar reading. *Heat color* in Settings turns all of it off.

### Named Rules
**The State Must Speak Rule.** Colour never carries state alone. The mode switch position, the measured-speed mark, exception words and accessibility values carry it too.
**The Two Families Rule.** Cooling is never warm and heat is never icy.

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

The fan section has the percentage with an optional exception word and the Auto/Manual switch on one row. Below it is the slider: its hit area extends 16 pt beyond the margins, and a small floor percentage sits under the hardware-minimum tick. Then come presets (one row for up to three, wrapping 2×2, 3+2, 3×2 up to six), the setup action while needed, and a compact error line.

Settings rows put short labels on the left and native controls on the right: Sensor, Units, Menu bar, Spacing, Effects, Heat color, Return to Auto (a 5–120 min slider in 5 min steps when on), Open at login, Low power. A final action row holds Source code (GitHub mark), Edit Presets and Quit.

### Menu bar item
The status item hugs its content: icon and/or reading plus 4 pt (compact, default) or 8 pt (comfortable) per side. The title is digits and a degree sign with no padding characters. Its width reserves "88°" so two-digit readings never shift neighbouring items. The content options are icon + temperature (default), temperature, and icon.

## Elevation & Depth

Depth comes from system glass, tonal fills and light rather than shadow. The panel has the AppKit window shadow. The slider thumb keeps a 1.5 pt black legibility shadow. The heat aura is a soft radial light behind the temperature; it changes only when the heat band does.

### Named Rules
**The Material First Rule.** Let native glass and tonal separation establish depth; light is reserved for meaning (heat, cooling energy).

## Shapes

The panel is 24 pt glass on macOS 26 (20 pt fallback). Soft buttons use a 9 pt radius, or half their height when shorter; the mode switch is a full capsule with an inset pill. The slider thumb is a 6×20 pt white pill.

## Components

### Cooling slider
- **Lattice:** five rows of dots on a 3 pt pitch. Resting dots are 2 pt; lit dots grow to 2.4 pt and cool from mint through cyan to ice white as the value rises (`SliderEnergy`). All bitmaps are rendered once per size, scale, appearance or floor change.
- **Progressive energy:** a white-hot head trails the thumb. Its length, the halo and the overall light grow on one curve, and are stronger while dragging.
- **Frost:** from about 45% upward, rime crystals grow along the lit edges, denser and longer toward the top (`Frost.amount`).
- **Ice crown at 100%:** a pointer or preset reaching full cooling forms a bright rime fringe that spreads back from the thumb, plus a six-armed flake that crystallises around the thumb (about 0.6 s, Expressive only). The thumb gains an icy rim. The formed state is static artwork. Lowering the value melts it (about 0.28 s). Keyboard, VoiceOver and model refreshes show or remove it instantly.
- **Measured speed:** a slim ghost mark shows where the fan actually runs when it differs from the request by at least 3%. It also appears in the tooltip and the accessibility value.
- **Interaction:** pointer, keyboard and accessibility changes preview immediately. Release, or a pause in key presses, commits. A pointer release sends a short light sweep back along the track. The 100% glint and haptic are user-action feedback only.

### Mode switch
- One capsule control holding the Auto and Manual buttons. A pill springs to the active mode: neutral for Auto, mint for applied Manual, sand for a preview that is not applied, absent for an external controller. The buttons keep their own accessibility labels. When Return to Auto is on, Manual's tooltip shows the remaining time.

### Buttons
- The fill lives on the backing layer and cross-fades for hover, selection and press. A press scales to 0.96 (0.985 for wide buttons) and springs back on release.
- Presets are 40 pt with the name above and the effective percentage below.

### Temperature
- The figure rolls up or down when it changes (when effects allow). The aura cross-fades between heat bands and breathes in once when the band rises.

## Motion & Effects

The Effects setting is **Off / Subtle / Expressive** (default Expressive), resolved into an `EffectsProfile`:
- **Off:** no glow, frost, aura, roll, sweep or glint. Continuity transitions remain.
- **Subtle:** reduced light and frost; the crown appears without the formation.
- **Expressive:** everything above.
- **Reduce Motion:** removes all movement (glide, roll, sweep, formation, glint, entrance) and keeps static state such as the ice crown.
- **Reduce Transparency:** halves light and frost and removes the glass tint.

Timing: press 90 ms in, then a spring out. Fills 180 ms. Glide 200 ms. Section swap 260 ms. Formation 620 ms. Melt 280 ms. Easing is strong ease-out `(0.23, 1, 0.32, 1)` or ease-in-out `(0.65, 0, 0.35, 1)`. Nothing loops, and hiding the panel removes every transient animation.

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
- **Don't** describe a preview as applied or imply that zero is available below the firmware floor.
- **Don't** let a heat state imply that manual control is blocked.
