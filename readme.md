# albus playbook

a windows optimization script for people who know what they're doing.  
applies ~400 registry tweaks, removes bloat, locks privacy, installs a native low-latency service — one run, no interactivity except gpu driver selection.

---

## usage

**playbook**
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex
```
run as administrator. the launcher downloads [minsudo](https://github.com/M2Team/NanaRun), elevates to trustedinstaller, and streams the script directly into memory. nothing is left behind except `C:\Albus\albus.log`.

**usb creator**
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/usb.ps1 | iex
```
formats a usb with [ventoy](https://github.com/ventoy/Ventoy) and writes a zero-touch `autounattend.xml` — bypasses oobe, disables telemetry at install time, places an albus shortcut on the desktop. drop your windows iso into the `ISOs` folder and boot.

---

## requirements

- windows 11 — x64
- powershell 5.1+
- administrator (trustedinstaller via launcher)
- internet optional — only needed for software downloads

---

## what it does

### system

- `Win32PrioritySeparation` set to 38 — short variable quantum, max foreground boost
- svchost split threshold maximized — all services share one host process per group
- msi interrupt mode enabled for every pci device
- ghost devices (not present) removed via pnputil
- disk write cache enabled, power management disabled on all non-usb drives
- memory compression disabled
- ntfs: 8.3 names off, last access disabled, trim enabled, memory usage 1
- boot: quietboot, legacy bootmenu, 10s timeout, no platform clock override
- winevt diagnostic channels disabled
- msiserver whitelisted for safe mode
- exploit guard mitigations disabled system-wide
- spectre/meltdown kernel mitigations disabled (registry)
- critical process ifeo mitigation payloads zeroed (fontdrvhost, dwm, lsass, explorer, etc.)

### power

custom plan `albus 6.2` built on top of ultimate performance:

| setting | value |
|---|---|
| cpu min / max state | 100% / 100% |
| core parking min / max | 100% / 100% |
| energy performance preference | 0 (max perf) |
| heterogeneous scheduling | disabled |
| cpu cooling | active |
| pcie link state | off |
| usb selective suspend | off |
| sleep / hibernate / hybrid sleep | never |
| power throttling | off |
| modern standby | off |
| fast boot | off |
| display timeout | 10 min |

unnecessary plans deleted. hibernate file removed. sleep and lock removed from start menu flyout.

### privacy & telemetry

- all telemetry registry paths zeroed: `AllowTelemetry`, `DiagTrack`, `SQMLogger`, `CEIP`, `WMI autologgers`
- firewall rules block diagtrack (`svchost/DiagTrack`) and wersvc outbound
- telemetry binaries renamed to `.bak` — `CompatTelRunner.exe`, `DeviceCensus.exe`, `AggregatorHost.exe`, `wsqmcons.exe`, `WerFault.exe`, `WerFaultSecure.exe`, `wermgr.exe`, `DiagnosticsHub.StandardCollector.Service.exe`, `omadmclient.exe`
- dism packages stripped: DiagTrack, Telemetry, CEIP, Cortana, AI/ML, BioEnrollment, Holographic, QuickAssist, StepsRecorder, WirelessDisplay
- winsxs manifests matching `*diagtrack*`, `*telemetry*`, `*ceip*`, `*diaghub*`, `*wer*` renamed
- cortana, copilot, recall, windows ai, click-to-do disabled
- advertising id, tailored experiences, cloud content delivery, spotlight all off
- settings sync fully disabled across all categories
- activity history, online speech recognition, game dvr, wi-fi sense off
- ceip disabled for app-v, sqm, ie, messenger, unattend
- wer reporting, consent, and logging disabled

### services disabled

| category | services |
|---|---|
| telemetry & diagnostics | DiagTrack, dmwappushservice, diagnosticshub.standardcollector.service, WerSvc, wercplsupport, DPS, WdiServiceHost, WdiSystemHost, troubleshootingsvc, diagsvc, PcaSvc, InventorySvc |
| bloat | WpnUserService, RetailDemo, MapsBroker, wisvc, UCPD, GraphicsPerfSvc, Ndu, DSSvc, WSAIFabricSvc |
| print | Spooler, PrintNotify |
| remote desktop | TermService, UmRdpService, SessionEnv |
| sync | OneSyncSvc, CDPUserSvc, TrkWks |
| superfluous | RdyBoost, SysMain, dam |

svchost splitting disabled per-service (`SvcHostSplitDisable=1`).  
rdyboost removed from disk lowerfilters.

### scheduled tasks disabled

`Application Experience`, `AppxDeploymentClient`, `Autochk`, `Customer Experience Improvement Program`, `DiskDiagnostic`, `Flighting`, `Defrag`, `Power Efficiency Diagnostics`, `Feedback`, `Maintenance`, `Maps`, `SettingSync`, `CloudExperienceHost`, `DiskFootprint`, `WindowsAI`, `WDI`, `PI`

### network

- nagle disabled: `TcpAckFrequency=1`, `TCPNoDelay=1` per interface
- tcp: `autotuninglevel=restricted`, ecn off, timestamps off, `initialRto=2000`, rsc off, nonsackrttresiliency off
- congestion provider: cubic
- lso (ipv4) disabled, interrupt moderation disabled on all physical adapters
- bindings removed: ipv6, lldp, lltdio, implat, rspndr, server, msclient
- adapter power saving properties zeroed: eee, aspm, wol, pme, nic auto power saver, pnpcapabilities=24
- netbios over tcpip disabled
- llmnr disabled
- dns coalescing disabled
- qos policies: `cs2.exe` and `r5apex.exe` tagged dscp 46

### debloat

**edge** — fully removed: browser, webview2, edge update infrastructure. registry `NoRemove` cleared before uninstall. spoofed sihost.exe path to bypass the installer's environment check.

**onedrive** — uninstalled per-user via registry uninstall string, fallback to system paths. sidebar entry removed (`{018D5C66-4533-4307-9B53-224DE2ED1FE6}`). user appdata and start menu links cleaned.

**uwp** — all packages removed except: `Paint`, `WindowsStore`, `Photos`, `ShellExperienceHost`, `StartMenuExperienceHost`, `WindowsNotepad`, `ImmersiveControlPanel`, `SecHealthUI`, and media codec extensions (AV1, AVC, HEIF, HEVC, MPEG2, VP9, WebP, WebMedia, RawImage).

**windows capabilities** — all removed except: `Ethernet`, `WiFi`, `Notepad`, `NetFX3`, `VBSCRIPT`, `WMIC`, `ShellComponents`.

**optional features** — disabled except: `DirectPlay`, `LegacyComponents`, `NetFx`, `SearchEngine-Client`, `Server-Shell`, `Windows-Defender`, `Drivers-General`, `WirelessNetworking`.

**other**: `GameInput`, `Update Health Tools` (uhssvc + PLUGScheduler), all run/runonce keys cleared, startup folders emptied.

### ui & shell

- true black wallpaper generated at native resolution, applied as desktop and lock screen
- dark mode, transparency off, accent color 0x000000
- sound scheme: none (all event sounds cleared)
- visual effects: custom — animations off, aero peek off, listview alpha/shadow off, thumbnail caching off
- mouse: enhance pointer precision disabled, 1:1 eppcurve applied (sensitivity 10, zeroed thresholds, correct SmoothMouseX/YCurve bytes)
- typing: autocorrect, spellcheck, text prediction, hwkb autocorrection, multilingual, voice typing all off
- ease of access: all flags zeroed
- narrator: all options disabled
- explorer: file extensions shown, full path in title bar, classic context menu, details in copy dialog, autoplay off, folder type detection disabled, shortcut arrow removed, gallery/network hidden from sidebar, downloads unsorted
- taskbar: search hidden, task view hidden, copilot button hidden, end task on right-click enabled, animations off
- notifications: toast disabled, notification center disabled, no lock screen toasts
- start menu: 6 pins (store, settings, notepad, paint, explorer, calculator), suggestions off, most used apps hidden
- account pictures blacked out
- accessibility folders hidden with attrib

### software (requires internet)

- brave browser — latest, silent, hardware acceleration off, background mode off, high efficiency on
- 7-zip — latest, cascaded context menu off
- localsend — latest, silent
- visual c++ x64 runtime
- directx end-user runtime

### gpu drivers (interactive)

**nvidia**  
opens driver download page, waits for keypress, file picker selects the downloaded exe. extracted with 7-zip, whitelist kept: `Display.Driver`, `NVI2`, `EULA.txt`, `ListDevices.txt`, `setup.cfg`, `setup.exe`. eula/consent/privacy lines removed from setup.cfg. installs with `-s -noreboot -noeula -clean`.

post-install registry tweaks:
- `DisableDynamicPstate=1` per gpu adapter key
- `RMHdcpKeyglobZero=1` (disables hdcp key generation overhead)
- nvidia profile inspector imported silently with a baked `.nip` profile

nvidia profile inspector settings applied (`Base Profile`):

| setting | value |
|---|---|
| Frame Rate Limiter V3 | 0 (off) |
| GSYNC (global) | disabled |
| Maximum Pre-Rendered Frames | 1 |
| Ultra Low Latency | enabled |
| Ultra Low Latency CPL State | 2 |
| Vertical Sync | force off |
| Vertical Sync Tear Control | 2525368439 |
| Preferred Refresh Rate | highest available |
| Antialiasing Mode | application controlled |
| Antialiasing Gamma Correction | off |
| Anisotropic Filter Optimization | on |
| Texture Filtering Quality | high performance (20) |
| Texture Filtering Trilinear Optimization | off |
| Texture Filtering Negative LOD Bias | allow |
| CUDA Force P2 State | off |
| Power Management Mode | prefer max performance |
| Shader Cache Size | unlimited (0xFFFFFFFF) |
| Threaded Optimization | on |
| Vulkan/OpenGL Present Method | 0 |

**amd**  
opens download page, waits, file picker. extracted with 7-zip. patches installer xmls (disables enabled/hidden flags in AMDAUEPInstaller, AMDCOMPUTE, AMDUpdater, etc.) and json manifests (sets `InstallByDefault` to `No`). installs via `ATISetup.exe -INSTALL -VIEW:2`.

post-install:
- removes AMDNoiseSuppression, StartRSX autorun entries
- deletes: AMD Crash Defender Service, amdfendr, amdfendrmgr, amdacpbus, AMDSAFD, AtiHDAudioService
- removes AMD Bug Report Tool and AMD Install Manager
- moves adrenalin shortcuts to programs root, removes nested folder
- runs RadeonSoftware.exe once to initialize CN registry, then kills it
- applies UMD settings: VSyncControl=0x30, TFQ=0x32 (high quality), Tessellation=0x31, abmlevel=0x00
- disables amd system tray, auto-update, animations, toast notifications

---

## albusx service

`AlbusX.exe` is a native windows service compiled from `albus.cs` at runtime using `csc.exe` from .NET Framework 4.x. it runs as LocalSystem, starts automatically, and survives crashes via restart policy (5s → 10s → 30s).

it does six things independently and concurrently.

---

### 1 — timer resolution

windows default timer resolution is 15.6ms. albusx locks it to the hardware maximum (typically 0.5ms on most systems).

**how it works:**

```
NtQueryTimerResolution → gets min, max, current values (in 100ns units)
NtSetTimerResolution(MaximumResolution, true) → requests finest available
verification loop: 50 retries, SpinWait between each, confirms actual value dropped
```

if an `.ini` file is present and specifies a custom `resolution=` value, that's used instead of hardware max.

**resolution guard** runs every 30 seconds on a background timer:
- queries current actual resolution
- if it has drifted above target + 100 units (a 10µs tolerance), re-applies
- this handles other software quietly restoring windows default without raising errors

on service stop, resolution reverts to the value captured at startup — no permanent system change.

---

### 2 — process-triggered mode (optional)

if `AlbusX.exe.ini` exists and lists process names, the service switches from always-on to event-driven mode.

**ini format:**
```
cs2.exe
r5apex.exe
resolution=5000
```
commas, spaces, or semicolons as separators. `.exe` extension optional. `resolution=` in 100ns units (e.g. 5000 = 0.5ms).

**flow:**

```
WMI __InstanceCreationEvent (0.5s poll) watches for listed processes
→ process detected: arm resolution, purge standby, ghost memory, priority boost
→ OpenProcess(SYNCHRONIZE) + WaitForSingleObject(-1) blocks until exit
→ process exits: restore default resolution, purge standby, ghost memory, un-boost
```

wmi watcher reconnects automatically on drop (up to 5 retries, 3s delay each).

**ini hot-reload:** `FileSystemWatcher` monitors the ini file. any write triggers a full reload — process list updated, resolution target recalculated, wmi watcher rebuilt. no restart needed.

---

### 3 — standby list purge

two mechanisms:

```csharp
SetSystemFileCacheSize(-1, -1, 0)       // clears system file cache
NtSetSystemInformation(80, ref 4, 4)    // MemoryPurgeStandbyList
```

class 80 (`SystemMemoryListInformation`) with command 4 (`MemoryPurgeStandbyList`) is an undocumented ntdll call that flushes the modified and standby page lists from RAM — freeing physical memory occupied by pages not yet reclaimed by the kernel.

**periodic purge** fires every 5 minutes using `PerformanceCounter("Memory", "Available MBytes")`. purge only runs if available ram is below 1024mb — avoids unnecessary churn on systems with large ram.

---

### 4 — priority management

on game start (or always-on mode):
- `dwm.exe` → `ProcessPriorityClass.High`
- `explorer.exe` → `ProcessPriorityClass.BelowNormal`

on game exit:
- `dwm.exe` → stays High
- `explorer.exe` → Normal

the rationale: explorer at BelowNormal prevents background shell activity from competing with the game during a session. dwm stays high because display composition latency is directly tied to its scheduling.

---

### 5 — audio latency minimization

a dedicated background thread (MMCSS "Pro Audio", `ThreadPriority.Highest`) enumerates every active audio endpoint via Windows Core Audio APIs and pushes each to its minimum shared-mode buffer size.

**flow per device:**

```
IMMDeviceEnumerator.EnumAudioEndpoints(eAll, ACTIVE)
→ for each device: Activate(IAudioClient3)
→ GetMixFormat → current mix format
→ GetSharedModeEnginePeriod → returns default, fundamental, min, max frame counts
→ if min < default: InitializeSharedAudioStream(min period)
→ Start()
```

`IAudioClient3.InitializeSharedAudioStream` is a windows 10+ exclusive api that allows the audio engine to run at minimum hardware-supported period rather than the default 10ms. on most systems this reduces audio engine latency from ~10ms to ~3ms or less.

**device hot-swap:** `IMMNotificationClient.OnDefaultDeviceChanged` triggers `OptimizeAllEndpoints` again when the default audio device changes — usb headsets, monitors with speakers, etc. are handled automatically without restart.

latency reduction is logged per device:
```
[albus audio] miniaturized: frames 441->128 (10.00ms -> 2.90ms). id:...endpoint8
```

---

### 6 — self-optimization

the service applies several measures to itself on start:

| measure | api | effect |
|---|---|---|
| process priority: High | `Process.PriorityClass` | scheduler slots above normal apps |
| thread priority: Highest | `Thread.Priority` | preempts nearly everything |
| gc latency: SustainedLowLatency | `GCSettings.LatencyMode` | suppresses blocking gen2 gc collections |
| processor affinity: core 0 | `ProcessorAffinity = (IntPtr)1` | pinned — avoids migration overhead |
| mmcss: Pro Audio | `AvSetMmThreadCharacteristics` | os-level scheduling boost |
| power throttling: off | `SetProcessInformation(PROCESS_POWER_THROTTLING_STATE)` | disables ecoqos for the service |
| prevent sleep | `SetThreadExecutionState(0x80000003)` | ES_CONTINUOUS \| ES_SYSTEM_REQUIRED \| ES_AWAYMODE_REQUIRED |
| virtual lock | `VirtualLock` | prevents service pages from being paged out |
| ghost memory | `EmptyWorkingSet` | trims its own working set after init |

---

## notes

- windows update paused until 2038-01-19 via registry — resume manually when needed
- edge fully removed; apps depending on webview2 (e.g. some system settings pages) may break
- exploit guard mitigations disabled system-wide — do not run on machines that require them
- spectre/meltdown kernel patches disabled — performance gain on trusted hardware
- uac completely disabled — all processes run at full admin without prompt
- bitlocker auto-encryption prevented; existing volumes decrypted if found
- hibernate disabled and fast boot off — clean kernel resume path
- all startup entries cleared — nothing runs at login except what you add back
- albus does not touch pagefile, cpu affinity for user apps, or display drivers beyond the gpu phase

---

## credits

inspired by and built alongside work from [FR33THY](https://www.youtube.com/watch?v=JJvW9e4X7k0&t=2711s), [MeetRevision](https://github.com/meetrevision/playbook), [PC-Tuning](https://github.com/valleyofdoom/PC-Tuning).
