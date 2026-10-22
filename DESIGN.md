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
typography:
  display:
    fontFamily: "SF Rounded, system-ui, sans-serif"
    fontSize: "44pt"
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
    fontSize: "28pt"
    fontWeight: 500
rounded:
  control: "8pt"
  glass: "26pt"
  glass-fallback: "22pt"
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
    width: "380pt"
  primary-action:
    backgroundColor: "rgba(143,219,194,0.16)"
    textColor: "{colors.accent-dark}"
    rounded: "{rounded.control}"
    height: "32pt"
  preset:
    backgroundColor: "rgba(255,255,255,0.05)"
    textColor: "#FFFFFF"
    rounded: "{rounded.control}"
    height: "32pt"
  quiet-action:
    textColor: "{colors.accent-dark}"
    rounded: "{rounded.control}"
    height: "28pt"
---

# Design System: Aervane

## Overview

**Creative North Star: "The Native Instrument"**

Aervane is a small, precise macOS instrument: temperature leads, fan control follows, and the panel stays light enough to feel like a menu-bar utility. The implementation uses AppKit controls, system typography, system glass, dynamic system colors, and custom linework rather than a web-like dashboard vocabulary.

The first viewport is a 380 pt glass panel with a large temperature reading, a restrained trend line, explicit Auto/Manual state, direct percentage adjustment, and editable presets. Setup, settings, and editing remain inline. The dark capture is the verified finish reference; light mode is implemented dynamically but unverified in review.

**Key Characteristics:**
- Native macOS glass and SF system type.
- Direct effort-style percentage control with truthful hardware-floor language.
- Muted mint/spruce applied state and warm ochre/sand attention state.
- Compact 4/8 pt rhythm with no idle animation or network dependency.

## Colors

The palette is dynamic by appearance. Dark mode uses muted mint and sand against system dark ink; light mode maps those roles to readable spruce and ochre. `Theme.ink` remains the system label color, while `faint` and `hairline` are alpha layers over it.

### Primary
- **Muted mint** (`#8FDBC2`) / **Spruce** (`#126B57`): Applied/manual state, lit slider dots, selected controls, the airflow mark, and the primary setup action.

### Neutral
- **System label:** `NSColor.labelColor`, used for primary text, the slider thumb, and resting icon strokes.
- **Secondary light** (`#5C5C5C`) / **Secondary dark** (`#ADADAD`): Captions, status text, measured values, and footer text.
- **Hairline:** `labelColor` at 10% alpha, used for one-device-pixel section dividers.
- **Glass:** AppKit `NSGlassEffectView` regular material on macOS 26+, with a popover visual-effect fallback on older supported systems.

### Named Rules
**The State Must Speak Rule.** Applied, preview, stale, automatic, and competing-controller states use explicit text and semantic color; color never carries the state alone.

## Typography

**Display Font:** SF Rounded system design, with the system fallback.
**Body Font:** SF Pro system font.
**Label/Mono Font:** SF Pro system font with monospaced digits for changing percentages and preset values.

**Character:** System-native, calm, and legible at menu-bar distance. Rounded display numerals soften the temperature readout; monospaced digits keep the fan value stable during interaction.

### Hierarchy
- **Display** (light, 44 pt, 1.18 line-height): Temperature figure.
- **Title** (semibold, 13 pt): Aervane, Fan, and strong section labels.
- **Numeric** (medium, 28 pt, SF Pro monospaced digits): Requested fan percentage.
- **Body** (medium, 12 pt): Button labels, preset names, settings controls.
- **Label** (regular or medium, 11 pt): Captions, status, hardware floor, health, and footer.

### Named Rules
**The Stable Number Rule.** Values that change during adjustment use monospaced digits; temperature uses the larger rounded display face.

## Layout

The panel is 380 pt wide with 20 pt horizontal margins. `PanelView.arrange` is the single source for frames and window height, using 4/8 rhythm: 8 pt between related controls, 12–16 pt between groups, and 16–32 pt section breathing room. The header sits at 16 pt top inset; temperature and trend share the first section; a one-device-pixel divider separates it from Fan.

