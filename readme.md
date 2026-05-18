# albuswin

![platform](https://img.shields.io/badge/platform-windows%2011-0078d4?style=flat-square)
![engine](https://img.shields.io/badge/engine-powershell-5391fe?style=flat-square)
![daemon](https://img.shields.io/badge/daemon-c%23%20%2F%20rust-black?style=flat-square)

a bare-metal windows optimization script.

**disclaimer**: use at your own risk. i accept no responsibility for any system damage or data loss. this script executes aggressive, non-reversible system modifications.

**note**: my primary os is [omarchy](https://github.com/basecamp/omarchy). this exists because i boot windows solely to play cs2. i need the os completely out of the way. it runs once, reboots, and vanishes.

## table of contents

1. [prerequisites](#prerequisites)
2. [usage](#usage)
3. [what it does](#what-it-does)
4. [albus daemon](#albus-daemon)
5. [reversion](#reversion)

## prerequisites

- a clean, freshly installed windows 11 environment.
- active internet connection (for dynamic driver and software deployment).
- no prior debloat scripts applied (to prevent registry conflicts).

## usage

**playbook** — run from an elevated powershell instance:
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex
```

**install media** — build a ventoy usb with autounattend to bypass tpm and oobe requirements:
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/usb.ps1 | iex
```

## what it does

executes as `trustedinstaller`. a ~3000-line, single-pass execution architecture. executes in the following structured sequence:

- **preparation** — terminates interfering shell processes and resets consent storage locks.
- **debloat** — aggressively uninstalls uwp bloatware, optional features, onedrive, and executes a total structural purge of microsoft edge.
- **telemetry purge** — neutralizes ai binaries, nullifies locked telemetry components, and deletes 50+ unused dism packages from the component store.
- **software** — silently deploys essential tools: brave, 7-zip, localsend, vc++ runtimes, and directx.
- **gpu** — automated driver fetching, extraction, and debloating (nvidia, amd, intel). applies profile inspector presets and driver-level registry optimizations.
- **registry** — overwrites ~400 keys covering boot optimizations, prefetch, uac, defender, edge policies, and visual effects.
- **services** — permanently neutralizes 30+ background services.
- **tasks** — wipes 16 scheduled task groups (ceip, defrag, diagnostics, telemetry).
- **network** — disables nagle's algorithm, interrupt moderation, and auto-tuning. applies dscp 46 (expedited forwarding) and strict tcp parameters.
- **power** — deploys a custom "albus" power plan. forces 100% min cpu, disables core parking, heterogeneous scheduling, sleep states, and usb selective suspend.
- **hardware** — purges ghost devices, forces message signaled interrupts (msi) on all pci interfaces, and neutralizes exploit mitigations (spectre/meltdown/vbs/hvci).
- **filesystem** — disables 8.3 naming, last access timestamps, platform clock, and memory compression.
- **ui** — dynamically generates a true black wallpaper, forces system-wide dark mode, and aggressively strips shell animations.
- **startup cleanup** — eradicates all driver and software installation leftovers, leaving zero traces.
- [**albus daemon**](#albus-daemon) — compiles and deploys a native precision latency daemon for extreme hardware enforcement.
- **cleanup** — purges temporary directories, clears all event logs autonomously, and flushes dns before triggering a clean reboot.

## albus daemon

**status**: the entire daemon is being rewritten in **rust** for absolute memory safety and zero-latency execution.

a custom, high-precision latency controller deployed as the final optimization layer. it operates at the edge of physical hardware limits to enforce absolute system stability and responsiveness.

- **cpu topology** — dynamically maps physical cores, e-cores, and numa nodes. calculates ideal processor affinities and isolates gpu/nic irqs to independent hardware threads.
- **process watchdog** — utilizes event tracing for windows (etw) to autonomously detect target executables (e.g. cs2). instantly injects high priority, disables power throttling (ecoqos), and pins execution exclusively to p-cores.
- **memory management** — acquires `selockmemoryprivilege` to allocate 4mb numa-aware large pages, locking critical kernel pools. acts as an aggressive memory manager, purging the standby list when available ram drops below 1gb.
- **gpu enforcement** — hooks the undocumented `d3dkmt` api to force `realtime` scheduling priority directly onto the graphics kernel architecture.
- **network qos** — actively negotiates native udp qos, forcing dscp 46 (expedited forwarding) on all outbound realtime traffic.
- **audio limits** — interfaces directly with `iaudioclient3` via com. overrides shared mode engine periods to their minimum hardware capabilities and runs a real-time glitch/underrun detector.
- **clock precision** — forces and locks a 0.5ms global kernel timer resolution (`ntsettimerresolution`) with a watchdog to correct drift. completely disables processor c-states and manipulates deferred procedure call (dpc) behavior.

## reversion

no backups. no rollbacks. to revert, reinstall windows using the usb creator.
