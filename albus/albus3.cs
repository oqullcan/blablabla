// ══════════════════════════════════════════════════════════════════════════════
//  AlbusB  v1.0
//  precision system latency service — fully automatic, zero manual steps
//
//  layers:
//    · timer        — 0.5ms kernel timer resolution, guard + watchdog
//    · cpu          — auto topology detection, SMT-aware P-core affinity,
//                     NUMA-local binding, thread ideal processor
//    · scheduler    — kernel scheduler granularity, DPC behavior
//    · c-state      — NtPowerInformation kernel idle block
//    · throttle     — EcoQoS / Thread Director disable
//    · gpu          — D3DKMT realtime, IRQ affinity (runtime)
//    · nic          — IRQ affinity, QoS socket flow, UDP buffer (runtime)
//    · audio        — IAudioClient3 minimum buffer, glitch detection
//    · memory       — Large Pages, NUMA-local alloc, standby purge,
//                     working set lock, memory priority
//    · priority     — process/thread, DWM boost, explorer throttle,
//                     child process inheritance
//    · etw          — kernel-session process tracking (WMI fallback)
//    · watchdog     — priority theft, timer drift, health report
//    · log          — dual: Windows Event Log + C:\AlbusB\albusbx.log
//    · ini          — process list + custom resolution, hot-reload
//
//  compile:
//    csc.exe -r:System.ServiceProcess.dll
//            -r:System.Configuration.Install.dll
//            -r:System.Management.dll
//            -r:System.Net.dll
//            -out:AlbusBX.exe AlbusBX.cs
//
//  service name : AlbusBSvc
//  exe          : AlbusBX.exe
//  log          : C:\AlbusB\albusbx.log
//  ini          : AlbusBX.exe.ini  (optional)
// ══════════════════════════════════════════════════════════════════════════════

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Threading;
using System.Management;
using System.Text.RegularExpressions;
using Microsoft.Win32;

[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyProduct("AlbusB")]
[assembly: AssemblyTitle("AlbusB")]
[assembly: AssemblyDescription("precision system latency service v1.0")]

namespace AlbusB
{
    // ══════════════════════════════════════════════════════════════════════════
    //  LOGGER — dual output: Event Log + flat file
    // ══════════════════════════════════════════════════════════════════════════
    static class Log
    {
        static readonly string LogPath  = @"C:\AlbusB\albusbx.log";
        static readonly object FileLock = new object();
        static EventLog _eventLog;

        public static void Init(EventLog ev)
        {
            _eventLog = ev;
            try
            {
                string dir = Path.GetDirectoryName(LogPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                // rotate if > 10 MB
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 10 * 1024 * 1024)
                {
                    string arch = LogPath + "." + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".bak";
                    File.Move(LogPath, arch);
                }
            }
            catch { }
        }