The slider hit area extends 16 pt beyond the content margins. Presets use one row for one to three items, then wrap as 2×2, 3+2, or 3×2 through six items. Editor and Settings expand the same panel inline; no modal or separate settings window is introduced.

## Elevation & Depth

Depth comes from the system glass material, tonal fills, one-pixel dividers, and a restrained slider-thumb shadow. The panel itself has AppKit window shadow. Controls do not use hard offset shadows; the active state is a low-alpha accent fill and the slider thumb carries only a 1.5 pt radius shadow.

### Shadow Vocabulary
- **Slider thumb:** black shadow, 1.5 pt radius, zero offset; dark opacity 0.45 and light opacity 0.22.
- **Panel:** AppKit panel shadow supplied by the window (`hasShadow = true`).

### Named Rules
**The Material First Rule.** Let native glass and tonal separation establish depth; reserve shadow for the floating panel and thumb legibility.

## Shapes

The panel is a large rounded glass silhouette: 26 pt on macOS 26+ and 22 pt in the visual-effect fallback. Soft buttons use an 8 pt radius, or half their height when shorter. The slider thumb is a 6×20 pt white pill with a 0.5 pt light-mode edge. Text fields remain native rounded AppKit fields. Hairlines are clipped to the 20 pt content margins.

## Components

### Panel
- **Shape:** Native glass surface, 380 pt wide, 26 pt radius (22 pt fallback).
- **Behavior:** Opens from the status item as a nonactivating pop-up panel and closes on outside click or Escape.

### Fan percentage slider
- **Shape:** Five rows of 2 pt dots on a 3 pt pitch, with a 6×20 pt pill thumb and a one-pixel hardware-floor tick.
- **Color:** Resting dots use label color at low alpha; lit dots use the accent with brightness tied to absolute percentage. The firmware floor is held and labeled, never relabeled as zero.
- **Interaction:** Pointer, keyboard, and accessibility changes preview immediately; release or the debounced keyboard change commits. Reduced Motion removes transitions and bloom. The 100% bloom and haptic are user-action feedback only.

### Mode controls
- **Shape:** Compact 26 pt soft buttons with 8 pt corners.
- **States:** Auto and Manual use quiet tonal fills; selected/applied state uses accent at low alpha and accent text.

### Presets
- **Shape:** 32 pt soft buttons with 8 pt corners, name left and effective percentage right.
- **Behavior:** Up to six presets; values are raised to the hardware floor for display. Edit mode replaces the button row with native name/value fields, delete controls, and an inline “Add current speed” action. Changes save as typed.

### Setup action
- **Shape:** Full-width 32 pt prominent soft button with airflow glyph.
- **Behavior:** Appears only when control is not connected or another controller is present. Preview copy remains “not applied” until setup succeeds.

### Inline Settings
- **Behavior:** Expands below the main controls with native segmented sensor choice, checkboxes for Fahrenheit, login, and low-power polling, plus Source code and Quit actions.

## Do's and Don'ts

### Do:
- **Do** keep temperature first and the direct percentage adjustment immediately available.
- **Do** use dynamic system colors and preserve readable light/dark mappings.
- **Do** label preview, stale, automatic, applied, and competing-controller states in plain language.
- **Do** preserve the hardware minimum and distinguish requested from measured speed.
- **Do** keep presets, editing, and settings inline and persist preset edits immediately.

### Don't:
- **Don't** introduce cards, dashboards, modal speed dialogs, or web-style decorative chrome.
- **Don't** use accent color as the only status signal.
- **Don't** describe a preview as applied or imply that zero is available below the firmware floor.
- **Don't** add idle animation, timers, or network-dependent visual behavior.
- **Don't** canonize the captured pointer-glow artifact as a system rule; physical pointer dragging was unavailable during review.

**Evidence note.** The dark interface is captured in `.impeccable/review/mac-panel.png` and `.impeccable/review/mac-presets.png`, and the fresh finish review disposition is ship for that visible dark interface. Keyboard and accessibility behavior, preset persistence, and UI handler regression tests were verified. Light mode, 1× rendering, VoiceOver announcements, hardware control behavior, and physical pointer dragging remain unverified; this record does not claim those tests or approval.
