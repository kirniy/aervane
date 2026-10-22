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

**Point of view: warm light behind the glass, frost on it.** Heat glows from behind the reading at the top. The fan's *measured* speed sends a faint cold wash up from the lower edge. The cooling *command* runs as coolant light through a channel cut into the glass. Rime grows on its lips from about 45%, and at 100% the top of the channel freezes into a sheet of ice. There are no literal snowflakes and no decorative glow.

**Key characteristics:**
- Native glass. On macOS 26 the glass carries a faint heat tint when the reading is warm or hotter. There is a visual-effect fallback on macOS 14–25.
- Two colour families that never mix: **ice** (mint → glacier cyan → ice white) is cooling power; **heat** (amber → orange → coral) is the measured temperature.
- Event-driven motion only: no idle animation, timers, display links or particles. The slider answers the hand (grab, speed, release) with finite reactions.
- Keyboard-complete: every core action has a plain key, and text fields keep their own keys.

*Implementation status (2026-10-23):* Both slider styles compile with Xcode 26.2 and all 153 macOS tests pass. The channel has been rendered and exercised in the installed app with real 100% and 76% control. Switching styles is covered by regression tests for preserving value, hardware floor, measured speed, enabled/stale state and effects without preview or commit callbacks. The native window’s outer rectangular outline is fixed and confirmed by the user. Physical pointer dragging, real VoiceOver, system Reduce Motion/Transparency, light appearance and 1× displays still need broader device verification; handler tests do not establish those results.

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

The fan section has the percentage with an optional exception word and the Auto/Manual switch on one row. Below it is the slider: its hit area extends 16 pt beyond the margins, and a small floor percentage sits under the hardware-minimum tick. Then come presets (one row for up to three, wrapping 2×2, 3+2, 3×2 up to six), the setup action while needed, and a compact error line.

Settings rows put short labels on the left and native controls on the right: Sensor, Units, Menu bar, Spacing, Effects, Slider (Channel / Dot Grid), Heat color, Return to Auto (a 5–120 min slider in 5 min steps when on), Open at login, Low power. A final action row holds Source code (GitHub mark), Edit Presets and Quit.

### Menu bar item
The status item hugs its content: icon and/or reading plus 4 pt (compact, default) or 8 pt (comfortable) per side. The title is digits and a degree sign with no padding characters. Its width reserves "88°" so two-digit readings never shift neighbouring items. The content options are icon + temperature (default), temperature, and icon.

## Elevation & Depth

Depth comes from system glass, tonal fills and light rather than shadow. The panel has the AppKit window shadow. The slider channel is recessed: shade under its upper lip and a light catch along its lower one. The thumb is the one raised object, with a soft drop shadow (1 pt down, 3 pt blur). The heat aura is a soft radial light behind the temperature; it changes only when the heat band does.

### Named Rules
**The Material First Rule.** Let native glass and tonal separation establish depth; light is reserved for meaning (heat, cooling energy).

## Shapes

The panel is 24 pt glass on macOS 26 (20 pt fallback). Soft buttons use a 9 pt radius, or half their height when shorter; the mode switch is a full capsule with an inset pill. The slider channel is a 12 pt capsule. The thumb is a 12×24 pt glass puck with a 4×14 pt coolant core. In the Dot Grid style the thumb is a 6×20 pt white pill.

## Components

### Cooling slider
The **Slider** setting chooses how it is drawn: **Channel** (default) or **Dot Grid** (the original lattice). Both styles are the same control (`PercentSlider`) with one input path and different skins (`ChannelSkin`, `DotGridSkin`). Value, hardware floor, measured mark, previews, commits, haptics, keys and accessibility are identical. Switching style is presentation-only: it never sends anything to the fan, keeps the value and the enabled, stale and focus state, settles every transient, and shows formed ice statically. The floor label follows the selected style's geometry.