        public static void Write(string msg, bool warn = false)
        {
            string line = string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss.fff"), msg);
            lock (FileLock)
                try { File.AppendAllText(LogPath, line + Environment.NewLine); } catch { }
            if (_eventLog != null)
                try
                {
                    _eventLog.WriteEntry(line,
                        warn ? EventLogEntryType.Warning : EventLogEntryType.Information);
                }
                catch { }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  SAFE — guarded execution
    // ══════════════════════════════════════════════════════════════════════════
    static class Safe
    {
        public static void Run(string tag, Action fn)
        {
            try { fn(); }
            catch (Exception ex) { Log.Write(string.Format("[{0}] ERROR: {1}", tag, ex.Message), true); }
        }

        public static T Run<T>(string tag, Func<T> fn, T def = default(T))
        {
            try { return fn(); }
            catch (Exception ex) { Log.Write(string.Format("[{0}] ERROR: {1}", tag, ex.Message), true); return def; }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CPU TOPOLOGY — auto-detect cores, NUMA, SMT, efficiency classes
    // ══════════════════════════════════════════════════════════════════════════
    static class CpuTopology
    {
        public struct CoreInfo
        {
            public byte LogicalIndex;
            public byte EfficiencyClass;   // 0 = E-core / low, max = P-core
            public byte NumaNode;
            public byte PhysicalCore;      // from APIC/SMT pairing
        }

        public static List<CoreInfo> Cores            = new List<CoreInfo>();
        public static byte           MaxEffClass       = 0;
        public static byte           BestNumaNode      = 0;
        public static long           PCoreMask         = 0;   // P-cores, no HT siblings
        public static long           AllPCoreMask      = 0;   // P-cores including HT
        public static int            PhysicalCoreCount = 0;

        public static void Detect()
        {
            Safe.Run("topo_detect", () =>
            {
                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0) { FallbackUniform(); return; }

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                    { FallbackUniform(); return; }

                    // pass 1: find max efficiency class
                    for (int off = 0; off < (int)returned; )
                    {
                        int sz = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff = Marshal.ReadByte(buf, off + 18);
                        if (eff > MaxEffClass) MaxEffClass = eff;
                        off += sz;
                    }

                    // pass 2: collect all cores
                    var physicalSeen = new Dictionary<byte, List<byte>>();  // physCore -> logicals

                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz      = Marshal.ReadInt32(buf, off);
                        if (sz < 24) break;
                        byte eff     = Marshal.ReadByte(buf, off + 18);
                        byte logical = Marshal.ReadByte(buf, off + 14);
                        byte numa    = Marshal.ReadByte(buf, off + 19);
                        byte phys    = Marshal.ReadByte(buf, off + 20);

                        var ci = new CoreInfo
                        {
                            LogicalIndex    = logical,
                            EfficiencyClass = eff,
                            NumaNode        = numa,
                            PhysicalCore    = phys
                        };
                        Cores.Add(ci);

                        if (!physicalSeen.ContainsKey(phys))
                            physicalSeen[phys] = new List<byte>();
                        physicalSeen[phys].Add(logical);

                        off += sz;
                    }

                    PhysicalCoreCount = physicalSeen.Count;

                    // Find best NUMA node (most P-cores)
                    var nodeCount = new Dictionary<byte, int>();
                    foreach (var c in Cores)
                    {
                        if (c.EfficiencyClass < MaxEffClass) continue;
                        if (!nodeCount.ContainsKey(c.NumaNode)) nodeCount[c.NumaNode] = 0;
                        nodeCount[c.NumaNode]++;
                    }
                    foreach (var kv in nodeCount)
                        if (!nodeCount.ContainsKey(BestNumaNode) ||
                            kv.Value > nodeCount[BestNumaNode])
                            BestNumaNode = kv.Key;

                    // Build masks:
                    //   AllPCoreMask — all logical CPUs on P-cores in best NUMA
                    //   PCoreMask    — only ONE logical per physical (no HT sibling)
                    var usedPhys = new SimpleHashSet<byte>();
                    foreach (var c in Cores)
                    {
                        if (c.EfficiencyClass < MaxEffClass) continue;
                        if (c.NumaNode != BestNumaNode)      continue;
                        AllPCoreMask |= (1L << c.LogicalIndex);
                        if (!usedPhys.Contains(c.PhysicalCore))
                        {
                            PCoreMask |= (1L << c.LogicalIndex);
                            usedPhys.Add(c.PhysicalCore);
                        }
                    }

                    // Uniform CPU (no hybrid): use all cores, skip HT siblings
                    if (MaxEffClass == 0)
                    {
                        usedPhys     = new SimpleHashSet<byte>();   // ← fresh instance, no Clear needed
                        PCoreMask    = 0;
                        AllPCoreMask = 0;
                        foreach (var c in Cores)
                        {
                            AllPCoreMask |= (1L << c.LogicalIndex);
                            if (!usedPhys.Contains(c.PhysicalCore))
                            {
                                PCoreMask |= (1L << c.LogicalIndex);
                                usedPhys.Add(c.PhysicalCore);
                            }
                        }
                        BestNumaNode = 0;
                    }

                    Log.Write(string.Format(
                        "[topo] cpus={0} physical={1} numa={2} effclass={3} " +
                        "pcore_mask=0x{4:X} allpcore_mask=0x{5:X}",
                        Cores.Count, PhysicalCoreCount, BestNumaNode,
                        MaxEffClass, PCoreMask, AllPCoreMask));
                }
                finally { Marshal.FreeHGlobal(buf); }
            });
        }

        static void FallbackUniform()
        {
            int n = Environment.ProcessorCount;
            for (byte i = 0; i < n; i++)
            {
                Cores.Add(new CoreInfo { LogicalIndex = i });
                AllPCoreMask |= (1L << i);
                if (i % 2 == 0 || n <= 2) PCoreMask |= (1L << i);
            }
            PhysicalCoreCount = Math.Max(1, n / 2);
            Log.Write(string.Format("[topo] fallback uniform: {0} logical, mask=0x{1:X}", n, PCoreMask));
        }

        // Dedicated core for NIC IRQ — physical core 1, first thread
        public static int NicIrqCore()
        {
            int n = Environment.ProcessorCount;
            if (n <= 1) return 0;
            foreach (var c in Cores)
                if (c.PhysicalCore == 1 && c.EfficiencyClass == MaxEffClass)
                    return c.LogicalIndex;
            return 1;
        }

        // Dedicated core for GPU IRQ — physical core 2, first thread
        public static int GpuIrqCore()
        {
            int n = Environment.ProcessorCount;
            if (n <= 2) return n > 1 ? 1 : 0;
            foreach (var c in Cores)
                if (c.PhysicalCore == 2 && c.EfficiencyClass == MaxEffClass)
                    return c.LogicalIndex;
            return 2;
        }

        public static int CountBits(long v)
        {
            int c = 0; while (v != 0) { c += (int)(v & 1L); v >>= 1; } return c;
        }

        public static byte[] MaskToBytes(long mask)
        {
            int cpus      = Environment.ProcessorCount;
            int byteCount = Math.Max(4, (cpus + 7) / 8);
            byte[] b      = new byte[byteCount];
            for (int i = 0; i < byteCount && i < 8; i++)
                b[i] = (byte)((mask >> (i * 8)) & 0xFF);
            return b;
        }

        [DllImport("kernel32.dll")]
        static extern bool GetSystemCpuSetInformation(IntPtr info, uint bufLen,
            out uint returned, IntPtr proc, uint flags);

        // ── Minimal HashSet replacement (no System.Collections.Generic.HashSet in .NET 3.5 target) ──
        // FIX: renamed from nested HashSet<T> to SimpleHashSet<T> to avoid name collision,
        //      and added Clear() so the uniform-CPU path can reuse without CS1061.
        internal sealed class SimpleHashSet<T>
        {
            readonly Dictionary<T, bool> _d = new Dictionary<T, bool>();
            public bool Contains(T v) { return _d.ContainsKey(v); }
            public void Add(T v)      { _d[v] = true; }
            public void Clear()       { _d.Clear(); }           // ← FIX: was missing
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  MAIN SERVICE
    // ══════════════════════════════════════════════════════════════════════════
    sealed class AlbusBService : ServiceBase
    {
        // ── constants ────────────────────────────────────────────────────────
        const string SVC_NAME               = "AlbusBSvc";
        const uint   TARGET_RESOLUTION      = 5000u;    // 0.5 ms (100-ns units)
        const uint   RESOLUTION_TOLERANCE   = 50u;      // 5 µs
        const int    GUARD_SEC              = 8;
        const int    WATCHDOG_SEC           = 8;
        const int    HEALTH_INITIAL_MIN     = 3;
        const int    HEALTH_INTERVAL_MIN    = 10;
        const int    PURGE_INITIAL_MIN      = 2;
        const int    PURGE_INTERVAL_MIN     = 4;
        const int    PURGE_THRESHOLD_MB     = 1024;
        const int    WIN11_BUILD            = 22621;

        // ── state ─────────────────────────────────────────────────────────────
        uint   defaultRes, minRes, maxRes, targetRes, customRes;
        long   processCounter;
        IntPtr hWaitTimer = IntPtr.Zero;
        bool   isWin11;

        Timer                  guardTimer, purgeTimer, watchdogTimer, healthTimer;
        ManagementEventWatcher startWatch;
        FileSystemWatcher      iniWatcher;
        Thread                 audioThread, etwThread;
        List<string>           processNames;
        int                    wmiRetry;
        long                   dpcBaselineTicks;
        int                    audioGlitchCount;
        ManualResetEventSlim   stopEvent = new ManualResetEventSlim(false);

        // Performance counters — created once, reused
        PerformanceCounter pcMemAvail, pcCpuTotal;

        // Audio
        readonly List<object> audioClients = new List<object>();
        AudioNotifier         audioNotifier;

        // NIC IRQ restore
        readonly Dictionary<string, byte[]> origNicMask   = new Dictionary<string, byte[]>();
        readonly Dictionary<string, int>    origNicPolicy = new Dictionary<string, int>();

        // Large Pages handle list for cleanup
        readonly List<IntPtr> largePageAllocs = new List<IntPtr>();

        // ── entry ─────────────────────────────────────────────────────────────
        static void Main() { ServiceBase.Run(new AlbusBService()); }

        public AlbusBService()
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
            Log.Init(EventLog);
            Log.Write("[albusbx] starting v1.0...");

            //  1. Detect CPU topology first — everything else depends on it
            CpuTopology.Detect();

            //  2. Self priority + affinity
            SetSelfPriority();
            SetSelfAffinity();

            //  3. ThreadPool
            Safe.Run("threadpool", () =>
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 32), Math.Max(io, 16));
            });

            //  4. GC sustained low latency
            Safe.Run("gc", () => GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency);

            //  5. High-res waitable timer
            Safe.Run("waittimer", () =>
            {
                hWaitTimer = CreateWaitableTimerExW(IntPtr.Zero, null,
                    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
            });

            //  6. Working set lock 16–256 MB
            Safe.Run("workingset", () =>
                SetProcessWorkingSetSizeEx(
                    Process.GetCurrentProcess().Handle,
                    (UIntPtr)(16  * 1024 * 1024),
                    (UIntPtr)(256 * 1024 * 1024),
                    QUOTA_LIMITS_HARDWS_MIN_ENABLE));

            //  7. Large Pages
            AcquireLargePagePrivilege();

            //  8. MMCSS Pro Audio
            Safe.Run("mmcss", () => { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); });

            //  9. Disable EcoQoS throttling
            DisableThrottling();

            // 10. Prevent sleep
            Safe.Run("execstate", () =>
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED));

            // 11. Win11 detection
            isWin11 = DetectWin11();
            Log.Write(string.Format("[albusbx] win11={0}", isWin11));

            // 12. Read config
            ReadConfig();

            // 13. Scheduler granularity + DPC behavior
            TuneScheduler();

            // 14. C-state block
            DisableCStates();

            // 15. GPU priority + IRQ
            BoostGpuPriority();
            OptimizeGpuIrqAffinity();

            // 16. NIC IRQ + QoS
            OptimizeNicIrqAffinity();

            // 17. Memory priority + NUMA
            SetMemoryPriority();

