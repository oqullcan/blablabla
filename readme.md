# albus

```
  albus v6.2  ·  windows optimization playbook
  ──────────────────────────────────────────────
  registry · services · power · network · gpu · debloat · native service
```

---

## a note on why this exists

my daily driver is linux — specifically [omarchy](https://omarchy.org), an arch-based setup i've spent a long time tuning to be exactly what i want. everything about how i compute day-to-day happens there.

but i play cs2. and whenever i touch windows, i can't stop noticing how much of what ships by default is either actively hostile to performance, designed to collect data, or simply leftover from engineering decisions made fifteen years ago that nobody cleaned up. so this became a hobby: understanding exactly what windows does under the hood, why certain things cause latency, what the registry actually controls, and how to build a system that gets out of its own way.

albus is that understanding, crystallized into a script. it's not a one-click magic optimizer. every change in it has a reason, and this document explains all of them.

---

## overview

```
┌─────────────────────────────────────────────────────────────┐
│                      albus v6.2                             │
├──────────────┬──────────────┬──────────────┬────────────────┤
│   registry   │   services   │    power     │    network     │
│   ~400 keys  │  25 disabled │  custom plan │  tcp/nic/qos   │
├──────────────┼──────────────┼──────────────┼────────────────┤
│   debloat    │     gpu      │   albusx     │  usb creator   │
│  edge/odr/   │  nvidia/amd  │  c# service  │  ventoy+xml    │
│  uwp/caps    │  driver+nip  │  timer/audio │  zero-touch    │
└──────────────┴──────────────┴──────────────┴────────────────┘
```

albus runs once, end to end, with no prompts except gpu driver selection. it elevates to trustedinstaller for the portions that require it, and leaves no scheduled tasks, no background agents, and no modified system files — except `AlbusX.exe` (the compiled native service) and `C:\Albus\albus.log`.

---

## requirements

| requirement | detail |
|---|---|
| os | windows 11 x64 |
| shell | powershell 5.1+ |
| privileges | administrator (launcher handles trustedinstaller) |
| internet | optional — only used for software downloads in phase 2 |
| .net framework | 4.x — required to compile albusx at runtime |

---

## usage

### playbook

```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex
```

run from an elevated powershell. the launcher (`run.ps1`) does three things before the main script ever executes:

1. downloads [minsudo](https://github.com/M2Team/NanaRun) from the latest github release
2. adds `C:\Albus` to windows defender exclusions (prevents false positives on registry manipulation)
3. re-launches the main script under trustedinstaller via `MinSudo -TI`

trustedinstaller is the highest privilege level on windows — higher than administrator. certain registry keys, system files, and service configurations are owned by trustedinstaller and cannot be modified without it. the launcher exists specifically to reach that level cleanly.

### usb creator

```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/usb.ps1 | iex
```

installs [ventoy](https://github.com/ventoy/Ventoy) to a usb drive and writes a zero-touch `autounattend.xml`. drop a windows iso into the `ISOs` folder and boot. the xml:

- bypasses oobe entirely (no microsoft account, no telemetry consent screen, no eula click)
- creates a local account named `Albus` with no password and auto-logon enabled
- pre-applies ~40 registry values at install time (telemetry, driver search, update pause, wer, firewall rules)
- bypasses hardware requirements (tpm, secureboot, cpu, ram)
- places an albus shortcut on the desktop pointing to the playbook one-liner

---

## execution flow

```
run.ps1 (administrator)
    │
    ├── defender exclusion
    ├── .net ngen optimization
    ├── minsudo download + install
    │
    └── MinSudo -TI → albus.ps1 (trustedinstaller)
            │
            ├── phase 1   system preparation
            ├── phase 2   software installation
            ├── phase 3   gpu driver (interactive)
            ├── phase 4   registry tweaks
            ├── phase 5   ui
            ├── phase 6   services
            ├── phase 7   scheduled tasks
            ├── phase 8   network configuration
            ├── phase 9   power plan
            ├── phase 10  hardware tuning
            ├── phase 11  filesystem & boot
            ├── phase 12  albusx service
            ├── phase 13  debloat
            ├── phase 14  startup cleanup
            └── phase 15  cleanup
```

---

## phase 1 — system preparation

before touching any registry or service, albus kills processes that hold locks on the state it's about to modify.

```
AppActions · CrossDeviceResume · FESearchHost · SearchHost
SoftLandingTask · TextInputHost · WebExperienceHostApp
WindowsBackupClient · ShellExperienceHost · StartMenuExperienceHost
Widgets · WidgetService · MiniSearchHost
```

**why:** processes like `StartMenuExperienceHost` hold open handles to their registry sections. modifying those keys while the process is alive can result in partial writes, race conditions, or the process overwriting your changes on next refresh. killing them first ensures clean writes.

it also resets the capability consent storage database (`CapabilityConsentStorage.db`) after stopping the camera service. this is required because the app permission tweaks applied later (webcam deny, mic allow, etc.) will be ignored if the database has stale consent entries that override registry values.

---

## phase 2 — software installation

all downloads fetch the latest release from github's api rather than hardcoded urls. installs are silent. the following are installed:

| software | reason |
|---|---|
| brave browser | replaces edge, which is removed in phase 13. hardware acceleration disabled (reduces gpu scheduler contention), background mode off (no phantom cpu usage), high efficiency mode on |
| 7-zip | required by the nvidia and amd gpu phases for driver extraction. context menu set to non-cascaded to avoid the nested submenu annoyance |
| localsend | local file transfer without cloud. no specific performance reason — just a quality utility |
| visual c++ x64 runtime | many games and tools silently require this. better to have it than not |
| directx runtime | same category — older dx9/dx10/dx11 titles need certain redistributable components that aren't shipped with windows 11 |

---

## phase 3 — gpu driver

### nvidia

the standard nvidia installer ships with telemetry components, the geforce experience overlay, and several services that run permanently in the background. albus strips all of that.

**extraction and debloat:**

```
driver.exe → 7z extract → C:\Albus\NVIDIA\
    │
    ├── keep: Display.Driver · NVI2 · EULA.txt · ListDevices.txt
    │          setup.cfg · setup.exe
    │
    └── delete: everything else
                (GFExperience, ShadowPlay, NGX, PhysX standalone,
                 NvContainer, telemetry, audio SDK, etc.)
```

`setup.cfg` is patched to remove references to `EulaHtmlFile`, `FunctionalConsentFile`, and `PrivacyPolicyFile` — these lines trigger the eula and consent screens during installation. without them, `setup.exe -s -noreboot -noeula -clean` runs fully silent.

**registry optimizations post-install:**

| key | value | why |
|---|---|---|
| `DisableDynamicPstate` | 1 | prevents the gpu from dynamically adjusting power states mid-frame. pstate transitions introduce latency spikes. on a gaming system, staying in p0 (max performance state) is always correct |
| `RMHdcpKeyglobZero` | 1 | disables hdcp key generation overhead. hdcp is a content protection protocol relevant for drm media. it has no role in gaming and the key generation adds unnecessary gpu workload |
| `EnableGR535` | 0 | disables a gpu resiliency feature that polls driver state. adds overhead, relevant only for stability monitoring in enterprise contexts |
| `NvTray StartOnLogin` | 0 | the nvidia system tray process adds a persistent background agent. removing it from startup eliminates that |
| `OptInOrOutPreference` | 0 | opts out of nvidia telemetry data collection |

**nvidia profile inspector:**

a `.nip` profile is generated and applied silently via `nvidiaProfileInspector.exe -silentImport`. this configures the driver-level rendering profile for all applications globally.

```
key settings and why:

  frame rate limiter v3 = 0
    → no in-driver fps cap. any capping should happen at the application
      or display level, not in the driver where it introduces scheduling lag.

  gsync global feature = 0
  vsync = force off (0x83F40001)
  vsync tear control = 2525368439 (adaptive)
    → gsync and vsync both introduce input latency by design — they synchronize
      frame presentation to the display refresh cycle, which means frames wait.
      in competitive play, tearing is preferable to latency.

  maximum pre-rendered frames = 1
    → limits how far ahead the cpu queues frames for the gpu.
      higher values smooth frametime at the cost of input lag.
      1 means the cpu sends one frame ahead, minimizing the pipeline delay.

  ultra low latency = enabled
  ultra low latency cpl state = 2
    → nvidia's "just in time" frame submission. instead of queuing frames
      deep into the render pipeline, frames are submitted as late as possible
      — immediately before the gpu needs them. reduces cpu-to-display latency.

  preferred refresh rate = highest available (1)
    → tells the driver to always target the maximum refresh rate the
      connected display supports.

  antialiasing mode = application controlled (1)
  antialiasing gamma correction = off
  anisotropic filter optimization = on
  anisotropic filter sample optimization = on
  texture filtering quality = high performance (20)
  texture filtering trilinear optimization = off
  texture filtering negative lod bias = allow (0)
    → all texture/aa settings handed to the application. the driver
      should not override what the game engine requests. trilinear
      optimization can cause blurring on textures at oblique angles,
      so it's off. lod bias allowed so applications can use negative
      bias for sharpness if they choose.

  cuda force p2 state = 0
    → prevents cuda contexts from forcing the gpu into a reduced power
      state (p2). irrelevant for most games but matters for any compute
      workload running alongside.

  power management mode = prefer max performance (1)
    → forces gpu to stay at maximum clock speeds regardless of load.
      avoids the latency of clock ramp-up when a frame arrives after
      a brief idle period.

  shader cache size = unlimited (0xFFFFFFFF)
    → no artificial cap on the driver's compiled shader cache. shaders
      that miss the cache must recompile in real-time, causing stutters.
      unlimited cache size maximizes the chance of cache hits.

  threaded optimization = on (1)
    → allows the driver to distribute opengl/directx calls across
      multiple threads. nearly always a performance improvement.
```

### amd

similar approach — extract, patch installer manifests, silent install, cleanup, registry optimizations.

the amd installer xml files (`AMDAUEPInstaller.xml`, `AMDUpdater.xml`, etc.) are patched to flip `<Enabled>true</Enabled>` to false for all optional components and set `InstallByDefault` to `No` in json manifests. this prevents the installer from silently bundling the radeon software suite, amd link, and various update agents.

post-install:
- removes amd noise suppression autorun
- deletes: AMD Crash Defender Service, amdfendr, amdfendrmgr, amdacpbus, AMDSAFD, AtiHDAudioService
- removes the amd install manager via msiexec
- moves adrenalin start menu shortcuts out of the nested folder (the nested folder has a unicode colon `꡹` in its name, which breaks some tools)

registry (umd keys, per gpu adapter):

| key | value | why |
|---|---|---|
| `VSyncControl` | 0x30 | vsync off at driver level — same reasoning as nvidia |
| `TFQ` | 0x32 | texture filter quality: high performance |
| `Tessellation` | 0x31 | tessellation: application controlled |
| `abmlevel` | 0x00 | adaptive backlight management off — amd's panel brightness adjustment based on content, irrelevant on desktop monitors |

---

## phase 4 — registry tweaks

this is the densest phase. grouped by category.

### boot

**`BootExecute`** — `autocheck autochk /k:C*`

the default value is `autocheck autochk *`. the `*` triggers chkdsk on all volumes at boot if any are flagged dirty. adding `/k:C` skips the check on `C:`. on modern nvme ssds with journaled ntfs, the filesystem is resilient enough that this check is rarely useful and always slow.

**`DisableWpbtExecution`** — `1`

the windows platform binary table is a uefi mechanism that allows firmware to place executables in a reserved memory region that the bootloader maps and executes before the os takes control. legitimate uses exist (some oem tools use it) but it's also a persistence vector for rootkits. disabling it on a known-clean system has no downside.

### crash control

**`AutoReboot`** — `0`

by default, windows reboots immediately on a bsod. this hides the stop code. setting it to 0 keeps the bsod on screen so you can read the error.

**`CrashDumpEnabled`** — `3` (small dump, 64kb)

a full memory dump can be gigabytes. a small dump contains the stop code, stack trace, and loaded drivers — enough to diagnose most crashes without filling the disk.

**`DisplayParameters`** — `1`

shows the bsod parameters (the four numbers under the stop code) on screen. these numbers are essential for looking up the specific cause of a crash.

### win32 priority separation

**`Win32PrioritySeparation`** — `38`

this is a 6-bit value that controls two things: quantum length and foreground boost.

```
value 38 = 0b100110

bits 0-1: 10 → variable quantum
bits 2-3: 01 → short quantum interval  
bits 4-5: 10 → max foreground boost (2x)
```

the result: foreground applications get maximum scheduler priority boost (they're given 2x the base quantum of background processes), and all quantums are short and variable (the scheduler checks in more frequently). for a gaming system where the game is always the foreground app, this is the correct configuration.

### virtualization-based security

**hypervisor launch type** and **vsm launch type** both set to `off`.
`EnableVirtualizationBasedSecurity` → `0`.
hypervisor-enforced code integrity → `0`.

vbs and hvci run parts of the kernel inside a hypervisor to protect credential and code integrity. the protection is real. the performance cost is also real: on many systems, hvci alone reduces gaming performance by 5-15% because every kernel page permission change requires a hypervisor call instead of a direct cpu operation.

on a personal gaming machine that doesn't store domain credentials or process sensitive enterprise data, this trade-off points toward disabling it.

**note:** if you run this on a machine used for work with domain accounts or sensitive credentials, reconsider this section.

### prefetch & superfetch

**`EnablePrefetcher`** → `0`
**`EnableSuperfetch`** → `0`

prefetch and superfetch are disk read prediction systems. they work by building a history of which files are accessed at boot and application launch, then pre-reading them into ram before they're needed.

on a hard disk, this was a meaningful optimization — disk seek times are expensive and predicting reads saved seconds. on an nvme ssd with read speeds over 3GB/s and access latencies under 100µs, the prediction advantage disappears. the processes that run these systems (`SysMain` service) consume cpu and memory to maintain something that provides no measurable benefit on fast storage.

### uac

all uac prompts and elevation dialogs disabled.

`EnableLUA` → `0` means all processes run as full administrator without any prompt or confirmation. this removes the security layer that asks "are you sure?" before elevated actions.

**why:** the constant prompts interrupt workflow, and on a personal machine where you understand what you're running, they provide no meaningful protection. the real attack surface for malware is not "running as admin" — it's the initial execution vector (email attachments, malicious downloads). once that vector is closed through awareness, uac's prompts are noise.

### smartscreen & defender

smartscreen is disabled for web content evaluation and app install control (set to `Anywhere` — any source is allowed).

defender system tray icon and `SecurityHealth` startup entry removed.

**why:** these are ui-level warnings, not actual protection mechanisms. the underlying defender antivirus engine continues to run (albus does not disable the antimalware service — only the notification layer). if you want defender off entirely, that requires a separate process outside the scope of albus.

### edge & webview2 policy

```
InstallDefault → 0          (edge: don't install)
Install{56EB18F8...} → 0    (edge browser: don't install/reinstall)
Install{F3017226...} → 1    (webview2: allow reinstall if needed)
DoNotUpdateToEdgeWithChromium → 1
```

these policy keys prevent windows update from silently reinstalling edge after removal. without them, a quality update will often re-deploy the browser.

### bitlocker

**`PreventDeviceEncryption`** → `1`

windows 11 24h2 enables automatic device encryption by default, even on home editions, without explicit user consent. this is a policy change from previous versions. if the machine has no recovery key stored and the user doesn't realize encryption is active, a reinstall or hardware change can result in unrecoverable data.

disabling it prevents automatic encryption. manual bitlocker through the control panel is not affected.

existing encrypted volumes are decrypted if found.

### windows update (paused to 2038)

```
FlightSettingsMaxPauseDays    = 5269  (≈14.4 years)
PauseFeatureUpdatesEndTime    = 2038-01-19T03:14:07Z
PauseQualityUpdatesEndTime    = 2038-01-19T03:14:07Z
PauseUpdatesExpiryTime        = 2038-01-19T03:14:07Z
```

driver updates from windows update disabled. store os upgrade disabled. delivery optimization set to lan-only (no p2p upload to microsoft's cdn).

**why:** windows update has a documented history of pushing driver updates that regress gpu, nic, and audio performance. the in-box nvidia and amd drivers are often months behind the release channel and don't include the latest optimizations. by blocking driver delivery through windows update, driver management stays manual — you install exactly what you chose, when you chose.

quality updates (security patches) are paused, not permanently blocked. when you want to update, change the pause end date or use `wuauclt /detectnow`.

### telemetry

```
AllowTelemetry → 0  (across 7 registry paths)
DiagTrack service → disabled
WMI autologgers (Diagtrack-Listener, SQMLogger, SetupPlatformTel) → Start=0
Firewall rules: block DiagTrack outbound, block WerSvc outbound
TailoredExperiencesWithDiagnosticDataEnabled → 0
EnableEventTranscript → 0
NumberOfSIUFInPeriod → 0  (feedback frequency: never)
AdvertisingInfo Enabled → 0
EnableClipboardHistory → 0
GameDVR_Enabled → 0
```

`AllowTelemetry=0` is documented as "security" level — microsoft says only essential telemetry is sent at this level. in practice, multiple independent researchers have found that windows continues sending data beyond what's documented even at level 0. albus goes further: the `DiagTrack` service is disabled entirely, its WMI autologger `Start` value set to 0 (so it doesn't activate during boot), and outbound firewall rules block the `svchost` instances hosting `DiagTrack` and `WerSvc` from reaching the internet even if they somehow start.

the telemetry binary neutralization in phase 13 adds another layer — `CompatTelRunner.exe`, `DeviceCensus.exe`, and several others are renamed to `.bak` so they cannot execute even if a service attempts to invoke them directly.

### copilot & ai

everything off: windows copilot, recall, click-to-do, paint ai (generative fill, cocreator, image creator), notepad ai, bing chat, system ai model consent store.

**why:** recall specifically is a continuous screenshot-and-ocr system that indexes everything visible on the screen into a searchable local database. the privacy implications are significant even for local-only storage. on a gaming machine, it's also a constant background workload with no benefit.

### process priorities via ifeo

image file execution options (ifeo) `PerfOptions` keys let you set baseline cpu and i/o priorities for processes without modifying them:

| process | cpupriority | iopriority | why |
|---|---|---|---|
| SearchIndexer.exe | 5 (background) | — | indexing is never time-critical. background priority ensures it never preempts foreground work |
| ctfmon.exe | 5 (background) | — | text input framework monitor. runs always but rarely needs responsiveness |
| fontdrvhost.exe | 1 (idle) | 0 (very low) | font driver host. loads fonts on demand. idle priority is correct |
| lsass.exe | 1 (idle) | — | local security authority. authentication events are rare during gaming; lowering its base priority reduces background overhead |
| sihost.exe | 1 (idle) | 0 (very low) | shell infrastructure host. handles shell notifications and the system tray. should never compete with the game |

### service shutdown timeout

**`WaitToKillServiceTimeout`** → `1500` (1.5 seconds)

default is 20 seconds. when you shut down or restart, windows sends a stop signal to all running services and waits up to 20 seconds for each to exit gracefully before forcing termination. 1.5 seconds is enough for any well-written service. badly written services that take longer get killed — which is the correct outcome on shutdown anyway.

### app compatibility engine

```
DisableEngine → 1
AITEnable → 0
DisableUAR → 1
DisablePCA → 1
DisableInventory → 1
```

the application compatibility infrastructure runs a compatibility database check on every process launch. it looks up each executable against a list of known applications that require shimming (patching) to run on modern windows. for the vast majority of modern applications, this lookup finds nothing and takes a few milliseconds for no reason.

disabling it removes that per-launch overhead. the shim database still exists; processes that genuinely need compatibility shims (old dx8 games, etc.) can have them applied manually.

### maintenance & defrag scheduling

automatic maintenance disabled. scheduled diagnostics disabled. system restore scheduling disabled (disk percent → 0). disk defragmentation scheduling disabled.

**why:** automatic maintenance triggers disk scans, defragmentation, windows defender scans, and software inventory at "idle" times that may coincide with gaming. on an ssd, defragmentation is actively harmful (unnecessary write amplification). on nvme, it's doubly irrelevant.

### app permissions

```
location          → deny
webcam            → deny
microphone        → allow
activity          → deny
userAccountInfo   → deny
appointments      → deny
radios            → deny
bluetoothSync     → deny
appDiagnostics    → deny
documentsLibrary  → deny
picturesLibrary   → deny
videosLibrary     → deny
broadFileSystemAccess → deny
```

microphone is explicitly allowed because voip (discord, in-game voice) requires it. everything else is denied by default. individual applications that legitimately need a permission can be granted it through settings.

### visual effects

**`UserPreferencesMask`** → custom binary value disabling:
- animate windows when minimizing/maximizing
- animate controls and elements inside windows
- fade or slide menus into view
- fade or slide tooltips into view
- fade out menu items after clicking
- show shadows under mouse pointer
- slide taskbar buttons
- smooth edges of screen fonts (cleartype remains on separately)

**`MinAnimate`** → `0`
**`DragFullWindows`** → `0` (draw window outline while dragging, not full content)
**`EnableAeroPeek`** → `0`

**why:** every animation is a frame that the gpu compositor (dwm) must render. none of these animations convey information — they're purely aesthetic. disabling them reduces dwm's workload and makes the ui feel more responsive because elements appear immediately instead of after a 200ms fade.

### mouse

enhance pointer precision disabled:

```
MouseSpeed      → 0   (disables acceleration curve)
MouseThreshold1 → 0
MouseThreshold2 → 0
```

the 1:1 epp-on curve applied via `SmoothMouseXCurve` and `SmoothMouseYCurve`:

```
x curve: 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
          0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00,
          0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00,
          0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00,
          0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00

y curve: 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
          0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00,
          0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00,
          0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00,
          0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00
```

these curve values produce a perfectly linear mapping between physical mouse movement and cursor movement even when the windows acceleration system is technically "active" (which it is when `MouseSpeed=0` but the curves are defined). `MouseSensitivity=10` is the default midpoint — no sensitivity scaling applied.

**why this matters:** mouse acceleration means the faster you physically move the mouse, the more the cursor moves per millimeter of physical travel. this makes muscle memory unreliable in aiming — the same physical motion produces different results depending on speed. disabling it gives 1:1 movement at all speeds.

---

## phase 5 — ui

### wallpaper & theme

generates a true black jpeg at the primary monitor's native resolution, applies it as both desktop wallpaper and lock screen background. dark mode on, transparency off, accent color `#000000`.

**sound scheme** set to none — all system event sounds cleared across 28 individual paths.

**account pictures** replaced with black images of matching dimensions. this prevents windows from using a colorful avatar in places where it appears (lock screen, start menu).

### start menu

a minimal pin list is written directly to `start2.bin` (the binary format windows uses to store start menu layout):

```
microsoft store · settings · notepad · paint · file explorer · calculator
```

everything else unpinned. start suggestions, iris recommendations, account notifications all disabled.

### taskbar

- alignment: left (windows 10 style)
- search: hidden
- task view button: hidden
- copilot button: hidden
- animations: disabled
- widgets/news: disabled
- meet now: removed
- teams chat: disabled
- end task on right-click: **enabled** (this is a developer setting — shows "end task" in the taskbar right-click menu for running apps)

---

## phase 6 — services

```
┌─────────────────────────────────┬──────────┬─────────────────────────────────────────┐
│ service                         │ action   │ why                                     │
├─────────────────────────────────┼──────────┼─────────────────────────────────────────┤
│ DiagTrack                       │ disabled │ telemetry upload service                │
│ dmwappushservice                │ disabled │ mobile device management push           │
│ diagnosticshub.standardcoll...  │ disabled │ vs diagnostic data collection           │
│ WerSvc                          │ disabled │ windows error reporting upload          │
│ wercplsupport                   │ disabled │ wer control panel                       │
│ DPS                             │ disabled │ diagnostic policy service               │
│ WdiServiceHost                  │ disabled │ diagnostic service host                 │
│ WdiSystemHost                   │ disabled │ diagnostic system host                  │
│ troubleshootingsvc              │ disabled │ recommended troubleshooting             │
│ diagsvc                         │ disabled │ diagnostic execution service            │
│ PcaSvc                          │ disabled │ program compatibility assistant         │
│ InventorySvc                    │ disabled │ compatibility appraiser                 │
│ WpnUserService                  │ disabled │ push notification infrastructure        │
│ RetailDemo                      │ disabled │ oem demo mode                           │
│ MapsBroker                      │ disabled │ offline maps background download        │
│ wisvc                           │ disabled │ windows insider service                 │
│ UCPD                            │ disabled │ user choice protection (store policy)   │
│ GraphicsPerfSvc                 │ disabled │ graphics performance monitor            │
│ Ndu                             │ disabled │ windows network data usage monitor      │
│ DSSvc                           │ disabled │ data sharing service                    │
│ WSAIFabricSvc                   │ disabled │ windows subsystem for android ai        │
│ Spooler                         │ disabled │ print spooler (no printer assumed)      │
│ PrintNotify                     │ disabled │ printer notifications                   │
│ TermService                     │ disabled │ remote desktop                          │
│ UmRdpService                    │ disabled │ rdp user mode port redirector           │
│ SessionEnv                      │ disabled │ remote desktop configuration            │
│ OneSyncSvc                      │ disabled │ settings sync to microsoft account      │
│ CDPUserSvc                      │ disabled │ connected devices platform              │
│ TrkWks                          │ disabled │ distributed link tracking client        │
│ RdyBoost                        │ disabled │ readyboost (usb flash ram cache)        │
│ SysMain                         │ disabled │ superfetch                              │
│ dam                             │ disabled │ desktop activity moderator              │
└─────────────────────────────────┴──────────┴─────────────────────────────────────────┘
```

`condrv` (console driver) is explicitly set to `start=2` (automatic) to ensure it doesn't get accidentally caught in any bulk-disable logic — console windows require it.

**svchost splitting disabled:** windows splits services into individual svchost.exe processes to improve stability (if one service crashes, it doesn't take others with it) and security (isolation). on a gaming machine, the benefit is marginal and the overhead is not: dozens of separate svchost processes means dozens of memory allocations, page table entries, and scheduler objects. setting `SvcHostSplitDisable=1` per service and maximizing `SvcHostSplitThresholdInKB` collapses related services back into shared host processes.

**rdyboost removed from lowerfilters:** the disk class driver lowerfilters stack is the chain of kernel drivers that intercept disk i/o. rdyboost inserts itself here to cache disk reads to a usb drive. removing it from the filter stack means disk i/o takes a shorter path through the kernel.

---

## phase 7 — scheduled tasks

all tasks in these paths disabled:

```
\Microsoft\Windows\Application Experience\
\Microsoft\Windows\AppxDeploymentClient\
\Microsoft\Windows\Autochk\
\Microsoft\Windows\Customer Experience Improvement Program\
\Microsoft\Windows\DiskDiagnostic\
\Microsoft\Windows\Flighting\
\Microsoft\Windows\Defrag\
\Microsoft\Windows\Power Efficiency Diagnostics\
\Microsoft\Windows\Feedback\
\Microsoft\Windows\Maintenance\
\Microsoft\Windows\Maps\
\Microsoft\Windows\SettingSync\
\Microsoft\Windows\CloudExperienceHost\
\Microsoft\Windows\DiskFootprint\
\Microsoft\Windows\WindowsAI\
\Microsoft\Windows\WDI\
\Microsoft\Windows\PI\
```

these tasks fire at "idle" times to perform diagnostics, telemetry collection, defragmentation, settings sync, and ai model maintenance. "idle" detection in windows is not reliable — tasks have fired during low-frametrate game scenes that windows misidentified as idle.

---

## phase 8 — network configuration

### tcp stack

```
autotuninglevel  = restricted
ecncapability    = disabled
timestamps       = disabled
initialRto       = 2000
rss              = enabled
rsc              = disabled
nonsackrttresiliency = disabled
congestion provider  = cubic (internet template)
```

**autotuninglevel restricted:** windows TCP auto-tuning dynamically grows the receive buffer as throughput increases. "restricted" allows some growth but caps it — this reduces latency jitter caused by the buffer scaling algorithm on connections where you don't need maximum throughput (e.g. gaming, where you need low latency, not high bandwidth).

**ecn disabled:** explicit congestion notification is a mechanism where routers signal congestion back to endpoints without dropping packets. many network devices in the wild do not implement ecn correctly, and packets with ecn bits set can be dropped or mishandled. disabling it avoids compatibility issues.

**timestamps disabled:** tcp timestamps add 12 bytes to every packet header for round-trip time measurement. on a gaming connection, this overhead has no benefit — rtt measurement is already handled at the application layer by the game engine.

**rss enabled:** receive side scaling distributes incoming packet processing across multiple cpu cores. on a modern multi-core system, this prevents a single core from becoming the bottleneck for all incoming network traffic.

**rsc disabled:** receive segment coalescing batches multiple incoming packets into larger ones before delivering them to the protocol stack. this improves throughput but adds latency — the packets wait to be batched. for gaming, unbatched delivery is correct.

### interface settings

for all active physical adapters:
- lso (large send offload) ipv4 disabled
- interrupt moderation disabled
- ipv6, lldp, lltdio, implat, rspndr, server, msclient bindings removed

**interrupt moderation:** the nic hardware can batch multiple received packets into a single cpu interrupt rather than interrupting for each packet. this reduces cpu load at the cost of latency — packets sit in the nic buffer waiting for the batch. disabling it means an interrupt fires for every packet, adding cpu overhead but minimizing the time between packet arrival and application delivery.

**power properties zeroed per adapter:** eee (energy efficient ethernet), aspm (active state power management), wake on lan, device sleep on disconnect, nic auto power saver, pnpcapabilities=24 (prevents windows from powering down the adapter when "idle").

### tcp nagle per interface

```
TcpAckFrequency = 1   (ack every packet, don't wait to batch acks)
TCPNoDelay      = 1   (disable nagle algorithm)
```

nagle's algorithm holds small tcp packets and waits for an ack before sending, or waits until enough data accumulates to fill a full segment. this improves bandwidth efficiency for bulk transfers but adds 40-200ms latency to small packets. games send many small packets (position updates, input state) — nagle is actively harmful.

### qos policies

`cs2.exe` and `r5apex.exe` tagged with dscp 46 (expedited forwarding). routers that respect dscp will prioritize these packets in queues.

---

## phase 9 — power plan

a custom plan named `albus 6.2` is built from the ultimate performance base (or high performance as fallback). all existing plans except power saver (kept as required-by-windows fallback) are deleted.

```
┌──────────────────────────────────────────────────────────────────┐
│                     albus 6.2 power plan                         │
├──────────────────────────┬─────────────┬────────────────────────┤
│ setting                  │ ac   dc     │ reason                  │
├──────────────────────────┼─────────────┼────────────────────────┤
│ cpu min state            │ 100% 100%   │ no clock scaling        │
│ cpu max state            │ 100% 100%   │ always full speed       │
│ core parking min         │ 100% 100%   │ all cores unparked      │
│ core parking max         │ 100% 100%   │ all cores available     │
│ energy perf preference   │  0    0     │ max perf, ignore power  │
│ heterogeneous scheduling │  0    0     │ no p/e-core splitting   │
│ cpu cooling policy       │ active active│ fan, not throttle      │
│ sleep after              │ never never │ no sleep                │
│ hybrid sleep             │  off  off   │ no hybrid               │
│ hibernate after          │ never never │ no hibernate            │
│ wake timers              │  off  off   │ nothing wakes the pc    │
│ usb selective suspend    │  off  off   │ usb always powered      │
│ pcie link state          │  off  off   │ gpu always in p0        │
│ adaptive brightness      │  off  off   │ no panel dimming        │
│ power throttling         │  off  off   │ no ecoqos               │
│ modern standby           │  off  off   │ no connected standby    │
│ fast boot                │  off  off   │ cold boot only          │
│ hibernate                │  off  off   │ no hiberfil.sys         │
└──────────────────────────┴─────────────┴────────────────────────┘
```

**core parking:** when cores are "parked", the scheduler migrates all threads away from them and the cores enter a low-power state. unparking takes microseconds, but those microseconds add up when the game is sending work to the cpu at 500+ hz. forcing min and max parking to 100% keeps all cores awake and available.

**heterogeneous scheduling:** on intel 12th gen+ and later amd processors, windows can classify cores into performance and efficiency categories and route workloads accordingly. for a game, this means some game threads may run on e-cores (slower, less cache). forcing heterogeneous scheduling off keeps all workloads on p-cores.

**modern standby:** connected standby allows the pc to perform background tasks (email sync, push notifications) while appearing asleep. it's more similar to a smartphone's idle state than a traditional sleep. on a desktop gaming machine it provides no benefit and interferes with clean sleep/wake cycles.

---

## phase 10 — hardware tuning

### ghost device removal

`pnputil /remove-device` called for every device that is not present on the system but still has a driver entry. ghost devices accumulate when you unplug hardware without uninstalling drivers — they're entries in the device manager with no physical counterpart. they consume registry space, can interfere with driver enumeration, and occasionally cause irq conflicts.

### msi interrupt mode

for every pci device, the `MSISupported` registry value under `Interrupt Management\MessageSignaledInterruptProperties` is set to `1`.

**why:** there are two ways a device can interrupt the cpu: legacy irq (a shared wire-based signal, often shared between multiple devices) or msi (a memory-write operation that the device performs to a specific address, delivering a cpu interrupt). msi is strictly superior: it's not shared (eliminates spurious interrupt conflicts), it delivers more information (the interrupt carries data about which specific event occurred), and it has lower latency. windows doesn't enable msi for all devices by default.

### disk write cache

**`UserWriteCacheSetting`** → `1`
**`CacheIsPowerProtected`** → `1`
**`EnablePowerManagement`** → `0`

write cache enabled: the disk controller buffers writes in ram and acknowledges them to the os before they're committed to flash. this dramatically improves write throughput and reduces write latency. `CacheIsPowerProtected=1` tells windows that the drive has capacitors or battery backup to flush the cache on power loss (modern nvme drives do, or the risk is acceptable).

### exploit guard & spectre/meltdown

`Set-ProcessMitigation -SYSTEM -Disable [all]` disables system-wide process mitigations including:

```
dep · aslr · cfg · cet · sehop · heap terminate · export address filter
import address filter · rop stack pivot · rop caller check · rop simulate exec
```

spectre/meltdown kernel patches:
```
FeatureSettingsOverride     = 3
FeatureSettingsOverrideMask = 3
```

these are real security mitigations. disabling them removes protections against specific hardware vulnerability classes. on a machine that runs only trusted software and doesn't handle sensitive data, the performance recovery (typically 5-15% in cpu-bound scenarios) justifies this. on any machine used for banking, sensitive work, or running untrusted code, do not disable these.

ifeo mitigation payloads for critical processes (`fontdrvhost.exe`, `dwm.exe`, `lsass.exe`, `svchost.exe`, `winlogon.exe`, `csrss.exe`, `audiodg.exe`, `services.exe`, `explorer.exe`, `taskhostw.exe`, `sihost.exe`) are set to zeroed binary payloads — effectively disabling per-process mitigation overhead for processes that run continuously.

---

## phase 11 — filesystem & boot

### ntfs behavior

```
8.3 names     → disabled   (every file write no longer creates a short 8.3 alias)
delete notify → enabled    (trim: notifies ssd of freed blocks — keep on)
last access   → disabled   (stops updating the "last accessed" timestamp on reads)
memory usage  → 1          (ntfs cache: paged pool, not non-paged — frees up kernel memory)
```

**8.3 names:** the 8.3 filename format (e.g. `PROGRA~1` for `Program Files`) is a DOS-era compatibility feature. windows creates a short alias for every file. this doubles the metadata write for every file creation operation. no modern software requires 8.3 names.

**last access:** by default, windows updates the last-accessed timestamp on every file read. this converts read operations into read+write operations at the filesystem level. disabling it means reads are pure reads — no metadata update, no write amplification.

### bcdedit

```
timeout     = 10       (boot menu shows for 10s)
bootux      = disabled (no animated windows logo during boot)
bootmenu    = legacy   (shows boot options in text mode, not graphical)
quietboot   = yes      (suppresses boot progress messages)
description = Albus 6.2
```

`deletevalue useplatformclock` and `deletevalue useplatformtick` — removes overrides that force windows to use the platform clock (hpet/acpi) for timer resolution. the default (removing the override) lets the kernel choose the best available timer source, which on modern systems is typically the tsc (time stamp counter) — lower latency and more precise.

`tscsyncpolicy = Default` — lets the kernel negotiate tsc synchronization across cores automatically.

global settings custom flags `16000067`, `16000069`, `16000068` enable additional boot optimizations related to pre-launch environment initialization.

---

## phase 12 — albusx service

documented separately in the section below.

---

## phase 13 — debloat

### edge removal

edge's uninstaller is wrapped in a consent and environment check that prevents it from running in contexts it doesn't expect. albus bypasses this:

```
1. clear NoRemove registry key (re-enables the uninstaller)
2. set AllowUninstall = 1 in EdgeUpdateDev
3. create a fake MicrosoftEdge.exe in SystemApps (satisfies installer env check)
4. spoof sihost.exe path to cmd.exe (satisfies process context check)
5. invoke setup.exe --force-uninstall --delete-profile
6. remove edge update and webview2 via same mechanism
7. apply group policy to prevent reinstallation via windows update
```

webview2 is kept available for reinstallation (`Install{F3017226...}=1`) because some system components (certain settings pages, office applications) use it as their rendering engine. edge browser itself is fully gone.

### onedrive removal

per-user uninstall via registry uninstall string (found in `HKU\{SID}\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe`). fallback to system paths (`System32\OneDriveSetup.exe`, `SysWOW64\OneDriveSetup.exe`). appx package removed for all users. the `{018D5C66-4533-4307-9B53-224DE2ED1FE6}` namespace tree entry (the "onedrive" entry in the file explorer sidebar) is hidden.

### uwp packages removed

everything except:

```
Microsoft.Paint                          Microsoft.WindowsNotepad
Microsoft.WindowsStore                   Microsoft.ImmersiveControlPanel
Microsoft.Windows.Photos                 Microsoft.SecHealthUI
Microsoft.Windows.ShellExperienceHost    Microsoft.Windows.StartMenuExperienceHost
Microsoft.AV1VideoExtension              Microsoft.AVCEncoderVideoExtension
Microsoft.HEIFImageExtension             Microsoft.HEVCVideoExtension
Microsoft.MPEG2VideoExtension            Microsoft.VP9VideoExtensions
Microsoft.WebMediaExtensions             Microsoft.WebpImageExtension
Microsoft.RawImageExtension
```

the codec extensions are kept because they enable playback of modern video formats in media player and file explorer preview. removing them silently breaks thumbnails and video playback.

### telemetry binary neutralization

```
CompatTelRunner.exe         → CompatTelRunner.exe.bak
DeviceCensus.exe            → DeviceCensus.exe.bak
AggregatorHost.exe          → AggregatorHost.exe.bak
wsqmcons.exe                → wsqmcons.exe.bak
WerFault.exe                → WerFault.exe.bak
WerFaultSecure.exe          → WerFaultSecure.exe.bak
wermgr.exe                  → wermgr.exe.bak
DiagnosticsHub...Service.exe → ...exe.bak
omadmclient.exe             → omadmclient.exe.bak
```

**why rename instead of delete:** system files are protected by windows resource protection. deletion requires taking ownership and can trigger integrity checks. renaming to `.bak` achieves the same effect (the binary cannot execute) without triggering protection mechanisms.

### dism cleanup

component store (`WinSxS`) cleaned and superfluous packages stripped. dism packages matching `DiagTrack`, `Telemetry`, `CEIP`, `Cortana`, `AI-MachineLearning`, `BioEnrollment`, `Holographic`, `QuickAssist`, `StepsRecorder` removed if present.

winsxs manifests matching `*diagtrack*`, `*telemetry*`, `*ceip*`, `*diaghub*`, `*wer*` renamed to `.bak` — prevents these components from being reinstalled by component-based servicing.

---

## phase 14 — startup cleanup

all entries in:

```
HKCU\...\Run       HKCU\...\RunOnce
HKLM\...\Run       HKLM\...\RunOnce
HKLM\WOW6432Node\...\Run
HKLM\WOW6432Node\...\RunOnce
```

cleared. startup folders emptied:

```
%AppData%\Microsoft\Windows\Start Menu\Programs\Startup
%ProgramData%\Microsoft\Windows\Start Menu\Programs\StartUp
```

**why:** software installers liberally add startup entries. over time, a fresh windows install accumulates a dozen or more processes launching at logon — many of which are update checkers and telemetry agents for software you installed once and forgot. clearing all of them means only what you explicitly add back will run.

---

## albusx — native service deep dive

albusx is a c# windows service compiled at runtime from `albus.cs` using the .net framework `csc.exe` compiler. it runs as `LocalSystem`, starts automatically at boot, and recovers from crashes (5s → 10s → 30s restart delays).

### architecture

```
AlbusBService (ServiceBase)
    │
    ├── CpuTopology.Detect()
    │       └── GetSystemCpuSetInformation() → maps all logical cpus
    │           identifies efficiency classes (p-core vs e-core)
    │           builds PCoreMask (one logical per physical p-core)
    │           builds AllPCoreMask (all logical p-cores)
    │           identifies best NUMA node
    │
    ├── SetSelfPriority()    → ProcessPriorityClass.RealTime
    ├── SetSelfAffinity()    → pinned to PCoreMask, ideal core set
    ├── DisableThrottling()  → EcoQoS off for this process
    ├── AcquireLargePagePrivilege()
    ├── SetMemoryPriority()  → MEMORY_PRIORITY_NORMAL (highest) + NUMA large page alloc
    ├── DisableCStates()     → CallNtPowerInformation(ProcessorIdleDomains)
    ├── TuneScheduler()      → short variable quantum, dpc watchdog off
    ├── BoostGpuPriority()   → D3DKMTSetProcessSchedulingPriority(REALTIME)
    ├── OptimizeGpuIrqAffinity()  → gpu irq routed to physical core 2
    ├── OptimizeNicIrqAffinity()  → nic irq routed to physical core 1
    ├── SetResolutionVerified()   → NtSetTimerResolution to hardware max
    ├── PurgeStandbyList()
    ├── GhostMemory()
    │
    ├── Timer: guard (8s)      → drift correction
    ├── Timer: purge (4min)    → standby list purge when ram < 1GB
    ├── Timer: watchdog (8s)   → priority/affinity/timer integrity
    ├── Timer: health (10min)  → jitter measurement, auto-rearm
    │
    ├── Thread: audio          → IAudioClient3 minimum buffer per endpoint
    ├── Thread: etw/wmi        → process watch (optional, ini-triggered)
    └── FileSystemWatcher      → ini hot-reload
```

### 1 — timer resolution

```
NtQueryTimerResolution → min, max, current (100ns units)

typical values:
  min     = 156001  (15.6ms  — coarsest, lowest cpu overhead)
  max     = 5000    (0.5ms   — finest, highest cpu overhead)
  default = 156001

NtSetTimerResolution(5000, true) → requests 0.5ms
```

windows timer resolution controls how often the kernel's scheduler wakes up to re-evaluate which thread should run. at 15.6ms (default), the scheduler checks in every 15.6ms. at 0.5ms, it checks every 0.5ms.

for a game running at 500+ fps, the scheduler needs to wake up far more frequently than every 15.6ms to keep the render loop fed. at 0.5ms resolution, the cpu is given an opportunity to service the game's threads 2000 times per second instead of 64 — significantly reducing the time between a frame being ready to render and the gpu actually receiving it.

**important note on windows 11:** starting with windows 11 22h2, timer resolution is per-process rather than global. `NtSetTimerResolution` called by albusx sets the resolution for its own process. games that do not call it themselves run at default resolution unless a compatibility setting exists. this is a deliberate microsoft design change. albusx sets `GlobalTimerResolutionRequests=1` in the kernel session manager key to restore the windows 10 global behavior.

**verification loop:**
```
for 50 iterations:
    NtQueryTimerResolution → read actual current value
    if current ≤ target + 50 units: done
    SpinWait(10000)
    NtSetTimerResolution → re-apply
```

**guard timer (8s interval):** queries current resolution and re-applies if it has drifted above target. this handles third-party software that quietly resets resolution after albusx sets it.

### 2 — process watch mode

if `AlbusX.exe.ini` exists:

```ini
cs2.exe
r5apex.exe
resolution=5000
```

the service switches from always-on to event-driven:

```
ETW (EventTrace) → opens "NT Kernel Logger"
    process start event (id=1) fires
    → check image name against list
    → if match: arm resolution + boost + purge
    → OpenProcess(SYNCHRONIZE) + WaitForSingleObject(∞)
    → process exits → restore resolution + un-boost + purge

fallback: WMI __InstanceCreationEvent (2s poll) if ETW unavailable
wmi watcher auto-restarts on disconnect (5 retries, 3s delay)
```

**ini hot-reload:** `FileSystemWatcher` monitors the ini file for writes. any change rebuilds the process list, recalculates target resolution, and rebuilds the etw/wmi watcher — no service restart needed.

### 3 — standby list purge

```csharp
SetSystemFileCacheSize(-1, -1, 0)

// clears the system file cache — pages backing files that are
// no longer mapped get freed immediately instead of sitting
// on the standby list

NtSetSystemInformation(80, ref 4, 4)

// class 80 = SystemMemoryListInformation
// command 4 = MemoryPurgeStandbyList
// flushes modified and standby page lists — reclaims physical
// ram occupied by pages that are technically "free" but haven't
// been returned to the free list yet
```

**periodic purge:** fires every 4 minutes. reads `PerformanceCounter("Memory", "Available MBytes")`. only purges if available ram < 1024mb — avoids thrashing on systems with ample ram where standby pages serve as an effective file cache.

### 4 — cpu topology detection

```
GetSystemCpuSetInformation() → returns per-logical-cpu data:
    struct SYSTEM_CPU_SET_INFORMATION {
        uint  Size
        uint  Type
        uint  Id
        uint  Group
        byte  LogicalProcessorIndex   ← offset 14
        byte  CoreIndex               ← offset 20
        byte  LastLevelCacheIndex
        byte  NumaNodeIndex           ← offset 19
        byte  EfficiencyClass         ← offset 18
        ...
    }
```

the efficiency class field distinguishes p-cores (class 1 on intel, class 0 on uniform systems) from e-cores (class 0 on intel). albusx builds two masks:

```
PCoreMask    = one logical cpu per physical p-core
               (avoids hyperthreading siblings, reduces cross-core latency)

AllPCoreMask = all logical cpus on p-cores
               (used for game processes where ht siblings are acceptable)
```

**numa node detection:** identifies the numa node with the most p-cores. on multi-socket systems, memory and cache latency is much lower for accesses within the same numa node. the service pins itself and allocates its working memory to the best node.

**>64 core handling:** the affinity mask api is limited to 64 bits (one per logical cpu). systems with more than 64 cpus require `GROUP_AFFINITY` structures. albusx detects this, logs a warning, and operates on the first 64 cpus.

### 5 — irq affinity routing

**gpu irq → physical core 2:**

```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-...}\0000\
    Interrupt Management\Affinity Policy\
        AssignmentSetOverride = [cpu mask bytes]
        DevicePolicy          = 4 (IrqPolicySpecifiedProcessors)
```

after writing the registry, `SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, ...)` is invoked to disable and re-enable the device — this is the only reliable way to make irq affinity changes take effect without a reboot.

**nic irq → physical core 1:**

same mechanism, applied to `{4D36E972-...}` (network adapters). virtual adapters (vpn, hyper-v, vmware, bluetooth, tap, isatap, teredo) are filtered out by checking `DriverDesc`, `DeviceDesc`, and `Description` registry values for keywords.

**original values are saved** and restored on service stop — irq assignments return to windows defaults when albusx stops.

**why specific cores?**

```
core 0: albusx service (pinned)
core 1: nic irq handler
core 2: gpu irq handler
remaining p-cores: game process + all p-core siblings
```

this prevents nic and gpu interrupts from landing on the same core as the game's main render thread. an irq arriving on a core preempts whatever is running — if the game's render thread is on core 3 and a nic irq arrives on core 3, the render thread is paused for the interrupt handler duration. routing irqs to dedicated cores eliminates this.

### 6 — gpu priority

```csharp
// resolve at runtime — not available via standard p/invoke
IntPtr hGdi32 = LoadLibraryW("gdi32.dll");
IntPtr fn = GetProcAddress(hGdi32, "D3DKMTSetProcessSchedulingPriority");
delegate int D3DKMTPrioDelegate(IntPtr hProcess, int priority);
_d3dkmtPrio = Marshal.GetDelegateForFunctionPointer(fn, ...);

// invoke
_d3dkmtPrio(Process.GetCurrentProcess().Handle, 5 /* REALTIME */);
```

`D3DKMTSetProcessSchedulingPriority` is an undocumented kernel-mode driver entry point exposed through gdi32. it sets the gpu scheduling priority for the calling process at the kernel graphics subsystem level — separate from and more powerful than windows process priority. realtime priority (5) means the gpu scheduler will preempt other processes' gpu work to service this process.

albusx applies this to itself, which keeps its own latency-sensitive operations (timer management, audio client initialization) prioritized. game processes applied in `ApplyProcessOptimizations` receive `High` cpu priority; the game engine itself typically calls this api internally.

### 7 — audio latency minimization

```
CoInitializeEx(COINIT_MULTITHREADED)
IMMDeviceEnumerator.EnumAudioEndpoints(eRender, ACTIVE)

for each endpoint:
    dev.Activate(IAudioClient3)
    client.GetMixFormat() → current mix format (sample rate, channels, bit depth)
    client.GetSharedModeEnginePeriod(fmt)
        → defPeriod   (default engine period, typically 10ms at 48khz = 480 frames)
        → fundPeriod  (fundamental period — minimum granularity)
        → minPeriod   (minimum supported period)
        → maxPeriod

    if minPeriod < defPeriod:
        client.InitializeSharedAudioStream(flags=0, minPeriod, fmt, null)
        client.Start()
```

`IAudioClient3.InitializeSharedAudioStream` is a windows 10 1607+ api that allows the audio engine to operate at its minimum supported buffer size. at 48khz:
- default: 480 frames = 10ms
- minimum: typically 48-128 frames = 1-2.67ms

this reduces audio engine latency from 10ms to ~1-3ms. the audio engine runs on a real-time mmcss thread ("pro audio"), so the smaller buffer is serviced reliably without underruns on a system with good irq latency.

**device hot-swap:** `IMMNotificationClient.OnDefaultDeviceChanged` fires when the default audio device changes (plugging in headphones, switching to hdmi audio, etc.). albusx releases all existing `IAudioClient3` instances and re-initializes them for the new device.

**glitch detector:** a per-device background thread polls `GetCurrentPadding()` every 50ms. if the buffer reports zero padding for two consecutive polls and more than 100ms has elapsed since the last non-zero read, it logs an audio underrun. this is diagnostic only — it doesn't attempt to recover.

### 8 — health monitor

fires every 10 minutes:

```
1. NtQueryTimerResolution → current timer resolution
2. PerformanceCounter("Memory", "Available MBytes")
3. PerformanceCounter("Processor", "% Processor Time", "_Total")
4. measure scheduling jitter:
       for 300 iterations:
           record Stopwatch.GetTimestamp()
           SpinWait(1000)
           record Stopwatch.GetTimestamp()
           keep minimum delta
       jitter_µs = min_delta * 1,000,000 / Stopwatch.Frequency
5. compare jitter to baseline measured at startup
6. if jitter > 3× baseline: trigger full rearm
       SetSelfPriority() + SetSelfAffinity() + DisableCStates() + SetResolutionVerified()
```

jitter measurement quantifies how consistent cpu scheduling actually is. a spike in jitter (measured as the minimum time taken for a tight spin loop) indicates something in the system is preempting the measurement thread — typically an irq that landed on the wrong core, a c-state transition, or another process at realtime priority.

### 9 — self-optimization

```
ProcessPriorityClass.RealTime
Thread.Priority = Highest
SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)  (15)
SetThreadIdealProcessor → first p-core in PCoreMask
ProcessorAffinity = PCoreMask
GCSettings.LatencyMode = SustainedLowLatency
ThreadPool.SetMinThreads(32, 16)
AvSetMmThreadCharacteristics("Pro Audio")
SetProcessInformation(PROCESS_POWER_THROTTLING → off)
SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
SetProcessWorkingSetSizeEx(16MB min, 256MB max, HARDWS_MIN_ENABLE)
EmptyWorkingSet (after init — trim pages not needed at steady state)
VirtualAllocExNuma (4MB large page on best NUMA node)
```

`SustainedLowLatency` gc mode: the .net garbage collector normally performs full blocking collections (gen2) that can pause all managed threads for tens of milliseconds. sustained low latency mode suppresses gen2 blocking collections for as long as possible, running background collections instead. this prevents gc pauses from interfering with the timer guard and watchdog threads.

`HARDWS_MIN_ENABLE`: locks the minimum working set in physical ram. the pages albusx actively uses will never be paged out to disk, regardless of memory pressure.

`VirtualAllocExNuma` with `MEM_LARGE_PAGES`: requests a 4MB allocation backed by 2MB huge pages (on intel) or 1GB pages if available. large pages reduce tlb pressure — the cpu's translation lookaside buffer caches fewer entries to cover the same address range. on a long-running service that accesses the same memory regions repeatedly, this reduces the frequency of tlb misses.

---

## what albus does not touch

- pagefile — size, location, and existence are left to windows defaults
- display drivers (beyond the gpu phase) — color profiles, refresh rate, hdr settings unchanged
- cpu affinity for user applications — games set their own affinity; albusx only applies affinity to processes it detects via the ini watch
- the windows defender antimalware service itself — notifications are removed but scanning continues
- wifi/bluetooth hardware — only driver binding settings, not radio state
- any per-user application data or settings

---

## reverting

albus does not have an undo function. if you need to revert:

- **registry:** the changes are individually documentable via the script. most can be reversed by deleting the written keys or setting values back to windows defaults.
- **services:** `sc config <name> start= auto` re-enables disabled services
- **power plan:** `powercfg /restoredefaultschemes` removes albus and restores the windows built-in plans
- **edge:** reinstall from `https://www.microsoft.com/edge` or via windows update after removing the policy keys
- **onedrive:** reinstall from `https://www.microsoft.com/onedrive`
- **vbs/hvci:** `bcdedit /set hypervisorlaunchtype auto`, then enable in device security settings

the safest full revert is a windows reinstall. which the usb creator makes trivial.

---

## credits

built alongside and informed by work from [FR33THY](https://www.youtube.com/watch?v=JJvW9e4X7k0), [MeetRevision](https://github.com/meetrevision/playbook), and [PC-Tuning](https://github.com/valleyofdoom/PC-Tuning).

---

```
  github  → https://www.github.com/oqullcan/albuswin
  twitter → https://www.x.com/oqullcn
```
