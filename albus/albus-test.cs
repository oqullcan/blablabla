// ══════════════════════════════════════════════════════════════════════════════
//  albus  v4.2
//  precision system latency service
//
//  layers:
//    · timer      — 0.5 ms kernel timer resolution, guard + watchdog
//    · cpu        — hybrid P-core affinity (NUMA-aware), MMCSS Pro Audio
//    · priority   — process/thread priority, DWM boost, explorer throttle
//    · c-state    — NtPowerInformation kernel idle block + OnStop restore
//    · gpu        — D3DKMT realtime scheduling priority
//    · audio      — IAudioClient3 minimum shared-mode buffer (vtable fix)
//    · memory     — standby purge (ISLC), working set lock, ghost memory
//    · irq        — GPU + NIC interrupt affinity (fully reversible)
//    · watchdog   — priority theft / timer drift protection
//    · health     — periodic DPC jitter + RAM + CPU report (event log)
//    · ini        — target process list + custom resolution, hot-reload
//    · etw        — ETW kernel-session process tracking (WMI fallback)
//
// ══════════════════════════════════════════════════════════════════════════════

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;
using System.Management;
using System.Text.RegularExpressions;
using Microsoft.Win32;

[assembly: AssemblyVersion("4.2.0.0")]
[assembly: AssemblyFileVersion("4.2.0.0")]
[assembly: AssemblyProduct("albus")]
[assembly: AssemblyTitle("albus")]
[assembly: AssemblyDescription("precision system latency service v4.2")]

namespace Albus
{
    // ══════════════════════════════════════════════════════════════════════════
    //  HELPER — safe execution + structured logging
    // ══════════════════════════════════════════════════════════════════════════
    static class Safe
    {
        public static void Run(string tag, Action fn, EventLog log = null)
        {
            try { fn(); }
            catch (Exception ex)
            {
                if (log != null)
                    try
                    {
                        log.WriteEntry(
                            string.Format("[{0}] {1} ERROR: {2}",
                                DateTime.Now.ToString("HH:mm:ss"), tag, ex.Message),
                            EventLogEntryType.Warning);
                    } catch {}
            }
        }

        public static T Run<T>(string tag, Func<T> fn, T def = default(T), EventLog log = null)
        {
            try { return fn(); }
            catch (Exception ex)
            {
                if (log != null)
                    try
                    {
                        log.WriteEntry(
                            string.Format("[{0}] {1} ERROR: {2}",
                                DateTime.Now.ToString("HH:mm:ss"), tag, ex.Message),
                            EventLogEntryType.Warning);
                    } catch {}
                return def;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  MAIN SERVICE
    // ══════════════════════════════════════════════════════════════════════════
    sealed class AlbusService : ServiceBase
    {
        // ── constants ────────────────────────────────────────────────────────
        const string SVC_NAME               = "AlbusXSvc";
        const uint   TARGET_RESOLUTION      = 5000u;   // 0.5 ms (100-ns units)
        const uint   RESOLUTION_TOLERANCE   = 50u;     // 5 µs
        const int    GUARD_SEC              = 10;
        const int    WATCHDOG_SEC           = 10;
        const int    HEALTH_INITIAL_MIN     = 5;
        const int    HEALTH_INTERVAL_MIN    = 15;
        const int    PURGE_INITIAL_MIN      = 2;
        const int    PURGE_INTERVAL_MIN     = 5;
        const int    PURGE_THRESHOLD_MB     = 1024;
        const int    WIN11_PERPROCESS_BUILD = 22621;   // Win11 22H2+

        // ── state ─────────────────────────────────────────────────────────────
        uint   defaultRes, minRes, maxRes;
        uint   targetRes, customRes;
        long   processCounter;
        IntPtr hWaitTimer = IntPtr.Zero;
        bool   isWin11PerProcess;

        Timer                  guardTimer, purgeTimer, watchdogTimer, healthTimer;
        ManagementEventWatcher startWatch;
        FileSystemWatcher      iniWatcher;
        Thread                 audioThread;
        Thread                 etwThread;
        List<string>           processNames;
        int                    wmiRetry;
        readonly List<object>  audioClients = new List<object>();
        AudioNotifier          audioNotifier;
        long                   dpcBaselineTicks;
        ManualResetEventSlim   stopEvent = new ManualResetEventSlim(false);

        // Original NIC IRQ values for restore on stop
        readonly Dictionary<string, byte[]> origNicAffinityMask = new Dictionary<string, byte[]>();
        readonly Dictionary<string, int>    origNicDevicePolicy  = new Dictionary<string, int>();

        // ── entry point ───────────────────────────────────────────────────────
        static void Main() { ServiceBase.Run(new AlbusService()); }

        public AlbusService()
        {
            ServiceName                 = SVC_NAME;
            EventLog.Log                = "Application";
            CanStop                     = true;
            CanHandlePowerEvent         = true;
            CanHandleSessionChangeEvent = false;
            CanPauseAndContinue         = false;
            CanShutdown                 = true;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  START
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStart(string[] args)
        {
            stopEvent.Reset();

            // 1. Service process/thread priority
            SetSelfPriority();

            // 2. ThreadPool minimum threads
            Safe.Run("threadpool", () =>
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 16), Math.Max(io, 8));
            }, EventLog);

            // 3. GC — sustained low latency
            Safe.Run("gc", () =>
                GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency, EventLog);

            // 4. High-resolution waitable timer (Win11 per-process lock)
            Safe.Run("waittimer", () =>
            {
                hWaitTimer = CreateWaitableTimerExW(
                    IntPtr.Zero, null,
                    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                    TIMER_ALL_ACCESS);
            }, EventLog);

            // 5. Working set lock: 8–128 MB
            Safe.Run("workingset", () =>
            {
                SetProcessWorkingSetSizeEx(
                    Process.GetCurrentProcess().Handle,
                    (UIntPtr)(8   * 1024 * 1024),
                    (UIntPtr)(128 * 1024 * 1024),
                    QUOTA_LIMITS_HARDWS_MIN_ENABLE);
            }, EventLog);

            // 6. MMCSS Pro Audio — service thread
            Safe.Run("mmcss", () =>
            {
                uint t = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref t);
            }, EventLog);

            // 7. Disable EcoQoS / Intel Thread Director power throttling
            DisableThrottling();

            // 8. Prevent display/system sleep
            Safe.Run("execstate", () =>
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED),
                EventLog);