            // 18. Timer resolution
            NtQueryTimerResolution(out minRes, out maxRes, out defaultRes);
            targetRes = customRes > 0 ? customRes : Math.Min(TARGET_RESOLUTION, maxRes);

            Log.Write(string.Format(
                "[albusbx] timer min={0} max={1} default={2} target={3} ({4:F3}ms)",
                minRes, maxRes, defaultRes, targetRes, targetRes / 10000.0));

            // 19. DPC baseline (background)
            ThreadPool.QueueUserWorkItem(delegate { MeasureDpcBaseline(); });

            // 20. Performance counters (created once)
            Safe.Run("perf_counters", () =>
            {
                pcMemAvail = new PerformanceCounter("Memory",    "Available MBytes");
                pcCpuTotal = new PerformanceCounter("Processor", "% Processor Time", "_Total");
                pcCpuTotal.NextValue(); // prime
            });

            // 21. Global or process-target mode
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

            // 22. Background workers
            StartGuard();
            StartPurge();
            StartWatchdog();
            StartHealthMonitor();
            StartIniWatcher();
            StartAudioThread();

            GhostMemory();
            Log.Write("[albusbx] all layers armed.");
            base.OnStart(args);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  STOP
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStop()
        {
            stopEvent.Set();

            Safe.Run("execstate", () => SetThreadExecutionState(ES_CONTINUOUS));

            DropTimer(ref guardTimer);
            DropTimer(ref purgeTimer);
            DropTimer(ref watchdogTimer);
            DropTimer(ref healthTimer);

            Safe.Run("watcher_stop", () =>
            {
                if (startWatch != null) { startWatch.Stop(); startWatch.Dispose(); startWatch = null; }
            });
            Safe.Run("iniwatcher_stop", () =>
            {
                if (iniWatcher != null) { iniWatcher.EnableRaisingEvents = false; iniWatcher.Dispose(); }
            });
            Safe.Run("waittimer_stop", () =>
            {
                if (hWaitTimer != IntPtr.Zero) { CloseHandle(hWaitTimer); hWaitTimer = IntPtr.Zero; }
            });
            Safe.Run("perf_counters_stop", () =>
            {
                if (pcMemAvail != null) { pcMemAvail.Dispose(); pcMemAvail = null; }
                if (pcCpuTotal != null) { pcCpuTotal.Dispose(); pcCpuTotal = null; }
            });

            // Free large page allocations
            Safe.Run("largepages_free", () =>
            {
                lock (largePageAllocs)
                    foreach (IntPtr p in largePageAllocs)
                        try { VirtualFree(p, UIntPtr.Zero, MEM_RELEASE); } catch { }
                largePageAllocs.Clear();
            });

            RestoreNicIrqAffinity();
            RestoreCStates();
            RestoreScheduler();
            ModulateUiPriority(false);

            Safe.Run("timer_restore", () =>
            {
                uint actual = 0;
                NtSetTimerResolution(defaultRes, true, out actual);
                Log.Write(string.Format("[albusbx] timer restored: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            });

            Log.Write("[albusbx] stopped, all changes reversed.");
            base.OnStop();
        }

        protected override void OnShutdown() { Safe.Run("shutdown", () => OnStop()); }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(3000);
                CpuTopology.Detect();   // topology can change after sleep on some laptops
                SetSelfPriority();
                SetSelfAffinity();
                TuneScheduler();
                DisableCStates();
                BoostGpuPriority();
                OptimizeGpuIrqAffinity();
                OptimizeNicIrqAffinity();
                SetResolutionVerified();
                PurgeStandbyList();
                MeasureDpcBaseline();
                Log.Write("[albusbx] post-sleep rearm complete.");
            }
            return true;
        }

        static void DropTimer(ref Timer t)
        {
            if (t == null) return;
            try { t.Dispose(); } catch { }
            t = null;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SELF PRIORITY + AFFINITY
        // ══════════════════════════════════════════════════════════════════════
        void SetSelfPriority()
        {
            Safe.Run("self_priority", () =>
            {
                Process self = Process.GetCurrentProcess();
                self.PriorityClass        = ProcessPriorityClass.RealTime;
                self.PriorityBoostEnabled = false;
                Thread.CurrentThread.Priority = ThreadPriority.Highest;
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
            });
        }

        void SetSelfAffinity()
        {
            Safe.Run("self_affinity", () =>
            {
                if (CpuTopology.PCoreMask == 0) return;
                Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)CpuTopology.PCoreMask;
                int ideal = 0;
                for (int i = 0; i < 64; i++)
                    if ((CpuTopology.PCoreMask & (1L << i)) != 0) { ideal = i; break; }
                SetThreadIdealProcessor(GetCurrentThread(), (uint)ideal);
                Log.Write(string.Format("[cpu] self affinity=0x{0:X} ideal={1}",
                    CpuTopology.PCoreMask, ideal));
            });
        }

        void DisableThrottling()
        {
            Safe.Run("throttle", () =>
            {
                PROCESS_POWER_THROTTLING s;
                s.Version     = 1;
                s.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                s.StateMask   = 0;
                SetProcessInformation(Process.GetCurrentProcess().Handle,
                    ProcessPowerThrottling, ref s,
                    Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SCHEDULER TUNING
        // ══════════════════════════════════════════════════════════════════════
        int savedDpcBehavior = -1;

        void TuneScheduler()
        {
            Safe.Run("scheduler_quantum", () =>
            {
                int quantum = 0x12; // short variable quantum
                NtSetSystemInformation(3, ref quantum, sizeof(int));
                Log.Write("[sched] quantum set to short-variable.");
            });

            Safe.Run("scheduler_dpc", () =>
            {
                int cur = 0;
                NtQuerySystemInformation(DpcBehaviorInfo, ref cur, sizeof(int), IntPtr.Zero);
                savedDpcBehavior = cur;
                int val = 0;
                NtSetSystemInformation(DpcBehaviorInfo, ref val, sizeof(int));
                Log.Write(string.Format("[sched] dpc watchdog disabled (was {0}).", cur));
            });
        }

        void RestoreScheduler()
        {
            Safe.Run("scheduler_restore", () =>
            {
                if (savedDpcBehavior >= 0)
                {
                    NtSetSystemInformation(DpcBehaviorInfo, ref savedDpcBehavior, sizeof(int));
                    Log.Write("[sched] dpc behavior restored.");
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WIN11 DETECTION
        // ══════════════════════════════════════════════════════════════════════
        bool DetectWin11()
        {
            return Safe.Run("win11", () =>
            {
                int build = 0;
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("CurrentBuildNumber");
                        if (v != null) int.TryParse(v.ToString(), out build);
                    }
                }
                return build >= WIN11_BUILD;
            }, false);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  C-STATE BLOCK
        // ══════════════════════════════════════════════════════════════════════
        void DisableCStates()
        {
            Safe.Run("cstate_off", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 1);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log.Write("[cstate] c-state transitions blocked.");
            });
        }

        void RestoreCStates()
        {
            Safe.Run("cstate_on", () =>
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 0);
                CallNtPowerInformation(ProcessorIdleDomains, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log.Write("[cstate] c-state transitions restored.");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU
        // ══════════════════════════════════════════════════════════════════════
        void BoostGpuPriority()
        {
            Safe.Run("gpu_prio", () =>
            {
                int hr = D3DKMTSetProcessSchedulingPriority(
                    Process.GetCurrentProcess().Handle,
                    D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME);
                Log.Write(string.Format("[gpu] d3dkmt realtime (hr=0x{0:X})", hr));
            });
        }

        void OptimizeGpuIrqAffinity()
        {
            Safe.Run("gpu_irq", () =>
            {
                int  gpuCore  = CpuTopology.GpuIrqCore();
                long gpuMask  = 1L << gpuCore;
                long fullMask = CpuTopology.PCoreMask & ~1L;
                if (fullMask == 0) fullMask = gpuMask;

                const string BASE =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}";
                using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(BASE, true))
                {
                    if (cls == null) return;
                    int count = 0;
                    foreach (string sub in cls.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = cls.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            using (RegistryKey pol = dev.CreateSubKey("Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                pol.SetValue("AssignmentSetOverride",
                                    CpuTopology.MaskToBytes(fullMask), RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors, RegistryValueKind.DWord);
                                count++;
                            }
                        }
                    }
                    if (count > 0)
                        Log.Write(string.Format("[gpu_irq] {0} device(s), mask=0x{1:X}", count, fullMask));
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  NIC IRQ + QoS SOCKET FLOW
        // ══════════════════════════════════════════════════════════════════════
        void OptimizeNicIrqAffinity()
        {
            Safe.Run("nic_irq", () =>
            {
                int  nicCore  = CpuTopology.NicIrqCore();
                long nicMask  = 1L << nicCore;

                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";
                using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (cls == null) return;
                    int count = 0;
                    foreach (string sub in cls.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = cls.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            if (IsVirtualAdapter(dev)) continue;

                            string dk = NIC_CLASS + "\\" + sub;

                            // Save originals
                            using (RegistryKey pol = dev.OpenSubKey("Interrupt Management\\Affinity Policy"))
                            {
                                if (pol != null)
                                {
                                    object ov = pol.GetValue("AssignmentSetOverride");
                                    if (ov is byte[]) origNicMask[dk] = (byte[])ov;
                                    object od = pol.GetValue("DevicePolicy");
                                    if (od != null) try { origNicPolicy[dk] = (int)od; } catch { }
                                }
                            }

                            // Apply
                            using (RegistryKey pol = dev.CreateSubKey("Interrupt Management\\Affinity Policy"))
                            {
                                if (pol == null) continue;
                                pol.SetValue("AssignmentSetOverride",
                                    CpuTopology.MaskToBytes(nicMask), RegistryValueKind.Binary);
                                pol.SetValue("DevicePolicy",
                                    IrqPolicySpecifiedProcessors, RegistryValueKind.DWord);
                                count++;
                            }
                        }
                    }
                    if (count > 0)
                        Log.Write(string.Format("[nic_irq] {0} adapter(s), core={1}", count, nicCore));
                }
            });

            ApplyQosToUdpSockets();
        }

        void ApplyQosToUdpSockets()
        {
            Safe.Run("nic_qos", () =>
            {
                IntPtr hQos = IntPtr.Zero;
                QOS_VERSION ver;
                ver.MajorVersion = 1;
                ver.MinorVersion = 0;
                if (!QOSCreateHandle(ref ver, out hQos)) return;

                try
                {
                    using (RegistryKey qos = Registry.LocalMachine.CreateSubKey(
                        @"SOFTWARE\Policies\Microsoft\Windows\QoS\AlbusB-Realtime"))
                    {
                        qos.SetValue("Version",       "1.0",     RegistryValueKind.String);
                        qos.SetValue("Protocol",      "UDP",     RegistryValueKind.String);
                        qos.SetValue("Local Port",    "*",       RegistryValueKind.String);
                        qos.SetValue("Remote Port",   "*",       RegistryValueKind.String);
                        qos.SetValue("Local IP",      "0.0.0.0", RegistryValueKind.String);
                        qos.SetValue("Remote IP",     "0.0.0.0", RegistryValueKind.String);
                        qos.SetValue("DSCP Value",    "46",      RegistryValueKind.String); // EF
                        qos.SetValue("Throttle Rate", "-1",      RegistryValueKind.String); // unlimited
                    }
                    Log.Write("[qos] udp dscp ef (46) policy applied.");
                }
                finally
                {
                    if (hQos != IntPtr.Zero) QOSCloseHandle(hQos);
                }
            });
        }

        void RestoreNicIrqAffinity()
        {
            Safe.Run("nic_irq_restore", () =>
            {
                const string NIC_CLASS =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}";
                using (RegistryKey cls = Registry.LocalMachine.OpenSubKey(NIC_CLASS, true))
                {
                    if (cls == null) return;
                    foreach (string sub in cls.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (RegistryKey dev = cls.OpenSubKey(sub, true))
                        {
                            if (dev == null) continue;
                            string dk = NIC_CLASS + "\\" + sub;
                            using (RegistryKey pol = dev.OpenSubKey("Interrupt Management\\Affinity Policy", true))
                            {
                                if (pol == null) continue;
                                if (origNicMask.ContainsKey(dk))
                                    pol.SetValue("AssignmentSetOverride", origNicMask[dk], RegistryValueKind.Binary);
                                if (origNicPolicy.ContainsKey(dk))
                                    pol.SetValue("DevicePolicy", origNicPolicy[dk], RegistryValueKind.DWord);
                            }
                        }
                    }
                }
                Safe.Run("qos_remove", () =>
                    Registry.LocalMachine.DeleteSubKey(
                        @"SOFTWARE\Policies\Microsoft\Windows\QoS\AlbusB-Realtime", false));

                Log.Write("[nic] irq affinity and qos restored.");
            });
        }

        static bool IsVirtualAdapter(RegistryKey dev)
        {
            try
            {
                string[] fields = { "DriverDesc", "DeviceDesc", "Description" };
                string[] kw     = { "virtual","loopback","tunnel","vpn","miniport","wan",
                                    "bluetooth","hyper-v","vmware","virtualbox","tap",
                                    "ndiswan","isatap","teredo","6to4" };
                foreach (string f in fields)
                {
                    object v = dev.GetValue(f);
                    if (v == null) continue;
                    string d = v.ToString().ToLowerInvariant();
                    foreach (string k in kw) if (d.Contains(k)) return true;
                }
            }
            catch { }
            return false;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  MEMORY
        // ══════════════════════════════════════════════════════════════════════
        void AcquireLargePagePrivilege()
        {
            Safe.Run("largepages", () =>
            {
                IntPtr hToken;
                if (!OpenProcessToken(Process.GetCurrentProcess().Handle,
                    TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken)) return;

                try
                {
                    LUID luid;
                    if (!LookupPrivilegeValue(null, "SeLockMemoryPrivilege", out luid)) return;

                    TOKEN_PRIVILEGES tp;
                    tp.PrivilegeCount           = 1;
                    tp.Privileges               = new LUID_AND_ATTRIBUTES[1];
                    tp.Privileges[0].Luid       = luid;
                    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

                    AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                    int err = Marshal.GetLastWin32Error();
                    if (err == 0)
                        Log.Write("[mem] SeLockMemoryPrivilege acquired — large pages enabled.");
                    else
                        Log.Write(string.Format("[mem] SeLockMemoryPrivilege failed (err={0}), continuing.", err));
                }
                finally { CloseHandle(hToken); }
            });
        }

        void SetMemoryPriority()
        {
            Safe.Run("mem_priority", () =>
            {
                MEMORY_PRIORITY_INFORMATION mpi;
                mpi.MemoryPriority = MEMORY_PRIORITY_NORMAL;
                SetProcessInformation2(Process.GetCurrentProcess().Handle,
                    ProcessMemoryPriority, ref mpi,
                    Marshal.SizeOf(typeof(MEMORY_PRIORITY_INFORMATION)));
                Log.Write("[mem] memory priority set to high.");
            });

            Safe.Run("mem_numa", () =>
            {
                if (CpuTopology.BestNumaNode == 0) return;
                UIntPtr sz   = (UIntPtr)(4 * 1024 * 1024); // 4 MB warm-up
                IntPtr  numa = VirtualAllocExNuma(
                    Process.GetCurrentProcess().Handle,
                    IntPtr.Zero, sz,
                    MEM_COMMIT | MEM_RESERVE,
                    PAGE_READWRITE,
                    CpuTopology.BestNumaNode);
                if (numa != IntPtr.Zero)
                {
                    lock (largePageAllocs) largePageAllocs.Add(numa);
                    Log.Write(string.Format("[mem] numa-local warm-up: 4MB on node {0}.",
                        CpuTopology.BestNumaNode));
                }
            });
        }

        void PurgeStandbyList()
        {
            Safe.Run("purge_cache",   () => SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0));
            Safe.Run("purge_standby", () => { int cmd = 4; NtSetSystemInformation(80, ref cmd, sizeof(int)); });
        }

        void GhostMemory()
        {
            Safe.Run("ghost", () => EmptyWorkingSet(Process.GetCurrentProcess().Handle));
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

            Log.Write(string.Format("[timer] set: {0} ({1:F3}ms)", actual, actual / 10000.0));
            if (isWin11) Log.Write("[timer] win11 per-process mode active.");
        }

        void RestoreResolution()
        {
            long c = Interlocked.Decrement(ref processCounter);
            if (c >= 1) return;
            uint actual = 0;
            NtSetTimerResolution(defaultRes, true, out actual);
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GUARD
        // ══════════════════════════════════════════════════════════════════════
        void StartGuard()
        {
            guardTimer = new Timer(GuardCallback, null,
                TimeSpan.FromSeconds(GUARD_SEC), TimeSpan.FromSeconds(GUARD_SEC));
        }

        void GuardCallback(object _)
        {
            Safe.Run("guard", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RESOLUTION_TOLERANCE) return;
                uint actual = 0;
                for (int i = 0; i < 5; i++)
                {
                    NtSetTimerResolution(targetRes, true, out actual);
                    Thread.SpinWait(5000);
                    NtQueryTimerResolution(out qMin, out qMax, out qCur);
                    if (qCur <= targetRes + RESOLUTION_TOLERANCE) break;
                }
                Log.Write(string.Format("[guard] timer drift corrected → {0:F3}ms", actual / 10000.0));
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  PURGE
        // ══════════════════════════════════════════════════════════════════════
        void StartPurge()
        {
            purgeTimer = new Timer(PurgeCallback, null,
                TimeSpan.FromMinutes(PURGE_INITIAL_MIN), TimeSpan.FromMinutes(PURGE_INTERVAL_MIN));
        }

        void PurgeCallback(object _)
        {
            Safe.Run("purge_cb", () =>
            {
                float mb = pcMemAvail != null ? pcMemAvail.NextValue() : 0;
                if (mb < PURGE_THRESHOLD_MB)
                {
                    PurgeStandbyList();
                    Log.Write(string.Format("[islc] standby purged, available={0:F0}MB.", mb));
                }
            });
            GhostMemory();
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WATCHDOG
        // ══════════════════════════════════════════════════════════════════════
        void StartWatchdog()
        {
            watchdogTimer = new Timer(WatchdogCallback, null,
                TimeSpan.FromSeconds(WATCHDOG_SEC), TimeSpan.FromSeconds(WATCHDOG_SEC));
        }

        void WatchdogCallback(object _)
        {
            Safe.Run("wd_prio", () =>
            {
                Process self = Process.GetCurrentProcess();
                if (self.PriorityClass != ProcessPriorityClass.RealTime)
                {
                    Log.Write(string.Format("[watchdog] priority stolen ({0}), restoring.", self.PriorityClass));
                    self.PriorityClass = ProcessPriorityClass.RealTime;
                }
            });

            Safe.Run("wd_affinity", () =>
            {
                if (CpuTopology.PCoreMask == 0) return;
                IntPtr cur = Process.GetCurrentProcess().ProcessorAffinity;
                if (cur != (IntPtr)CpuTopology.PCoreMask)
                {
                    Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)CpuTopology.PCoreMask;
                    Log.Write("[watchdog] affinity stolen, restored.");
                }
            });

            Safe.Run("wd_dwm", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { if (p.PriorityClass != ProcessPriorityClass.High) p.PriorityClass = ProcessPriorityClass.High; } catch { }
            });

            Safe.Run("wd_timer", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur > targetRes + RESOLUTION_TOLERANCE * 4)
                {
                    uint actual = 0;
                    NtSetTimerResolution(targetRes, true, out actual);
                    Log.Write(string.Format("[watchdog] timer drifted {0:F3}ms → corrected.", qCur / 10000.0));
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HEALTH MONITOR
        // ══════════════════════════════════════════════════════════════════════
        void StartHealthMonitor()
        {
            healthTimer = new Timer(HealthCallback, null,
                TimeSpan.FromMinutes(HEALTH_INITIAL_MIN), TimeSpan.FromMinutes(HEALTH_INTERVAL_MIN));
        }

        void HealthCallback(object _)
        {
            Safe.Run("health", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);

                float memMB = pcMemAvail != null ? pcMemAvail.NextValue() : 0;

                float cpu = 0;
                if (pcCpuTotal != null) { pcCpuTotal.NextValue(); Thread.Sleep(200); cpu = pcCpuTotal.NextValue(); }

                long best = long.MaxValue;
                for (int i = 0; i < 300; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(1000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < best) best = d;
                }
                double jitterUs = (best * 1000000.0) / Stopwatch.Frequency;

                double baseUs = dpcBaselineTicks > 0
                    ? (dpcBaselineTicks * 1000000.0) / Stopwatch.Frequency : 0;

                bool jitterBad = baseUs > 0 && jitterUs > baseUs * 3.0;

                Log.Write(string.Format(
                    "[health] timer={0:F3}ms | ram={1:F0}MB | cpu={2:F1}% | " +
                    "jitter={3:F2}µs | glitches={4}{5}",
                    qCur / 10000.0, memMB, cpu, jitterUs, audioGlitchCount,
                    jitterBad ? " | WARNING: high jitter!" : ""));

                if (jitterBad)
                {
                    SetSelfPriority();
                    SetSelfAffinity();
                    DisableCStates();
                    SetResolutionVerified();
                    Log.Write("[health] auto-rearm triggered due to high jitter.");
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  DPC BASELINE
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
                Log.Write(string.Format("[dpc] baseline jitter: {0:F2}µs", us));
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  UI PRIORITY
        // ══════════════════════════════════════════════════════════════════════
        void ModulateUiPriority(bool boost)
        {
            Safe.Run("ui_prio", () =>
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { p.PriorityClass = ProcessPriorityClass.High; } catch { }

                ProcessPriorityClass expPrio = boost
                    ? ProcessPriorityClass.BelowNormal : ProcessPriorityClass.Normal;
                foreach (Process p in Process.GetProcessesByName("explorer"))
                    try { p.PriorityClass = expPrio; } catch { }

                if (boost) Log.Write("[prio] dwm=high, explorer=belownormal.");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  ETW PROCESS TRACKER
        // ══════════════════════════════════════════════════════════════════════
        void StartEtwWatcher()
        {
            etwThread              = new Thread(EtwWorker);
            etwThread.Name         = "albusbx-etw";
            etwThread.Priority     = ThreadPriority.Highest;
            etwThread.IsBackground = true;
            etwThread.Start();
        }

        void EtwWorker()
        {
            bool ok = false;
            Safe.Run("etw", () => { ok = TryEtw(); });
            if (!ok) Safe.Run("wmi_fallback", StartWmiWatcher);
        }

        bool TryEtw()
        {
            var lf = new EVENT_TRACE_LOGFILE();
            lf.LoggerName          = "NT Kernel Logger";
            lf.ProcessTraceMode    = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
            lf.EventRecordCallback = OnEtwEvent;

            IntPtr h = OpenTrace(ref lf);
            if (h == INVALID_PROCESSTRACE_HANDLE)
            {
                lf.LoggerName = "AlbusB-KernelProc";
                h = OpenTrace(ref lf);
                if (h == INVALID_PROCESSTRACE_HANDLE) return false;
            }

            Log.Write("[etw] kernel trace started.");
            uint s = ProcessTrace(new IntPtr[] { h }, 1, IntPtr.Zero, IntPtr.Zero);
            CloseTrace(h);
            return s == 0;
        }

        void OnEtwEvent(ref EVENT_RECORD record)
        {
            ushort id      = record.EventHeader.Id;
            ushort dataLen = record.UserDataLength;
            IntPtr data    = record.UserData;

            Safe.Run("etw_ev", () =>
            {
                if (id != 1 || dataLen < 20) return;
                string img = "";
                Safe.Run("etw_img", () =>
                {
                    img = Marshal.PtrToStringUni(IntPtr.Add(data, 8));
                    if (img != null) img = Path.GetFileName(img).ToLowerInvariant();
                });
                if (string.IsNullOrEmpty(img)) return;
                List<string> tgts = processNames;
                if (tgts == null || !tgts.Contains(img)) return;
                uint pid = (uint)Marshal.ReadInt32(data, 0);
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid, img); });
            });
        }

        // ── WMI fallback ──────────────────────────────────────────────────────
        void StartWmiWatcher()
        {
            string q = string.Format(
                "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 " +
                "WHERE TargetInstance isa \"Win32_Process\" AND (TargetInstance.Name=\"{0}\")",
                string.Join("\" OR TargetInstance.Name=\"", processNames));
            startWatch               = new ManagementEventWatcher(q);
            startWatch.EventArrived += OnProcArrived;
            startWatch.Stopped      += OnWatcherStopped;
            startWatch.Start();
            wmiRetry = 0;
            Log.Write("[wmi] watching: " + string.Join(", ", processNames));
        }

        void OnWatcherStopped(object s, StoppedEventArgs e)
        {
            if (wmiRetry >= 5 || stopEvent.IsSet) return;
            wmiRetry++;
            Thread.Sleep(3000);
            Safe.Run("wmi_restart", () =>
            {
                if (startWatch != null) try { startWatch.Dispose(); } catch { }
                startWatch = null;
                StartWmiWatcher();
            });
        }

        void OnProcArrived(object s, EventArrivedEventArgs e)
        {
            Safe.Run("wmi_arrived", () =>
            {
                ManagementBaseObject proc =
                    (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                uint   pid  = (uint)proc.Properties["ProcessId"].Value;
                string name = proc.Properties["Name"].Value.ToString().ToLowerInvariant();
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid, name); });
            });
        }

        // ── Process started ───────────────────────────────────────────────────
        void ProcessStarted(uint pid, string name)
        {
            Safe.Run("proc_start", () =>
            {
                uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t);
                Thread.CurrentThread.Priority = ThreadPriority.Highest;

                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                ModulateUiPriority(true);
                ApplyProcessOptimizations(pid, name);
            });

            IntPtr hProc = IntPtr.Zero;
            Safe.Run("proc_wait", () =>
            {
                hProc = OpenProcess(SYNCHRONIZE, 0, pid);
                if (hProc != IntPtr.Zero) WaitForSingleObject(hProc, -1);
            });
            if (hProc != IntPtr.Zero) Safe.Run("proc_close", () => CloseHandle(hProc));

            ModulateUiPriority(false);
            RestoreResolution();
            PurgeStandbyList();
            GhostMemory();
            Log.Write(string.Format("[proc] {0} exited, cleanup done.", name));
        }

        void ApplyProcessOptimizations(uint pid, string name)
        {
            Safe.Run("proc_opt", () =>
            {
                Process proc = null;
                try { proc = Process.GetProcessById((int)pid); } catch { return; }

                try { proc.PriorityClass        = ProcessPriorityClass.High; } catch { }
                try { proc.PriorityBoostEnabled  = true;                      } catch { }

                if (CpuTopology.AllPCoreMask != 0)
                    try { proc.ProcessorAffinity = (IntPtr)CpuTopology.AllPCoreMask; } catch { }

                Safe.Run("proc_ecoqos", () =>
                {
                    PROCESS_POWER_THROTTLING s;
                    s.Version     = 1;
                    s.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                    s.StateMask   = 0;
                    SetProcessInformation(proc.Handle, ProcessPowerThrottling, ref s,
                        Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
                });

                ApplyToChildren(proc);

                Log.Write(string.Format(
                    "[proc] {0} (pid={1}): priority=high, affinity=0x{2:X}",
                    name, pid, CpuTopology.AllPCoreMask));
            });
        }

        void ApplyToChildren(Process parent)
        {
            Safe.Run("proc_children", () =>
            {
                string q = string.Format(
                    "SELECT * FROM Win32_Process WHERE ParentProcessId={0}", parent.Id);
                using (var searcher = new ManagementObjectSearcher(q))
                {
                    foreach (ManagementObject child in searcher.Get())
                    {
                        uint cpid = 0;
                        try { cpid = (uint)child.Properties["ProcessId"].Value; } catch { continue; }
                        Safe.Run("child_opt", () =>
                        {
                            Process cp = Process.GetProcessById((int)cpid);
                            try { cp.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }
                            if (CpuTopology.AllPCoreMask != 0)
                                try { cp.ProcessorAffinity = (IntPtr)CpuTopology.AllPCoreMask; } catch { }
                        });
                    }
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  AUDIO — IAudioClient3 minimum buffer + glitch detection
        // ══════════════════════════════════════════════════════════════════════
        void StartAudioThread()
        {
            audioThread              = new Thread(AudioWorker);
            audioThread.Name         = "albusbx-audio";
            audioThread.Priority     = ThreadPriority.Highest;
            audioThread.IsBackground = true;
            audioThread.Start();
        }

        void AudioWorker()
        {
            Safe.Run("audio_mmcss",  () => { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); });
            Safe.Run("audio_coinit", () => CoInitializeEx(IntPtr.Zero, COINIT_MULTITHREADED));
            Safe.Run("audio_main",   () =>
            {
                Type t = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(t);
                audioNotifier            = new AudioNotifier();
                audioNotifier.Service    = this;
                audioNotifier.Enumerator = enumerator;
                enumerator.RegisterEndpointNotificationCallback(audioNotifier);
                OptimizeAllEndpoints(enumerator);
            });
            stopEvent.Wait();
        }

        internal void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            Safe.Run("audio_eps", () =>
            {
                Guid IID_AC3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                IMMDeviceCollection col;
                if (enumerator.EnumAudioEndpoints(EDataFlow_eRender, DEVICE_STATE_ACTIVE, out col) != 0) return;
                uint count; col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    uint idx = i;
                    Safe.Run("audio_ep_" + idx, () =>
                    {
                        IMMDevice dev;
                        if (col.Item(idx, out dev) != 0) return;
                        object co;
                        if (dev.Activate(ref IID_AC3, CLSCTX_ALL, IntPtr.Zero, out co) != 0) return;
                        IAudioClient3 client = (IAudioClient3)co;

                        IntPtr pFmt = IntPtr.Zero;
                        if (client.GetMixFormat(out pFmt) != 0) return;

                        uint defF, fundF, minF, maxF;
                        if (client.GetSharedModeEnginePeriod(pFmt, out defF, out fundF, out minF, out maxF) != 0) return;

                        if (minF < defF && minF > 0)
                        {
                            if (client.InitializeSharedAudioStream(0, minF, pFmt, IntPtr.Zero) == 0 &&
                                client.Start() == 0)
                            {
                                lock (audioClients) audioClients.Add(co);
                                WAVEFORMATEX fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pFmt, typeof(WAVEFORMATEX));
                                string devId; dev.GetId(out devId);
                                string sid = (devId != null && devId.Length > 8)
                                    ? devId.Substring(devId.Length - 8) : "?";
                                Log.Write(string.Format(
                                    "[audio] {0}: {1:F3}ms → {2:F3}ms (frames {3}→{4})",
                                    sid,
                                    (defF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    (minF / (double)fmt.nSamplesPerSec) * 1000.0,
                                    defF, minF));

                                // Glitch detector for this endpoint
                                IAudioClient3 glitchClient = client;
                                Thread gd = new Thread(delegate() { GlitchDetector(glitchClient); });
                                gd.Name         = "albusbx-glitch";
                                gd.IsBackground = true;
                                gd.Priority     = ThreadPriority.AboveNormal;
                                gd.Start();
                            }
                        }
                        if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
                    });
                }
            });
        }

        // ── Glitch detector ───────────────────────────────────────────────────
        // FIX: lastPos is now captured properly inside the closure-friendly helper
        //      variables; uses consecutive-zero-padding heuristic + a stall counter
        //      based on elapsed time to detect real underruns vs. silence.
        void GlitchDetector(IAudioClient3 client)
        {
            uint prevPadding        = uint.MaxValue;
            int  consecutiveZero    = 0;
            long lastNonZeroTick    = Stopwatch.GetTimestamp();

            while (!stopEvent.IsSet)
            {
                Thread.Sleep(50);
                Safe.Run("glitch_poll", () =>
                {
                    uint padding;
                    if (client.GetCurrentPadding(out padding) != 0) return;

                    if (padding == 0)
                    {
                        consecutiveZero++;
                        long elapsed = Stopwatch.GetTimestamp() - lastNonZeroTick;
                        double elapsedMs = (elapsed * 1000.0) / Stopwatch.Frequency;

                        // Only flag as glitch if buffer stays empty for > 100 ms
                        // (avoids false positives during intentional silence)
                        if (consecutiveZero >= 2 && elapsedMs > 100.0)
                        {
                            Interlocked.Increment(ref audioGlitchCount);
                            Log.Write(string.Format(
                                "[audio] glitch detected (underrun, silent={0:F0}ms).", elapsedMs));
                            consecutiveZero  = 0;       // reset to avoid spam per stall event
                            lastNonZeroTick  = Stopwatch.GetTimestamp();
                        }
                    }
                    else
                    {
                        consecutiveZero = 0;
                        lastNonZeroTick = Stopwatch.GetTimestamp();
                    }
                    prevPadding = padding;
                });
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  CONFIG / INI
        // ══════════════════════════════════════════════════════════════════════
        void ReadConfig()
        {
            processNames = null;
            customRes    = 0;
            string ini   = Assembly.GetExecutingAssembly().Location + ".ini";
            if (!File.Exists(ini)) return;

            var names = new List<string>();
            foreach (string raw in File.ReadAllLines(ini))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith("//")) continue;
                if (line.ToLowerInvariant().StartsWith("resolution="))
                {
                    uint v;
                    if (uint.TryParse(line.Substring(11).Trim(), out v)) customRes = v;
                    continue;
                }
                foreach (string tok in line.Split(
                    new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string n = tok.ToLowerInvariant().Trim();
                    if (n.Length == 0) continue;
                    if (!n.EndsWith(".exe")) n += ".exe";
                    if (!names.Contains(n)) names.Add(n);
                }
            }
            processNames = names.Count > 0 ? names : null;
        }

        void StartIniWatcher()
        {
            Safe.Run("ini_watch", () =>
            {
                string ini = Assembly.GetExecutingAssembly().Location + ".ini";
                iniWatcher = new FileSystemWatcher(
                    Path.GetDirectoryName(ini), Path.GetFileName(ini));
                iniWatcher.NotifyFilter         = NotifyFilters.LastWrite;
                iniWatcher.Changed             += OnIniChanged;
                iniWatcher.EnableRaisingEvents  = true;
            });
        }

        void OnIniChanged(object s, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            Safe.Run("ini_reload", () =>
            {
                ReadConfig();
                targetRes = customRes > 0 ? customRes : Math.Min(TARGET_RESOLUTION, maxRes);
                if (startWatch != null)
                    try { startWatch.Stop(); startWatch.Dispose(); startWatch = null; } catch { }
                if (processNames != null && processNames.Count > 0) StartEtwWatcher();
                else { SetResolutionVerified(); ModulateUiPriority(true); }
                Log.Write("[ini] config reloaded.");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  P/INVOKE
        // ══════════════════════════════════════════════════════════════════════
        [DllImport("ntdll.dll")] static extern int  NtSetTimerResolution(uint des, bool set, out uint cur);
        [DllImport("ntdll.dll")] static extern int  NtQueryTimerResolution(out uint min, out uint max, out uint cur);
        [DllImport("ntdll.dll")] static extern int  NtSetSystemInformation(int cls, ref int info, int len);
        [DllImport("ntdll.dll")] static extern int  NtQuerySystemInformation(int cls, ref int info, int len, IntPtr ret);

        [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint acc, int inh, uint pid);
        [DllImport("kernel32.dll")] static extern int    WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll")] static extern bool   SetSystemFileCacheSize(IntPtr min, IntPtr max, int fl);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr a, string n, uint f, uint acc);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr h, int cls, ref PROCESS_POWER_THROTTLING info, int sz);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation2(IntPtr h, int cls, ref MEMORY_PRIORITY_INFORMATION info, int sz);
        [DllImport("kernel32.dll")] static extern uint   SetThreadExecutionState(uint f);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessWorkingSetSizeEx(IntPtr h, UIntPtr min, UIntPtr max, uint f);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool   SetThreadPriority(IntPtr h, int p);
        [DllImport("kernel32.dll")] static extern uint   SetThreadIdealProcessor(IntPtr h, uint p);
        [DllImport("kernel32.dll")] static extern bool   SetThreadAffinityMask(IntPtr h, IntPtr mask);
        [DllImport("kernel32.dll")]
        static extern IntPtr VirtualAllocExNuma(IntPtr proc, IntPtr addr, UIntPtr sz,
            uint allocType, uint protect, uint node);
        [DllImport("kernel32.dll")] static extern bool   VirtualFree(IntPtr addr, UIntPtr sz, uint freeType);
        [DllImport("kernel32.dll")] static extern bool   OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
        [DllImport("kernel32.dll")] static extern bool   AdjustTokenPrivileges(IntPtr tok, bool dis,
            ref TOKEN_PRIVILEGES newState, uint bufLen, IntPtr prev, IntPtr retLen);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);

        [DllImport("psapi.dll")]    static extern int    EmptyWorkingSet(IntPtr h);
        [DllImport("avrt.dll")]     static extern IntPtr AvSetMmThreadCharacteristics(string t, ref uint i);
        [DllImport("ole32.dll")]    static extern int    CoInitializeEx(IntPtr p, uint c);
        [DllImport("gdi32.dll")]    static extern int    D3DKMTSetProcessSchedulingPriority(IntPtr h, int p);
        [DllImport("powrprof.dll")]
        static extern uint CallNtPowerInformation(int lvl, IntPtr ib, uint il, IntPtr ob, uint ol);
        [DllImport("qwave.dll")]    static extern bool   QOSCreateHandle(ref QOS_VERSION ver, out IntPtr h);
        [DllImport("qwave.dll")]    static extern bool   QOSCloseHandle(IntPtr h);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr OpenTrace(ref EVENT_TRACE_LOGFILE f);
        [DllImport("advapi32.dll")]
        static extern uint ProcessTrace(IntPtr[] arr, uint cnt, IntPtr s, IntPtr e);
        [DllImport("advapi32.dll")]
        static extern uint CloseTrace(IntPtr h);

        // ── constants ─────────────────────────────────────────────────────────
        const uint SYNCHRONIZE                              = 0x00100000u;
        const uint ES_CONTINUOUS                            = 0x80000000u;
        const uint ES_SYSTEM_REQUIRED                       = 0x00000001u;
        const uint ES_DISPLAY_REQUIRED                      = 0x00000002u;
        const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION    = 0x00000002u;
        const uint TIMER_ALL_ACCESS                         = 0x1F0003u;
        const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE           = 0x00000001u;
        const int  ProcessPowerThrottling                   = 4;
        const int  ProcessMemoryPriority                    = 5;
        const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x4u;
        const int  ProcessorIdleDomains                     = 14;
        const int  DpcBehaviorInfo                          = 24;
        const int  D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME  = 5;
        const int  IrqPolicySpecifiedProcessors             = 4;
        const int  THREAD_PRIORITY_TIME_CRITICAL            = 15;
        const int  EDataFlow_eRender                        = 0;
        const int  DEVICE_STATE_ACTIVE                      = 1;
        const int  CLSCTX_ALL                               = 0x17;
        const uint COINIT_MULTITHREADED                     = 0u;
        const int  PROCESS_TRACE_MODE_REAL_TIME             = 0x00000100;
        const int  PROCESS_TRACE_MODE_EVENT_RECORD          = 0x10000000;
        const uint MEM_COMMIT                               = 0x1000u;
        const uint MEM_RESERVE                              = 0x2000u;
        const uint MEM_RELEASE                              = 0x8000u;
        const uint PAGE_READWRITE                           = 0x04u;
        const uint TOKEN_ADJUST_PRIVILEGES                  = 0x0020u;
        const uint TOKEN_QUERY                              = 0x0008u;
        const uint SE_PRIVILEGE_ENABLED                     = 0x0002u;
        const int  MEMORY_PRIORITY_NORMAL                   = 5;
        static readonly IntPtr INVALID_PROCESSTRACE_HANDLE  = new IntPtr(-1);

        // ── structs ───────────────────────────────────────────────────────────
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING { public uint Version, ControlMask, StateMask; }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORY_PRIORITY_INFORMATION { public int MemoryPriority; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct WAVEFORMATEX
        {
            public ushort wFormatTag, nChannels;
            public uint   nSamplesPerSec, nAvgBytesPerSec;
            public ushort nBlockAlign, wBitsPerSample, cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct QOS_VERSION { public ushort MajorVersion, MinorVersion; }

        [StructLayout(LayoutKind.Sequential)]
        struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
            public LUID_AND_ATTRIBUTES[] Privileges;
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
            public int   BufferSize, Filled, EventsLost;
            public EventRecordCallback EventRecordCallback;
            public uint  IsKernelTrace;
            public IntPtr Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_RECORD
        {
            public EVENT_HEADER       EventHeader;
            public ETW_BUFFER_CONTEXT BufferContext;
            public ushort             ExtendedDataCount;
            public ushort             UserDataLength;
            public IntPtr             ExtendedData;
            public IntPtr             UserData;
            public IntPtr             UserContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct EVENT_HEADER
        {
            public ushort Size, HeaderType, Flags, EventProperty;
            public uint   ThreadId, ProcessId;
            public long   TimeStamp;
            public Guid   ProviderId;
            public ushort Id;
            public byte   Version, Channel, Level, Opcode;
            public ushort Task;
            public ulong  Keyword;
            public uint   KernelTime, UserTime;
            public Guid   ActivityId;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ETW_BUFFER_CONTEXT
        {
            public byte ProcessorNumber, Alignment;
            public ushort LoggerId;
        }

        delegate void EventRecordCallback(ref EVENT_RECORD r);

        // ── COM interfaces ────────────────────────────────────────────────────
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
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int st);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
        }

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
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int acc, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int st);
        }

        [ComImport][Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period, IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long lat);
            [PreserveSig] int GetCurrentPadding(out uint pad);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long def, out long min);
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
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period, IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long lat);
            [PreserveSig] int GetCurrentPadding(out uint pad);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long def, out long min);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int cat, out int cap);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool ev, out long mn, out long mx);
        }

        [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioClient3
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period, IntPtr fmt, IntPtr guid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long lat);
            [PreserveSig] int GetCurrentPadding(out uint pad);
            [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr fmt);
            [PreserveSig] int GetDevicePeriod(out long def, out long min);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr h);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int cat, out int cap);
            [PreserveSig] int SetClientProperties(IntPtr props);
            [PreserveSig] int GetBufferSizeLimits(IntPtr fmt, bool ev, out long mn, out long mx);
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt,
                out uint defPeriod, out uint fundPeriod, out uint minPeriod, out uint maxPeriod);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr fmt, out uint curPeriod);
            [PreserveSig] int InitializeSharedAudioStream(uint flags, uint period, IntPtr fmt, IntPtr guid);
        }

        class AudioNotifier : IMMNotificationClient
        {
            public AlbusBService       Service;
            public IMMDeviceEnumerator Enumerator;

            public int OnDeviceStateChanged(string id, int st) { return 0; }
            public int OnDeviceAdded(string id)                { return 0; }
            public int OnDeviceRemoved(string id)              { return 0; }
            public int OnPropertyValueChanged(string id, IntPtr k) { return 0; }
            public int OnDefaultDeviceChanged(int flow, int role, string id)
            {
                Safe.Run("audio_devchg", () =>
                {
                    if (Service == null) return;
                    Service.Log_("[audio] device changed — re-optimizing.");
                    lock (Service.audioClients) Service.audioClients.Clear();
                    if (Enumerator != null) Service.OptimizeAllEndpoints(Enumerator);
                });
                return 0;
            }
        }

        internal void Log_(string msg) { Log.Write(msg); }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INSTALLER
    // ══════════════════════════════════════════════════════════════════════════
    [RunInstaller(true)]
    public class AlbusBInstaller : Installer
    {
        public AlbusBInstaller()
        {
            ServiceProcessInstaller spi = new ServiceProcessInstaller();
            spi.Account  = ServiceAccount.LocalSystem;
            spi.Username = null;
            spi.Password = null;

            ServiceInstaller si = new ServiceInstaller();
            si.ServiceName  = "AlbusBSvc";
            si.DisplayName  = "AlbusB";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "AlbusB v1.0 — auto topology, NUMA-aware affinity, " +
                "timer, C-state, GPU D3DKMT, audio IAudioClient3, " +
                "memory large-pages, NIC IRQ+QoS, ETW, watchdog, health.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
