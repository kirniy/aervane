# Resource measurements

One development build on an M4 Mac mini (32 GB), macOS 27.0, Xcode 26.2 release optimization, 2026-10-23. Measured after launching and exercising the panel. Other desktop work was running. The privileged helper was not installed, so these figures cover the app only.

| State | CPU, one core | Physical footprint | Resident set |
| --- | ---: | ---: | ---: |
| Panel closed, normal 3-second polling | 0.27% | 36.1 MiB | 95.1 MiB |
| Panel open, 1-second polling | 1.00% | 35.5 MiB | 92.5 MiB |

Each CPU value is the process CPU-time delta over one 30-second interval divided by elapsed time; 100% means one fully occupied core. Memory figures are individual samples, not averages. `footprint` reported a lifetime peak of **140.9 MiB** after startup/interface exercise. Resident set includes shared pages and is a different metric from physical footprint. These numbers are not a promise for other Macs or an end-to-end app-plus-helper benchmark.

The signed bundle occupies approximately **2.45 MiB** on disk. Its app executable is 637,664 bytes and helper executable 377,088 bytes; most remaining space is the app icon. Signing or subsequent builds can change these sizes.

## Method

Use `ps -p <pid> -o time=,rss=` twice, 30 seconds apart, and `footprint -p <pid> --noCategories -f bytes`. Close the panel without reopening it during the closed interval. The normal closed interval is three seconds; optional low-power polling uses eight seconds. A visible panel polls every second.

The app has no web runtime, telemetry, background network requests, display link, or idle animation. Temperature history is capped at 60 samples. Slider dot images are rebuilt only when geometry, appearance or the hardware floor changes; pointer motion updates small Core Animation layers.

Before a production release, repeat longer idle and interaction runs on supported Macs, include the privileged helper, profile allocations and wakeups, and verify sleep/wake behavior.