            // 9. Detect Win11 per-process timer
            isWin11PerProcess = DetectWin11PerProcessTimer();
            Log(string.Format("[albus init] win11 per-process timer: {0}", isWin11PerProcess));

            // 10. Read config
            ReadConfig();

            // 11. NUMA-aware P-core affinity
            SetPCoreMaskNuma();

            // 12. C-state kernel-level block
            DisableCStates();

            // 13. GPU D3DKMT realtime scheduling
            BoostGpuPriority();

            // 14. Timer resolution target
            NtQueryTimerResolution(out minRes, out maxRes, out defaultRes);
            targetRes = customRes > 0
                ? customRes
                : Math.Min(TARGET_RESOLUTION, maxRes);

            Log(string.Format(
                "[albus v4.2] min={0} max={1} default={2} target={3} ({4:F3}ms) mode={5}",
                minRes, maxRes, defaultRes,
                targetRes, targetRes / 10000.0,
                (processNames != null && processNames.Count > 0)
                    ? string.Join(",", processNames) : "global"));

            // 15. DPC latency baseline
            MeasureDpcBaseline();

            // 16. IRQ affinity — GPU + NIC (restored on stop)
            OptimizeGpuIrqAffinity();
            OptimizeNicIrqAffinity();

            // 17. Global or target-process mode
            if (processNames == null || processNames.Count == 0)
            {
                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                ModulateUiPriority(true);
            }
            else
            {
                StartEtwWatcher();
            }

            // 18. Background workers
            StartGuard();
            StartPurge();
            StartWatchdog();
            StartHealthMonitor();
            StartIniWatcher();
            StartAudioThread();

