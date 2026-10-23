# 0.4 design review

Implemented with Claude; integrated and tested on macOS.

| Before | After | Why |
| --- | --- | --- |
| Dot Grid moved mainly at full cooling | A cached light wave moves at every nonzero measured speed | Cooling is visible without per-frame Swift drawing |
| Smart target lived in Settings | A dashed target and draggable handle live on the temperature graph | Adjustment stays beside the evidence |
| Setup began with a bare button | Inline choice, preview, explicit setup and verified connection | Explain only the decision being made |
| Hidden shortcuts | Hold Command to reveal hints | Discoverability without permanent labels |
| A failed fan read erased all telemetry | Temperature and fan results are independent | Monitoring survives unavailable fan controls |
| Menu bar and Smart panel used different sensors | Both share one readout | A glance should agree with the opened panel |

Reduced Motion and Effects Off stop decorative loops. Hidden panels and settings pause slider animation. Existing preferences are migrated without replaying first-run onboarding.

The renderer and interaction tests are separate from physical-device verification. See HANDOFF.md and verification.md for current evidence and remaining gaps.