#### Channel
- **Channel:** a 12 pt capsule cut into the glass, spanning the content margins, with an inner shadow under the upper lip and a light catch below the lower one. The hit area spills 16 pt into the margins. Below the hardware minimum the channel is filled with muted, hatched mint: the fan always runs there and the thumb cannot reach it. A hairline tick under the coolant marks the floor.
- **Coolant:** the fill up to the thumb. It cools from mint (floor) through glacier cyan (60%) toward ice (100%) and thickens from 50% to 96% opacity (`SliderEnergy.tone`, `.coolant`). It is shaded like light in a glass tube: a top highlight, a gloss line and a darker base. The coolant and the thumb always show the requested value immediately.
- **Energy:** streamlines run through the coolant. They get longer, denser and brighter with speed, and a white-hot head and halo gather behind the thumb. All of it scales on one energy curve, stronger while dragging and stronger again with drag speed.
- **Thumb:** a sculpted glass puck: off-white body cooling toward its foot, specular crest, refracted cyan glow at the base, bevel and dark hairline rim. A recessed slot holds a core in the current coolant colour (kept saturated on dark). Hover grows it 8%. A grab squashes it (1.26×0.88) into its held shape. Drag speed leans it up to 8° into the travel and stretches it up to 35%, and it springs upright when the pointer stops. Release springs back with a small overshoot.
- **Hand reactions (Expressive):** a moving thumb leaves a cold wake that retracts into it. A preset or track click shoots light to the target. Grabs, releases and preset detents send a ripple along the channel. The coolant sloshes against fast motion. Speed has a 40 pt/s dead zone, so slow, precise adjustment stays perfectly still (`SliderMotion`). Each reaction is an additive animation that decays on its own; there is no timer.
- **Rime:** from about 45% (`Frost.amount`), grains and small dendrites grow inward from both lips, and sparse rime grains cling outside, thicker toward the top. Lowering the value by drag melts the rime back behind the thumb (500 ms) instead of cutting it off.
- **Ice sheet at 100%:** above 70% (`Frost.crystal`) the channel holds faceted plates of varied clarity with bevelled fractures, long cracks, trapped bubbles and a specular band. Sparse rim needles grow out of both lips; most are short, a few are prominent. When a pointer or preset reaches full cooling, a freezing front runs back from the thumb to 70% while the rim crystals grow and a glint rides the front (620 ms). The loose rime consolidates (dims) into the sheet. The glint then returns to the thumb, which frosts over (rime rim, needles, frosted cap) with a burst of needles along the channel (1.25 s in all, Expressive only). The formed state is static artwork. Lowering melts it (420 ms) from wherever the front is: plates fade and crystals draw back into the lips, so a drag that touches 100% and leaves never snaps to a full sheet. Keyboard, VoiceOver and model refreshes show or remove it instantly. On Subtle the sheet fades in and a lighter burst plays.
- **Measured speed:** a slim, pixel-snapped ghost mark shows where the fan actually runs when it differs from the request by at least 3%. It also appears in the tooltip and the accessibility value.
- **Interaction:** pointer, keyboard and accessibility changes preview immediately. Release, or a pause in key presses, commits; nothing commits per frame. A pointer release sends a light sweep back along the coolant. Keys are never animated: no glide, wake, ripple or formation. The 100% haptic, burst and glint are user-action feedback only.
- **Cost:** every bitmap (channel, coolant, streamlines, head, rime, sheet, rim crystals, glint, burst, thumb, frozen thumb) is rendered once per size, scale, appearance or floor change. Interaction only moves, masks, transforms and fades layers. Hiding the panel removes every transient.

#### Dot Grid
The pre-channel slider, restored unchanged as a skin.
- **Lattice:** five rows of dots on a 3 pt pitch. Resting dots are 2 pt; lit dots grow to 2.4 pt (`SliderEnergy.dotSize`) and cool from mint through cyan to ice white as the value rises. The thumb is a slim 6×20 pt white pill with a 1.5 pt legibility shadow.
- **Progressive energy:** a white-hot head trails the thumb. Its length, the halo and the overall light grow on one curve, and are stronger while dragging. Hover and drag widen the pill (1.17× and 1.34×) and lift the resting dots.
- **Hoarfrost:** from about 45% upward, fine rime grains cling to the lit edges, with a few short needles near the top. There are at most four grains per column edge.
- **Crystal crown at 100%:** above 70% each lit dot becomes a faceted diamond touching its neighbours, with a hairline rim on both edges. When a pointer or preset reaches full cooling, the pill's rim freezes and a front with one glint runs back to 70% (0.62 s, Expressive only). Lowering melts it (0.28 s) from wherever the front is. On Subtle a small bloom replaces the formation.
- It keeps the release sweep. It has no drag-speed lean, wake or ripples; those belong to the Channel.

### Mode switch
- One capsule control holding the Auto and Manual buttons. A pill springs to the active mode: neutral for Auto, mint for applied Manual, sand for a preview that is not applied, absent for an external controller. The buttons keep their own accessibility labels. When Return to Auto is on, Manual's tooltip shows the remaining time.

### Buttons
- The fill lives on the backing layer and cross-fades for hover, selection and press. A press scales to 0.96 (0.985 for wide buttons) and springs back on release.
- Presets are 40 pt with the name above and the effective percentage below.

### Temperature
- The figure rolls up or down when it changes (when effects allow). The aura cross-fades between heat bands and breathes in once when the band rises.

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
- Arrows (⇧ for 10), Page Up/Down, Home/End adjust the slider. **1–6** apply presets (by key position, so AZERTY and the keypad work). **A** restores Auto. **M** takes manual control at the shown speed. **⌘,** toggles Settings. Escape cancels the preset editor first, then closes the panel. Shortcuts with ⌘, ⌥ or ⌃ pass through, and text fields never see quick keys. A preset applied by key flashes its fill without movement, and the thumb jumps instead of gliding.

## Motion & Effects

The Effects setting is **Off / Subtle / Expressive** (default Expressive), resolved into an `EffectsProfile`:
- **Off:** the channel, coolant and glass thumb only: no streamlines, glow, frost, ice, aura, roll, sweep, wake or speed reactions. Continuity transitions (glide, thumb press and release) remain.
- **Subtle:** reduced light and frost, a gentler speed lean (45%), the ice sheet fading in with a light burst. No wake, ripples, sweep or formation.
- **Expressive:** everything above, at full strength.
- **Reduce Motion:** removes all movement at every level (glide, press shapes, speed reactions, wake, ripples, roll, sweep, formation, glint, burst, entrance) and keeps static state such as the ice sheet.
- **Reduce Transparency:** halves light and frost and removes the glass tint.

Timing: press 90 ms in, then a spring out. Fills 180 ms. Glide 200 ms. Thumb grab 260 ms squash; release spring (stiffness 380, damping 13); speed lean spring (240, 11). Wake 420 ms. Ripple 440 ms (620 ms on release). Percent roll 220 ms. Section swap 260 ms. Freezing front 620 ms, whole formation 1.25 s. Melt 420 ms; rime melt-back 500 ms. Cold air 900 ms per sample. Trend inspector 120 ms in, 180 ms out. Easing is strong ease-out `(0.23, 1, 0.32, 1)` or ease-in-out `(0.65, 0, 0.35, 1)`. Nothing loops, and hiding the panel removes every transient animation.

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