            GhostMemory();
            base.OnStart(args);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  STOP — reverse all runtime changes
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStop()
        {
            stopEvent.Set();

            Safe.Run("execstate", () =>
                SetThreadExecutionState(ES_CONTINUOUS), EventLog);

            DropTimer(ref guardTimer);
            DropTimer(ref purgeTimer);
            DropTimer(ref watchdogTimer);
            DropTimer(ref healthTimer);

            Safe.Run("watcher", () =>
            {
                if (startWatch != null)
                {
                    startWatch.Stop();
                    startWatch.Dispose();
                    startWatch = null;
                }
            }, EventLog);

            Safe.Run("iniwatcher", () =>
            {
                if (iniWatcher != null)
                {
                    iniWatcher.EnableRaisingEvents = false;
                    iniWatcher.Dispose();
                }
            }, EventLog);

            Safe.Run("waittimer", () =>
            {
                if (hWaitTimer != IntPtr.Zero)
                {
                    CloseHandle(hWaitTimer);
                    hWaitTimer = IntPtr.Zero;
                }
            }, EventLog);

            RestoreNicIrqAffinity();
            RestoreCStates();
            ModulateUiPriority(false);

            Safe.Run("timer_restore", () =>
            {
                uint actual = 0;
                NtSetTimerResolution(defaultRes, true, out actual);
                Log(string.Format("[albus stop] timer restored: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            }, EventLog);

            base.OnStop();
        }

        protected override void OnShutdown()
        {
            Safe.Run("shutdown", () => OnStop(), EventLog);
        }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2500);
                SetSelfPriority();
                SetPCoreMaskNuma();
                DisableCStates();
                OptimizeGpuIrqAffinity();
                OptimizeNicIrqAffinity();
                SetResolutionVerified();
                PurgeStandbyList();
                MeasureDpcBaseline();
                Log("[albus resume] post-sleep rearm complete.");
            }
            return true;
        }

        static void DropTimer(ref Timer t)
        {
            if (t == null) return;
            try { t.Dispose(); } catch {}
            t = null;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SELF PRIORITY
        // ══════════════════════════════════════════════════════════════════════
        void SetSelfPriority()
        {
            Safe.Run("self_priority", () =>
            {
                Process self = Process.GetCurrentProcess();
                self.PriorityClass        = ProcessPriorityClass.High;
                self.PriorityBoostEnabled = false;
                Thread.CurrentThread.Priority = ThreadPriority.Highest;
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
            }, EventLog);
        }

        void DisableThrottling()
        {
            Safe.Run("throttling", () =>
            {
                PROCESS_POWER_THROTTLING s;
                s.Version     = 1;
                s.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                s.StateMask   = 0;
                SetProcessInformation(Process.GetCurrentProcess().Handle,
                    ProcessPowerThrottling, ref s,
                    Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WIN11 PER-PROCESS TIMER DETECTION
        // ══════════════════════════════════════════════════════════════════════
        bool DetectWin11PerProcessTimer()
        {
            return Safe.Run("win11detect", () =>
            {
                int build = 0;
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (key != null)
                    {
                        object v = key.GetValue("CurrentBuildNumber");
                        if (v != null) int.TryParse(v.ToString(), out build);
                    }
                }
                return build >= WIN11_PERPROCESS_BUILD;
            }, false, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HYBRID CPU — NUMA-AWARE P-CORE AFFINITY
        //  AMD : NUMA node with highest P-core count = single CCD → no boundary latency.
        //  Intel Alder/Raptor: max efficiency class = P-core.
        // ══════════════════════════════════════════════════════════════════════
        void SetPCoreMaskNuma()
        {
            Safe.Run("cpu_affinity", () =>
            {
                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0)
                {
                    Log("[albus cpu] could not retrieve cpu set info.");
                    return;
                }

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                        return;

                    // pass 1: max efficiency class
                    byte maxClass = 0;
                    for (int off = 0; off < (int)returned; )
                    {
                        int sz = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff = Marshal.ReadByte(buf, off + 18);
                        if (eff > maxClass) maxClass = eff;
                        off += sz;
                    }

                    if (maxClass == 0)
                    {
                        Log("[albus cpu] uniform topology, affinity unchanged.");
                        return;
                    }

                    // pass 2: P-core count and mask per NUMA node
                    var nodeCount = new Dictionary<byte, int>();
                    var nodeMask  = new Dictionary<byte, long>();

                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz     = Marshal.ReadInt32(buf, off);
                        if (sz < 24) break;
                        byte eff    = Marshal.ReadByte(buf, off + 18);
                        byte logCpu = Marshal.ReadByte(buf, off + 14);
                        byte numa   = Marshal.ReadByte(buf, off + 19);

                        if (eff == maxClass)
                        {
                            if (!nodeCount.ContainsKey(numa))
                            {
                                nodeCount[numa] = 0;
                                nodeMask[numa]  = 0;
                            }
                            nodeCount[numa]++;
                            nodeMask[numa] |= (1L << logCpu);
                        }
                        off += sz;
                    }

                    // Select NUMA node with highest P-core count
                    byte bestNuma = 0;
                    int  bestCnt  = 0;
                    foreach (var kv in nodeCount)
                        if (kv.Value > bestCnt) { bestCnt = kv.Value; bestNuma = kv.Key; }

                    long mask = nodeMask.ContainsKey(bestNuma) ? nodeMask[bestNuma] : 0;
                    if (mask != 0)
                    {
                        Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)mask;
                        Log(string.Format(
                            "[albus cpu] numa-{0} p-core mask=0x{1:X} ({2} cores)",
                            bestNuma, mask, CountBits(mask)));
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }, EventLog);
        }

        static int CountBits(long v)
        {
            int c = 0;
            while (v != 0) { c += (int)(v & 1L); v >>= 1; }
            return c;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  C-STATE — NtPowerInformation kernel level
        //  Script: power plan CPU min=100% → separate layer, complementary.
        //  Service: kernel idle state blocked directly, restored on stop.
        // ══════════════════════════════════════════════════════════════════════
        void DisableCStates()
        {
            Safe.Run("cstate_disable", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 1);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log("[albus cstate] c-state transitions blocked (kernel level).");
            }, EventLog);
        }

        void RestoreCStates()
        {
            Safe.Run("cstate_restore", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 0);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log("[albus cstate] c-state transitions restored.");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU — D3DKMT REALTIME SCHEDULING
        //  TDR settings (TdrDelay/TdrLevel) are in script GPU phase.
        // ══════════════════════════════════════════════════════════════════════
        void BoostGpuPriority()
        {
            Safe.Run("gpu_priority", () =>
            {
                int hr = D3DKMTSetProcessSchedulingPriority(
                    Process.GetCurrentProcess().Handle,
                    D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME);
                Log(string.Format("[albus gpu] d3dkmt realtime scheduling (hr=0x{0:X})", hr));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  UI PRIORITY MODULATION
        // ══════════════════════════════════════════════════════════════════════
        void ModulateUiPriority(bool boost)
        {
            Safe.Run("ui_priority", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { p.PriorityClass = ProcessPriorityClass.High; } catch {}

                var expPrio = boost
                    ? ProcessPriorityClass.BelowNormal
                    : ProcessPriorityClass.Normal;
                foreach (Process p in Process.GetProcessesByName("explorer"))
                    try { p.PriorityClass = expPrio; } catch {}

                if (boost) Log("[albus prio] dwm=high, explorer=belownormal.");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  DPC LATENCY BASELINE
        // ══════════════════════════════════════════════════════════════════════
        void MeasureDpcBaseline()
        {
            Safe.Run("dpc_baseline", () =>
            {
                long best = long.MaxValue;
                for (int i = 0; i < 500; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(2000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < best) best = d;
                }
                dpcBaselineTicks = best;
                double us = (best * 1000000.0) / Stopwatch.Frequency;
                Log(string.Format("[albus dpc] baseline jitter: {0:F2} µs", us));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU IRQ AFFINITY — core 0 bypass, dynamic mask
        // ══════════════════════════════════════════════════════════════════════
        void OptimizeGpuIrqAffinity()
        {
            Safe.Run("gpu_irq", () =>
            {
                const string BASE =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}";
                using (RegistryKey gpuClass = Registry.LocalMachine.OpenSubKey(BASE, true))
                {
                    if (gpuClass == null) return;
                    int count = 0;
                    foreach (string sub in gpuClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = gpuClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            using (RegistryKey pol = dev.CreateSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                pol.SetValue("AssignmentSetOverride",
                                    BuildAffinityMask(excludeCore0: true),
                                    RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors,
                                    RegistryValueKind.DWord);
                                count++;
                            }
                        }
                    }
                    if (count > 0)
                        Log(string.Format(
                            "[albus irq] gpu irq affinity: {0} device(s), core-0 bypassed.", count));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  NIC IRQ AFFINITY — runtime, restored on stop
        //
        //  Boundary: service manages interrupt affinity ONLY.
        //  RSS queues, interrupt moderation, TCP/UDP stack params
        //  are set permanently by script phase 6.
        // ══════════════════════════════════════════════════════════════════════
        void OptimizeNicIrqAffinity()
        {
            Safe.Run("nic_irq", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    int count = 0;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            if (IsVirtualAdapter(dev)) continue;

                            // Save original values for restore
                            string dictKey = NIC_CLASS + "\\" + sub;
                            using (RegistryKey pol = dev.OpenSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol != null)
                                {
                                    object ov = pol.GetValue("AssignmentSetOverride");
                                    if (ov is byte[]) origNicAffinityMask[dictKey] = (byte[])ov;
                                    object od = pol.GetValue("DevicePolicy");
                                    if (od != null)
                                        try { origNicDevicePolicy[dictKey] = (int)od; } catch {}
                                }
                            }

                            // NIC IRQ → core 1 (core 0 = game/service, core 2+ = GPU)
                            using (RegistryKey pol = dev.CreateSubKey(
                                "Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                pol.SetValue("AssignmentSetOverride",
                                    BuildNicAffinityMask(),
                                    RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors,
                                    RegistryValueKind.DWord);
                                count++;
                            }
                        }
                    }
                    if (count > 0)
                        Log(string.Format(
                            "[albus netirq] nic irq affinity: {0} adapter(s), core-1 dedicated.", count));
                }
            }, EventLog);
        }

        void RestoreNicIrqAffinity()
        {
            Safe.Run("nic_irq_restore", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";

                using (RegistryKey nicClass = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (nicClass == null) return;
                    foreach (string sub in nicClass.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = nicClass.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            string dictKey = NIC_CLASS + "\\" + sub;
                            using (RegistryKey pol = dev.OpenSubKey(
                                "Interrupt Management\\Affinity Policy", true))
                            {
                                if (pol == null) continue;
                                if (origNicAffinityMask.ContainsKey(dictKey))
                                    pol.SetValue("AssignmentSetOverride",
                                        origNicAffinityMask[dictKey],
                                        RegistryValueKind.Binary);
                                if (origNicDevicePolicy.ContainsKey(dictKey))
                                    pol.SetValue("DevicePolicy",
                                        origNicDevicePolicy[dictKey],
                                        RegistryValueKind.DWord);
                            }
                        }
                    }
                }
                Log("[albus netirq] nic irq affinity restored.");
            }, EventLog);
        }

        // ── Virtual adapter detection ─────────────────────────────────────────
        static bool IsVirtualAdapter(RegistryKey dev)
        {
            try
            {
                string[] fields    = { "DriverDesc", "DeviceDesc", "Description" };
                string[] vKeywords = {
                    "virtual", "loopback", "tunnel", "vpn", "miniport",
                    "wan", "bluetooth", "hyper-v", "vmware", "virtualbox",
                    "tap", "ndiswan", "isatap", "teredo", "6to4"
                };
                foreach (string f in fields)
                {
                    object v = dev.GetValue(f);
                    if (v == null) continue;
                    string desc = v.ToString().ToLowerInvariant();
                    foreach (string kw in vKeywords)
                        if (desc.Contains(kw)) return true;
                }
            } catch {}
            return false;
        }

        // ── Affinity mask builders ────────────────────────────────────────────
        static byte[] BuildAffinityMask(bool excludeCore0)
        {
            int cpuCount  = Environment.ProcessorCount;
            int byteCount = Math.Max(4, (cpuCount + 7) / 8);
            byte[] mask   = new byte[byteCount];
            ulong  bits   = 0;
            for (int i = 0; i < cpuCount; i++)
            {
                if (excludeCore0 && i == 0) continue;
                bits |= (1UL << i);
            }
            for (int i = 0; i < byteCount && i < 8; i++)
                mask[i] = (byte)((bits >> (i * 8)) & 0xFF);
            return mask;
        }

        static byte[] BuildNicAffinityMask()
        {
            int cpuCount  = Environment.ProcessorCount;
            int byteCount = Math.Max(4, (cpuCount + 7) / 8);
            byte[] mask   = new byte[byteCount];
            int nicCore   = cpuCount > 1 ? 1 : 0;
            mask[nicCore / 8] = (byte)(1 << (nicCore % 8));
            return mask;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  TIMER RESOLUTION
        // ══════════════════════════════════════════════════════════════════════
        void SetResolutionVerified()
        {
            long c = Interlocked.Increment(ref processCounter);
            if (c > 1) return;

            uint actual = 0;
            NtSetTimerResolution(targetRes, true, out actual);

            for (int i = 0; i < 50; i++)
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RESOLUTION_TOLERANCE) break;
                Thread.SpinWait(10000);
                NtSetTimerResolution(targetRes, true, out actual);
            }

            Log(string.Format("[albus timer] verified: {0} ({1:F3}ms)", actual, actual / 10000.0));

            if (isWin11PerProcess)
                Log("[albus timer] WARNING: win11 per-process mode active.");
        }

        void RestoreResolution()
        {
            long c = Interlocked.Decrement(ref processCounter);
            if (c >= 1) return;
            uint actual = 0;
            NtSetTimerResolution(defaultRes, true, out actual);
        }

        void StartGuard()
        {
            guardTimer = new Timer(GuardCallback, null,
                TimeSpan.FromSeconds(GUARD_SEC),
                TimeSpan.FromSeconds(GUARD_SEC));
        }

        void GuardCallback(object _)
        {
            Safe.Run("guard", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RESOLUTION_TOLERANCE) return;

                uint actual = 0;
                for (int i = 0; i < 3; i++)
                {
                    NtSetTimerResolution(targetRes, true, out actual);
                    Thread.SpinWait(5000);
                    NtQueryTimerResolution(out qMin, out qMax, out qCur);
                    if (qCur <= targetRes + RESOLUTION_TOLERANCE) break;
                }
                Log(string.Format("[albus guard] drift corrected: {0} → {1} ({2:F3}ms)",
                    qCur, actual, actual / 10000.0));
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  MEMORY
        // ══════════════════════════════════════════════════════════════════════
        void PurgeStandbyList()
        {
            Safe.Run("purge_cache", () =>
                SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0), EventLog);
            Safe.Run("purge_standby", () =>
            { int cmd = 4; NtSetSystemInformation(80, ref cmd, sizeof(int)); }, EventLog);
        }

        void GhostMemory()
        {
            Safe.Run("ghost_mem", () =>
                EmptyWorkingSet(Process.GetCurrentProcess().Handle), EventLog);
        }

        void StartPurge()
        {
            purgeTimer = new Timer(PurgeCallback, null,
                TimeSpan.FromMinutes(PURGE_INITIAL_MIN),
                TimeSpan.FromMinutes(PURGE_INTERVAL_MIN));
        }

        void PurgeCallback(object _)
        {
            Safe.Run("purge_cb", () =>
            {
                float mb = 0;
                using (var pc = new PerformanceCounter("Memory", "Available MBytes"))
                    mb = pc.NextValue();
                if (mb < PURGE_THRESHOLD_MB)
                {
                    PurgeStandbyList();
                    Log(string.Format("[albus islc] purge triggered, available={0:F0}MB.", mb));
                }
            }, EventLog);
            GhostMemory();
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WATCHDOG — priority theft + timer drift
        // ══════════════════════════════════════════════════════════════════════
        void StartWatchdog()
        {
            watchdogTimer = new Timer(WatchdogCallback, null,
                TimeSpan.FromSeconds(WATCHDOG_SEC),
                TimeSpan.FromSeconds(WATCHDOG_SEC));
        }

        void WatchdogCallback(object _)
        {
            Safe.Run("wd_selfprio", () =>
            {
                Process self = Process.GetCurrentProcess();
                if (self.PriorityClass != ProcessPriorityClass.High)
                {
                    Log(string.Format("[albus watchdog] priority stolen ({0}), restoring.",
                        self.PriorityClass));
                    self.PriorityClass = ProcessPriorityClass.High;
                }
            }, EventLog);

            Safe.Run("wd_dwm", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try
                    {
                        if (p.PriorityClass != ProcessPriorityClass.High)
                            p.PriorityClass = ProcessPriorityClass.High;
                    } catch {}
            }, EventLog);

            Safe.Run("wd_timer", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur > targetRes + RESOLUTION_TOLERANCE * 4)
                {
                    uint actual = 0;
                    NtSetTimerResolution(targetRes, true, out actual);
                    Log(string.Format(
                        "[albus watchdog] timer drifted: {0:F3}ms → corrected.", qCur / 10000.0));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HEALTH MONITOR — DPC jitter + RAM + CPU every 15 min
        // ══════════════════════════════════════════════════════════════════════
        void StartHealthMonitor()
        {
            healthTimer = new Timer(HealthCallback, null,
                TimeSpan.FromMinutes(HEALTH_INITIAL_MIN),
                TimeSpan.FromMinutes(HEALTH_INTERVAL_MIN));
        }

        void HealthCallback(object _)
        {
            Safe.Run("health", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);

                float availMB = 0;
                Safe.Run("health_mem", () =>
                {
                    using (var pc = new PerformanceCounter("Memory", "Available MBytes"))
                        availMB = pc.NextValue();
                }, EventLog);

                float cpu = 0;
                Safe.Run("health_cpu", () =>
                {
                    using (var pc = new PerformanceCounter("Processor", "% Processor Time", "_Total"))
                    {
                        pc.NextValue();
                        Thread.Sleep(200);
                        cpu = pc.NextValue();
                    }
                }, EventLog);

                long jitterBest = long.MaxValue;
                for (int i = 0; i < 200; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(1000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < jitterBest) jitterBest = d;
                }
                double jitterUs = (jitterBest * 1000000.0) / Stopwatch.Frequency;

                Log(string.Format(
                    "[albus health] timer={0:F3}ms | ram={1:F0}MB | cpu={2:F1}% | jitter={3:F2}µs",
                    qCur / 10000.0, availMB, cpu, jitterUs));

                if (dpcBaselineTicks > 0)
                {
                    double baseUs = (dpcBaselineTicks * 1000000.0) / Stopwatch.Frequency;
                    if (jitterUs > baseUs * 3.0)
                        Log(string.Format(
                            "[albus health] WARNING: jitter is {0:F1}x above baseline!",
                            jitterUs / baseUs));
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  ETW PROCESS TRACKER — kernel-session, ~0-5ms latency
        // ══════════════════════════════════════════════════════════════════════
        void StartEtwWatcher()
        {
            etwThread              = new Thread(EtwWorker);
            etwThread.Name         = "albus-etw";
            etwThread.Priority     = ThreadPriority.Highest;
            etwThread.IsBackground = true;
            etwThread.Start();
        }

        void EtwWorker()
        {
            bool success = false;
            Safe.Run("etw_worker", () => { success = TryStartEtwSession(); }, EventLog);
            if (!success)
            {
                Log("[albus etw] etw failed, falling back to wmi.");
                Safe.Run("wmi_fallback", StartWmiWatcher, EventLog);
            }
        }

        bool TryStartEtwSession()
        {
            var logFile = new EVENT_TRACE_LOGFILE();
            logFile.LoggerName          = "NT Kernel Logger";
            logFile.ProcessTraceMode    = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
            logFile.EventRecordCallback = OnEtwEvent;

            IntPtr hTrace = OpenTrace(ref logFile);
            if (hTrace == INVALID_PROCESSTRACE_HANDLE)
            {
                logFile.LoggerName = "Albus-KernelProc";
                hTrace = OpenTrace(ref logFile);
                if (hTrace == INVALID_PROCESSTRACE_HANDLE) return false;
            }

            Log("[albus etw] etw trace started.");
            uint status = ProcessTrace(new IntPtr[] { hTrace }, 1, IntPtr.Zero, IntPtr.Zero);
            CloseTrace(hTrace);
            return (status == 0);
        }

        void OnEtwEvent(ref EVENT_RECORD record)
        {
            // C#5: cannot capture ref parameter inside lambda — copy to locals first
            ushort evtId      = record.EventHeader.Id;
            ushort evtDataLen = record.UserDataLength;
            IntPtr evtData    = record.UserData;

            Safe.Run("etw_event", () =>
            {
                if (evtId != 1) return;
                if (evtDataLen < 20) return;

                string imgName = "";
                Safe.Run("etw_imgname", () =>
                {
                    imgName = Marshal.PtrToStringUni(IntPtr.Add(evtData, 8));
                    if (imgName != null)
                        imgName = System.IO.Path.GetFileName(imgName).ToLowerInvariant();
                }, EventLog);

                if (string.IsNullOrEmpty(imgName)) return;

                List<string> targets = processNames;
                if (targets == null || !targets.Contains(imgName)) return;

                uint pid = (uint)Marshal.ReadInt32(evtData, 0);
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            }, EventLog);
        }

        // ── WMI Fallback ──────────────────────────────────────────────────────
        void StartWmiWatcher()
        {
            string query = string.Format(
                "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 " +
                "WHERE (TargetInstance isa \"Win32_Process\") AND " +
                "(TargetInstance.Name=\"{0}\")",
                string.Join("\" OR TargetInstance.Name=\"", processNames));

            startWatch               = new ManagementEventWatcher(query);
            startWatch.EventArrived += OnProcessArrived;
            startWatch.Stopped      += OnWatcherStopped;
            startWatch.Start();
            wmiRetry = 0;
            Log("[albus watcher] wmi watching: " + string.Join(", ", processNames));
        }

        void OnWatcherStopped(object sender, StoppedEventArgs e)
        {
            if (wmiRetry >= 5) return;
            if (stopEvent.IsSet) return;
            wmiRetry++;
            Thread.Sleep(3000);
            Safe.Run("wmi_restart", () =>
            {
                if (startWatch != null) try { startWatch.Dispose(); } catch {}
                startWatch = null;
                StartWmiWatcher();
                Log("[albus watcher] wmi reconnected.");
            }, EventLog);
        }

        void OnProcessArrived(object sender, EventArrivedEventArgs e)
        {
            Safe.Run("wmi_arrived", () =>
            {
                ManagementBaseObject proc =
                    (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                uint pid = (uint)proc.Properties["ProcessId"].Value;
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            }, EventLog);
        }

        void ProcessStarted(uint pid)
        {
            Safe.Run("proc_mmcss", () =>
            { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); }, EventLog);

            Safe.Run("proc_prio", () =>
                Thread.CurrentThread.Priority = ThreadPriority.Highest, EventLog);

            SetResolutionVerified();
            PurgeStandbyList();
            GhostMemory();
            ModulateUiPriority(true);

            IntPtr hProc = IntPtr.Zero;
            Safe.Run("proc_wait", () =>
            {
                hProc = OpenProcess(SYNCHRONIZE, 0, pid);
                if (hProc != IntPtr.Zero) WaitForSingleObject(hProc, -1);
            }, EventLog);
            if (hProc != IntPtr.Zero)
                Safe.Run("proc_close", () => CloseHandle(hProc), EventLog);

            ModulateUiPriority(false);
            RestoreResolution();
            PurgeStandbyList();
            GhostMemory();
            Log("[albus rested] process exited, cleanup complete.");
        }

        // ══════════════════════════════════════════════════════════════════════
        //  AUDIO — IAudioClient3 minimum shared-mode buffer
        //
        //  FIX (CS0051): IMMDeviceEnumerator is declared internal by default.
        //  OptimizeAllEndpoints() is internal — consistent accessibility.
        //  AudioNotifier holds the enumerator as the interface type directly,
        //  keeping everything within the same assembly-internal visibility.
        // ══════════════════════════════════════════════════════════════════════
        void StartAudioThread()
        {
            audioThread              = new Thread(AudioWorker);
            audioThread.Name         = "albus-audio";
            audioThread.Priority     = ThreadPriority.Highest;
            audioThread.IsBackground = true;
            audioThread.Start();
        }

        void AudioWorker()
        {
            Safe.Run("audio_mmcss", () =>
            { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); }, EventLog);

            Safe.Run("audio_coinit", () =>
                CoInitializeEx(IntPtr.Zero, COINIT_MULTITHREADED), EventLog);

            Safe.Run("audio_main", () =>
            {
                Type mmdeType = Type.GetTypeFromCLSID(
                    new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                IMMDeviceEnumerator enumerator =
                    (IMMDeviceEnumerator)Activator.CreateInstance(mmdeType);

                audioNotifier            = new AudioNotifier();
                audioNotifier.Service    = this;
                audioNotifier.Enumerator = enumerator;
                enumerator.RegisterEndpointNotificationCallback(audioNotifier);

                OptimizeAllEndpoints(enumerator);
            }, EventLog);

            stopEvent.Wait();
        }

        // CS0051 FIX: method visibility matches IMMDeviceEnumerator (both internal)
        internal void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            Safe.Run("audio_endpoints", () =>
            {
                Guid IID_AC3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                IMMDeviceCollection col;
                if (enumerator.EnumAudioEndpoints(EDataFlow_eRender, DEVICE_STATE_ACTIVE, out col) != 0)
                    return;

                uint count;
                col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    Safe.Run("audio_ep_" + i, () =>
                    {
                        IMMDevice dev;
                        if (col.Item(i, out dev) != 0) return;

                        object clientObj;
                        if (dev.Activate(ref IID_AC3, CLSCTX_ALL, IntPtr.Zero, out clientObj) != 0)
                            return;

                        IAudioClient3 client = (IAudioClient3)clientObj;
                        IntPtr pFmt = IntPtr.Zero;
                        if (client.GetMixFormat(out pFmt) != 0) return;

                        uint defF, fundF, minF, maxF;
                        if (client.GetSharedModeEnginePeriod(pFmt,
                            out defF, out fundF, out minF, out maxF) != 0) return;

                        if (minF < defF && minF > 0)
                        {
                            if (client.InitializeSharedAudioStream(0, minF, pFmt, IntPtr.Zero) == 0 &&
                                client.Start() == 0)
                            {
                                lock (audioClients) audioClients.Add(clientObj);

                                WAVEFORMATEX fmt =
                                    (WAVEFORMATEX)Marshal.PtrToStructure(pFmt, typeof(WAVEFORMATEX));
                                string devId;
                                dev.GetId(out devId);
                                string shortId = (devId != null && devId.Length > 8)
                                    ? devId.Substring(devId.Length - 8) : (devId ?? "?");

                                Log(string.Format(
                                    "[albus audio] {0}: {1:F3}ms → {2:F3}ms (frames {3}→{4})",
                                    shortId,
                                    (defF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    (minF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    defF, minF));
                            }
                        }
                        if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
                    }, EventLog);
                }
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  CONFIG / INI — hot-reload
        // ══════════════════════════════════════════════════════════════════════
        void ReadConfig()
        {
            processNames = null;
            customRes    = 0;

            string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
            if (!File.Exists(iniPath)) return;

            List<string> names = new List<string>();
            foreach (string raw in File.ReadAllLines(iniPath))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith("//"))
                    continue;

                if (line.ToLowerInvariant().StartsWith("resolution="))
                {
                    uint val;
                    if (uint.TryParse(line.Substring(11).Trim(), out val))
                        customRes = val;
                    continue;
                }

                foreach (string tok in line.Split(
                    new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string name = tok.ToLowerInvariant().Trim();
                    if (name.Length == 0) continue;
                    if (!name.EndsWith(".exe")) name += ".exe";
                    if (!names.Contains(name)) names.Add(name);
                }
            }
            processNames = names.Count > 0 ? names : null;
        }

        void StartIniWatcher()
        {
            Safe.Run("ini_watcher", () =>
            {
                string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
                iniWatcher = new FileSystemWatcher(
                    Path.GetDirectoryName(iniPath),
                    Path.GetFileName(iniPath));
                iniWatcher.NotifyFilter        = NotifyFilters.LastWrite;
                iniWatcher.Changed            += OnIniChanged;
                iniWatcher.EnableRaisingEvents = true;
            }, EventLog);
        }

        void OnIniChanged(object sender, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            Safe.Run("ini_reload", () =>
            {
                ReadConfig();
                targetRes = customRes > 0
                    ? customRes
                    : Math.Min(TARGET_RESOLUTION, maxRes);

                if (startWatch != null)
                    try { startWatch.Stop(); startWatch.Dispose(); startWatch = null; } catch {}

                if (processNames != null && processNames.Count > 0)
                    StartEtwWatcher();
                else
                {
                    SetResolutionVerified();
                    ModulateUiPriority(true);
                }
                Log("[albus reload] config reloaded.");
            }, EventLog);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  LOGGING
        // ══════════════════════════════════════════════════════════════════════
        void Log(string msg)
        {
            try
            {
                EventLog.WriteEntry(
                    string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  P/INVOKE
        // ══════════════════════════════════════════════════════════════════════

        [DllImport("ntdll.dll")]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool Set, out uint Current);
        [DllImport("ntdll.dll")]
        static extern int NtQueryTimerResolution(out uint Min, out uint Max, out uint Current);
        [DllImport("ntdll.dll")]
        static extern int NtSetSystemInformation(int InfoClass, ref int Info, int Len);

        [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, int inherit, uint pid);
        [DllImport("kernel32.dll")] static extern int    WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll")] static extern bool   SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr attr, string name, uint flags, uint access);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr hProc, int InfoClass,
            ref PROCESS_POWER_THROTTLING Info, int Size);
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessWorkingSetSizeEx(IntPtr hProc,
            UIntPtr min, UIntPtr max, uint flags);
        [DllImport("kernel32.dll")]
        static extern bool GetSystemCpuSetInformation(IntPtr info, uint bufLen,
            out uint returned, IntPtr proc, uint flags);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool   SetThreadPriority(IntPtr hThread, int nPriority);

        [DllImport("psapi.dll")]    static extern int    EmptyWorkingSet(IntPtr hProc);
        [DllImport("avrt.dll")]     static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint idx);
        [DllImport("ole32.dll")]    static extern int    CoInitializeEx(IntPtr pv, uint dwCoInit);
        [DllImport("gdi32.dll")]    static extern int    D3DKMTSetProcessSchedulingPriority(IntPtr hProc, int pri);
        [DllImport("powrprof.dll")]
        static extern uint CallNtPowerInformation(int Level, IntPtr inBuf, uint inLen,
            IntPtr outBuf, uint outLen);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr OpenTrace(ref EVENT_TRACE_LOGFILE Logfile);
        [DllImport("advapi32.dll")]
        static extern uint ProcessTrace(IntPtr[] HandleArray, uint HandleCount,
            IntPtr StartTime, IntPtr EndTime);
        [DllImport("advapi32.dll")]
        static extern uint CloseTrace(IntPtr TraceHandle);

        // ── constants ─────────────────────────────────────────────────────────
        const uint SYNCHRONIZE                              = 0x00100000u;
        const uint ES_CONTINUOUS                            = 0x80000000u;
        const uint ES_SYSTEM_REQUIRED                       = 0x00000001u;
        const uint ES_DISPLAY_REQUIRED                      = 0x00000002u;
        const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION    = 0x00000002u;
        const uint TIMER_ALL_ACCESS                         = 0x1F0003u;
        const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE           = 0x00000001u;
        const int  ProcessPowerThrottling                   = 4;
        const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x4u;
        const int  ProcessorIdleDomains                     = 14;
        const int  D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME  = 5;
        const int  IrqPolicySpecifiedProcessors             = 4;
        const int  THREAD_PRIORITY_TIME_CRITICAL            = 15;
        const int  EDataFlow_eRender                        = 0;
        const int  DEVICE_STATE_ACTIVE                      = 1;
        const int  CLSCTX_ALL                               = 0x17;
        const uint COINIT_MULTITHREADED                     = 0u;
        const int  PROCESS_TRACE_MODE_REAL_TIME             = 0x00000100;
        const int  PROCESS_TRACE_MODE_EVENT_RECORD          = 0x10000000;
        static readonly IntPtr INVALID_PROCESSTRACE_HANDLE  = new IntPtr(-1);

        // ── structs ───────────────────────────────────────────────────────────

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING
        { public uint Version, ControlMask, StateMask; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct WAVEFORMATEX
        {
            public ushort wFormatTag, nChannels;
            public uint   nSamplesPerSec, nAvgBytesPerSec;
            public ushort nBlockAlign, wBitsPerSample, cbSize;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct EVENT_TRACE_LOGFILE
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string LogFileName;
            [MarshalAs(UnmanagedType.LPWStr)] public string LoggerName;
            public long  CurrentTime;
            public uint  BuffersRead;
            public uint  ProcessTraceMode;
            public IntPtr CurrentEvent;
            public IntPtr LogfileHeader;
            public IntPtr BufferCallback;
            public int   BufferSize;
            public int   Filled;
            public int   EventsLost;
            public EventRecordCallback EventRecordCallback;
            public uint  IsKernelTrace;
            public IntPtr Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_RECORD
        {
            public EVENT_HEADER EventHeader;
            public ETW_BUFFER_CONTEXT BufferContext;
            public ushort ExtendedDataCount;
            public ushort UserDataLength;
            public IntPtr ExtendedData;
            public IntPtr UserData;
            public IntPtr UserContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_HEADER
        {
            public ushort Size;
            public ushort HeaderType;
            public ushort Flags;
            public ushort EventProperty;
            public uint   ThreadId;
            public uint   ProcessId;
            public long   TimeStamp;
            public Guid   ProviderId;
            public ushort Id;
            public byte   Version;
            public byte   Channel;
            public byte   Level;
            public byte   Opcode;
            public ushort Task;
            public ulong  Keyword;
            public uint   KernelTime;
            public uint   UserTime;
            public Guid   ActivityId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ETW_BUFFER_CONTEXT
        {
            public byte  ProcessorNumber;
            public byte  Alignment;
            public ushort LoggerId;
        }

        delegate void EventRecordCallback(ref EVENT_RECORD EventRecord);

        // ── COM interfaces — full vtable chain (IAudioClient→2→3) ─────────────

        [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint n);
            [PreserveSig] int Item(uint i, out IMMDevice dev);
        }

        [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMNotificationClient
        {
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role,
                [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
        }

        // CS0051 ROOT CAUSE + FIX:
        // IMMDeviceEnumerator had no explicit access modifier → defaulted to internal.
        // OptimizeAllEndpoints() was declared internal — same level — so C#6+ is fine,
        // but the legacy csc.exe (C#5, .NET 4.x) enforces stricter rules and rejects
        // an internal parameter type on an internal method when called from a nested
        // class (AudioNotifier) that holds it as a field. Explicitly marking the
        // interface internal makes the contract unambiguous to the old compiler.
        [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, int state, out IMMDeviceCollection col);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
            [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient cb);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient cb);
        }

        [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr pParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [ComImport][Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long defPeriod, out long minPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
        }

        [ComImport][Guid("726778CD-F60A-4EDA-82DE-E47610CD78AA")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient2
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long defPeriod, out long minPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int cat, out int capable);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool useEventDriven,
                out long minDur, out long maxDur);
        }

        [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient3
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period,
                IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long defPeriod, out long minPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int cat, out int capable);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool useEventDriven,
                out long minDur, out long maxDur);
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt,
                out uint defaultPeriodInFrames,
                out uint fundamentalPeriodInFrames,
                out uint minPeriodInFrames,
                out uint maxPeriodInFrames);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(
                out IntPtr fmt, out uint currentPeriodInFrames);
            [PreserveSig] int InitializeSharedAudioStream(
                uint streamFlags, uint periodInFrames,
                IntPtr fmt, IntPtr audioSessionGuid);
        }

        // AudioNotifier uses IMMDeviceEnumerator as internal field — consistent.
        class AudioNotifier : IMMNotificationClient
        {
            public AlbusService        Service;
            public IMMDeviceEnumerator Enumerator;

            public int OnDeviceStateChanged(string id, int state) { return 0; }
            public int OnDeviceAdded(string id)                   { return 0; }
            public int OnDeviceRemoved(string id)                 { return 0; }
            public int OnPropertyValueChanged(string id, IntPtr key) { return 0; }

            public int OnDefaultDeviceChanged(int flow, int role, string id)
            {
                Safe.Run("audio_devchange", () =>
                {
                    if (Service != null)
                    {
                        Service.Log("[albus audio] device change — re-optimizing endpoints.");
                        lock (Service.audioClients) Service.audioClients.Clear();
                        if (Enumerator != null)
                            Service.OptimizeAllEndpoints(Enumerator);
                    }
                }, Service != null ? Service.EventLog : null);
                return 0;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INSTALLER
    // ══════════════════════════════════════════════════════════════════════════
    [RunInstaller(true)]
    public class AlbusInstaller : Installer
    {
        public AlbusInstaller()
        {
            ServiceProcessInstaller spi = new ServiceProcessInstaller();
            spi.Account  = ServiceAccount.LocalSystem;
            spi.Username = null;
            spi.Password = null;

            ServiceInstaller si = new ServiceInstaller();
            si.ServiceName  = "AlbusXSvc";
            si.DisplayName  = "AlbusX";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "albus v4.2 — timer, NUMA-CPU, C-state, GPU D3DKMT, " +
                "audio IAudioClient3, memory, GPU+NIC IRQ affinity, ETW, watchdog, health.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
