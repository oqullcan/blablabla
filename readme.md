# albus playbook

a windows optimization script. applies registry tweaks, removes bloat, hardens privacy, and installs a native low-latency service — in a single run.

## usage

**playbook**
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex
```
run as administrator. the launcher automatically downloads [minsudo](https://github.com/M2Team/NanaRun), elevates to trustedinstaller, and streams the main script directly into memory — no files left behind.
 
**usb creator**
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/usb.ps1 | iex
```
formats a usb drive with [ventoy](https://github.com/ventoy/Ventoy) and writes a zero-touch `autounattend.xml` that bypasses oobe, disables telemetry at install time, and places an albus shortcut on the desktop. drop your windows iso into the `ISOs` folder and boot.

## what it does

**performance**
- ~400 registry tweaks across shell, privacy, ui, and system behavior
- custom power plan based on ultimate performance — all cores unparked, 100% min/max state
- kernel timer resolution enforced via a compiled native service (albusx)
- hardware-accelerated gpu scheduling, win32priorityseparation tuned for foreground apps
- ntfs optimized — trim enabled, last access disabled, 8.3 names off
- svchost split threshold maximized, msi mode enabled for all pci devices
- memory compression disabled

**privacy**
- all telemetry pipelines blocked — diagtrack, ceip, sqm, wer
- cortana, copilot, recall, and windows ai disabled
- firewall rules added to block diagtrack and wersvc outbound
- telemetry executables (compattelrunner, aggregatorhost, etc.) redirected via ifeo
- advertising id, tailored experiences, and cloud content delivery off
- all settings sync disabled

**debloat**
- edge fully removed — processes, services, registry, update infrastructure
- onedrive uninstalled
- most pre-installed uwp apps removed while keeping core system components
- gameinput, update health tools, braille service, remote desktop client removed
- startup folders and run keys cleared

**network**
- nagle's algorithm disabled per-interface
- tcp auto-tuning restricted, ecn and timestamps disabled
- lso and interrupt moderation disabled on all adapters
- ipv6, lldp, qos, and other unnecessary bindings removed
- adapter power saving and wake-on-lan fully disabled
- wpad, netbios, and dns negative cache reduced

**software** *(requires internet)*
- brave browser, 7-zip, visual c++ runtimes, directx end-user runtime

**gpu drivers** *(interactive)*
- nvidia — extracts, strips telemetry components, silent install, applies nvidia profile inspector profile
- amd — patches installer configs, installs, cleans bloat services, applies umd performance settings

## requirements

- windows 10 (19041+) or windows 11 — x64
- powershell 5.1+
- administrator privileges (launcher handles the rest)
- internet connection optional (needed for software downloads)

## notes

- updates are paused for 31 years — resume manually when needed
- edge is fully removed, webview2-dependent apps may be affected
- exploit guard mitigations are disabled system-wide
- bitlocker activation is prevented
- hibernate is disabled

## credits
inspired by and built with help from [FR33THY](https://www.youtube.com/watch?v=JJvW9e4X7k0&t=2711s), [MeetRevision](https://www.github.com/meetrevision/playbook), [PC-Tuning](https://www.github.com/valleyofdoom/PC-Tuning).
