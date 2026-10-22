# Resource measurements

Installed development build on an M4 Mac mini (32 GB), macOS 27.0, Xcode 26.2 release optimization, 2026-10-23. Measured after exercising the redesigned panel, with Expressive effects selected and the signed privileged helper running. Other desktop work was running.

| State | App CPU, one core | Helper CPU, one core | App physical footprint | App RSS | Helper RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Panel closed, normal 3-second polling | 0.33% | 0.00% | 34.0 MiB | 61.6 MiB | 8.6 MiB |
| Settings panel open, 1-second polling | 1.26% | 0.03% | 32.8 MiB | 79.4 MiB | 7.9 MiB |

Each CPU value is the process CPU-time delta over one 30-second interval divided by elapsed time; 100% means one fully occupied core. A displayed 0.00% is rounding at this sampling resolution, not a claim that the helper does no work. Memory figures are individual samples, not averages. `footprint` reported an app lifetime peak of **89.4 MiB** after startup/interface exercise. Resident set includes shared pages and is a different metric from physical footprint; do not add the two. The unprivileged `footprint` call could not inspect the root helper, so its physical footprint is not reported. These short samples are not a promise for other Macs or a drag-animation benchmark.

The signed bundle contains **2.87 MiB** of file data (about 2.89 MiB allocated on disk). Its app executable is 976,192 bytes and helper executable 495,248 bytes; most remaining space is the app icon. Signing or subsequent builds can change these sizes.

## Method

Identify the app and helper from `ps -axo pid=,comm=`. Use `ps -p <pid> -o time=,rss=` for each twice, 30 seconds apart, and `footprint -p <pid> --noCategories -f bytes`. Close the panel without reopening it during the closed interval. The normal closed interval is three seconds; optional low-power polling uses eight seconds. A visible panel polls every second. The open sample had Settings visible, manual control active and the optional timer running; the closed sample had manual control active and the timer disabled.

The app has no web runtime, telemetry, background network requests, display link, or looping idle animation. Temperature history is capped at 60 samples. Slider dot/frost images are rebuilt only when geometry, appearance or the hardware floor changes; pointer motion updates small Core Animation layers. Temporary animations are removed when the panel closes.

Before a production release, repeat longer idle and interaction runs on supported Macs, measure the helper's physical footprint with suitable access, profile allocations and wakeups, and verify sleep/wake behavior.
