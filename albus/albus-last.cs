// ══════════════════════════════════════════════════════════════════════════════
//  AlbusB  v4.8 - Ultimate Zero-Allocation Latency Daemon
//  Thread Pinning · Native Priority Management · GlobalMemoryStatusEx
// ══════════════════════════════════════════════════════════════════════════════

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Management;
using Microsoft.Win32;

[assembly: AssemblyVersion("4.8.0.0")]
[assembly: AssemblyFileVersion("4.8.0.0")]
[assembly: AssemblyProduct("AlbusB")]
[assembly: AssemblyTitle("AlbusB")]
[assembly: AssemblyDescription("precision system latency daemon v4.8")]

namespace AlbusB
{
    // ══════════════════════════════════════════════════════════════════════════
    //  Asenkron Loglama Subsystem
    // ══════════════════════════════════════════════════════════════════════════
    static class Log
    {
        static readonly string LogPath = @"C:\AlbusB\albusbx.log";

        static readonly BlockingCollection<string> Queue =
            new BlockingCollection<string>(new ConcurrentQueue<string>(), 20000);

        static System.Diagnostics.EventLog _eventLog;
        static Thread   _writerThread;
        static volatile bool _stop;

        public static void Init(System.Diagnostics.EventLog ev)
        {
            _eventLog = ev;
            try
            {
                string dir = Path.GetDirectoryName(LogPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 10 * 1024 * 1024)
                {
                    string arch = LogPath + "." + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".bak";
                    File.Move(LogPath, arch);
                }
            }
            catch { }

            _stop         = false;
            _writerThread = new Thread(WriterLoop)
            {
                Name         = "albusbx-log",
                IsBackground = true,
                Priority     = ThreadPriority.BelowNormal
            };
            _writerThread.Start();
        }

        public static void Write(string msg, bool warn = false)
        {
            string line = (warn ? "!" : "*") + "[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + msg;
            try { Queue.TryAdd(line, 0); } catch { }
        }

        public static void Stop()
        {
            _stop = true;
            try { Queue.CompleteAdding(); } catch { }
            if (_writerThread != null) _writerThread.Join(3000);
        }

        static void WriterLoop()
        {
            while (!_stop || Queue.Count > 0)
            {
                try
                {
                    string rawLine;
                    if (!Queue.TryTake(out rawLine, 500)) continue;

                    ProcessLogItem(rawLine);

                    while (Queue.TryTake(out rawLine, 0))
                        ProcessLogItem(rawLine);
                }
                catch (InvalidOperationException) { break; }
                catch { }
            }

            string t;
            while (Queue.TryTake(out t, 0)) ProcessLogItem(t);
        }

        static void ProcessLogItem(string rawLine)
        {
            if (string.IsNullOrEmpty(rawLine)) return;
            bool warn = rawLine[0] == '!';
            string cleanLine = rawLine.Substring(1);

            try { File.AppendAllText(LogPath, cleanLine + Environment.NewLine); } catch { }

            if (_eventLog != null)
            {
                try
                {
                    _eventLog.WriteEntry(cleanLine,
                        warn ? EventLogEntryType.Warning : EventLogEntryType.Information);
                }
                catch { }
            }
        }
    }

    static class Safe
    {
        public static void Run(string tag, Action fn)
        {
            try { fn(); }
            catch (Exception ex) { Log.Write("[" + tag + "] ERROR: " + ex.Message, true); }
        }

        public static T Run<T>(string tag, Func<T> fn, T def = default(T))
        {
            try { return fn(); }
            catch (Exception ex) { Log.Write("[" + tag + "] ERROR: " + ex.Message, true); return def; }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  CPU Topolojisi - Performans (P) ve Verimlilik (E) çekirdeklerini ayırt eder
    // ══════════════════════════════════════════════════════════════════════════
    static class CpuTopology
    {
        public struct CoreInfo
        {
            public byte LogicalIndex;
            public byte EfficiencyClass;
            public byte NumaNode;
            public byte PhysicalCore;
        }

        public static List<CoreInfo> Cores            = new List<CoreInfo>();
        public static byte           MaxEffClass       = 0;
        public static byte           BestNumaNode      = 0;
        public static long           PCoreMask         = 0;
        public static long           AllPCoreMask      = 0;
        public static int            PhysicalCoreCount = 0;
        public static bool           HasMoreThan64     = false;
        public static ulong          Ccd0Mask          = 0;
        public static ulong          Ccd1Mask          = 0;
        public static bool           IsAmdDualCcd      = false;

        public static void Detect()
        {
            Cores.Clear();
            PCoreMask = AllPCoreMask = 0;
            MaxEffClass = BestNumaNode = 0;
            PhysicalCoreCount = 0;
            Ccd0Mask = Ccd1Mask = 0;
            IsAmdDualCcd = false;

            Safe.Run("topo_detect", () =>
            {
                int totalLogical = Environment.ProcessorCount;
                HasMoreThan64    = totalLogical > 64;

                if (HasMoreThan64)
                    Log.Write("[topo] WARNING: >64 logical CPUs. Mask limited to first 64.");

                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0) { FallbackUniform(); return; }

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                    { FallbackUniform(); return; }

                    // En yüksek verimlilik sınıfını bul (P-Cores)
                    for (int off = 0; off < (int)returned; )
                    {
                        int sz = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff = Marshal.ReadByte(buf, off + 18);
                        if (eff > MaxEffClass) MaxEffClass = eff;
                        off += sz;
                    }

                    var physicalSeen = new SimpleHashSet<ulong>();

                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz      = Marshal.ReadInt32(buf, off);
                        if (sz < 24) break;
                        byte eff     = Marshal.ReadByte(buf, off + 18);
                        byte logical = Marshal.ReadByte(buf, off + 14);
                        byte numa    = Marshal.ReadByte(buf, off + 19);
                        byte phys    = Marshal.ReadByte(buf, off + 20);

                        Cores.Add(new CoreInfo
                        {
                            LogicalIndex    = logical,
                            EfficiencyClass = eff,
                            NumaNode        = numa,
                            PhysicalCore    = phys
                        });

                        ulong key = ((ulong)numa << 32) | phys;
                        if (!physicalSeen.Contains(key)) physicalSeen.Add(key);
                        off += sz;
                    }

                    PhysicalCoreCount = physicalSeen.Count;

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

                    // Affinity maskelerini oluştur
                    var usedPhys = new SimpleHashSet<byte>();
                    foreach (var c in Cores)
                    {
                        if (c.EfficiencyClass < MaxEffClass) continue;
                        if (c.NumaNode != BestNumaNode)      continue;
                        if (c.LogicalIndex < 64)
                            AllPCoreMask |= (1L << c.LogicalIndex);
                        if (!usedPhys.Contains(c.PhysicalCore))
                        {
                            if (c.LogicalIndex < 64)
                                PCoreMask |= (1L << c.LogicalIndex);
                            usedPhys.Add(c.PhysicalCore);
                        }
                    }

                    if (MaxEffClass == 0)
                    {
                        usedPhys     = new SimpleHashSet<byte>();
                        PCoreMask    = 0;
                        AllPCoreMask = 0;
                        foreach (var c in Cores)
                        {
                            if (c.LogicalIndex < 64)
                                AllPCoreMask |= (1L << c.LogicalIndex);
                            if (!usedPhys.Contains(c.PhysicalCore))
                            {
                                if (c.LogicalIndex < 64)
                                    PCoreMask |= (1L << c.LogicalIndex);
                                usedPhys.Add(c.PhysicalCore);
                            }
                        }
                        BestNumaNode = 0;
                    }

                    Log.Write(string.Format(
                        "[topo] cpus={0} physical={1} numa={2} effclass={3} " +
                        "pcore_mask=0x{4:X} allpcore_mask=0x{5:X} gt64={6}",
                        Cores.Count, PhysicalCoreCount, BestNumaNode,
                        MaxEffClass, PCoreMask, AllPCoreMask, HasMoreThan64));
                }
                finally { Marshal.FreeHGlobal(buf); }
            });

            Safe.Run("topo_amd", () =>
            {
                string procId = Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? "";
                IsAmdDualCcd = procId.IndexOf("AuthenticAMD", StringComparison.OrdinalIgnoreCase) >= 0 
                               && PhysicalCoreCount >= 12;

                if (IsAmdDualCcd)
                {
                    int half = PhysicalCoreCount / 2;
                    ulong ccd0 = 0;
                    ulong ccd1 = 0;
                    for (int i = 0; i < Cores.Count; i++)
                    {
                        var c = Cores[i];
                        if (c.LogicalIndex >= 64) continue;
                        if (c.PhysicalCore < half)
                            ccd0 |= (1UL << c.LogicalIndex);
                        else
                            ccd1 |= (1UL << c.LogicalIndex);
                    }
                    Ccd0Mask = ccd0;
                    Ccd1Mask = ccd1;
                    Log.Write("[topo] AMD Dual-CCD detected. CCD0 Mask: 0x" + Ccd0Mask.ToString("X") + " CCD1 Mask: 0x" + Ccd1Mask.ToString("X"));
                }
            });
        }

        static void FallbackUniform()
        {
            int n = Math.Min(Environment.ProcessorCount, 64);
            for (byte i = 0; i < n; i++)
            {
                Cores.Add(new CoreInfo { LogicalIndex = i });
                AllPCoreMask |= (1L << i);
                if (i % 2 == 0 || n <= 2) PCoreMask |= (1L << i);
            }
            PhysicalCoreCount = Math.Max(1, n / 2);
            Log.Write("[topo] fallback uniform: " + n + " logical, mask=0x" + PCoreMask.ToString("X"));
        }

        [DllImport("kernel32.dll")]
        static extern bool GetSystemCpuSetInformation(IntPtr info, uint bufLen,
            out uint returned, IntPtr proc, uint flags);

        internal sealed class SimpleHashSet<T>
        {
            readonly Dictionary<T, bool> _d;
            public SimpleHashSet() { _d = new Dictionary<T, bool>(); }
            public SimpleHashSet(IEqualityComparer<T> comparer) { _d = new Dictionary<T, bool>(comparer); }
            public bool Contains(T v) { return _d.ContainsKey(v); }
            public void Add(T v)      { _d[v] = true; }
            public void Clear()       { _d.Clear(); }
            public int Count          { get { return _d.Count; } }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Albus Daemon Servisi
    // ══════════════════════════════════════════════════════════════════════════
    sealed class AlbusBService : ServiceBase
    {
        const string SVC_NAME             = "AlbusXSvc";
        const uint   TARGET_RESOLUTION    = 5000u;       // 0.5ms
        const uint   RES_TOLERANCE        = 50u;
        const int    GUARD_SEC            = 8;
        const int    WATCHDOG_SEC         = 8;
        const int    HEALTH_INITIAL_MIN   = 3;
        const int    HEALTH_INTERVAL_MIN  = 10;
        const int    PURGE_INITIAL_MIN    = 2;
        const int    PURGE_INTERVAL_MIN   = 4;
        const ulong  PURGE_THRESHOLD_BYTES = 1024L * 1024 * 1024; // 1 GB

        uint   defaultRes, minRes, maxRes, targetRes, customRes;
        long   processCounter;
        IntPtr hWaitTimer = IntPtr.Zero;

        Timer guardTimer, purgeTimer, watchdogTimer, healthTimer;

        readonly object _watcherLock = new object();
        ManagementEventWatcher startWatch;

        FileSystemWatcher iniWatcher;
        Thread audioThread, etwThread;
        List<string> processNames;
        CpuTopology.SimpleHashSet<string> processNamesSet;
        int  wmiRetry;
        long dpcBaselineTicks;
        int  audioGlitchCount;
        readonly ManualResetEventSlim stopEvent = new ManualResetEventSlim(false);

        readonly List<AudioClientEntry> audioClients = new List<AudioClientEntry>();
        AudioNotifier audioNotifier;

        internal class AudioClientEntry
        {
            public IAudioClient3 Client;
            public volatile bool Disposed;
        }

        readonly ConcurrentDictionary<int, IntPtr> mmcssHandles =
            new ConcurrentDictionary<int, IntPtr>();

        // Dynamic Active Process Tracking & Background Throttling State
        static readonly object ActiveProcessesLock = new object();
        static readonly List<ActiveGameContext> ActiveGames = new List<ActiveGameContext>();
        static readonly string[] BackgroundHogs = new[] { 
            "chrome", "chrome.exe", 
            "brave", "brave.exe", 
            "discord", "discord.exe", 
            "steamwebhelper", "steamwebhelper.exe", 
            "explorer", "explorer.exe", 
            "epicgameslauncher", "epicgameslauncher.exe", 
            "origin", "origin.exe", 
            "galaxyclient", "galaxyclient.exe", 
            "uplaywebupdater", "uplaywebupdater.exe" 
        };

        struct ThreadTimeCache
        {
            public uint ThreadId;
            public long LastTime;
        }

        static readonly ThreadTimeCache[] threadTimeTable = new ThreadTimeCache[1024];

        static long GetThreadCpuTimeDelta(uint threadId, long totalTime)
        {
            uint size = (uint)threadTimeTable.Length;
            uint hash = threadId & (size - 1);

            for (uint i = 0; i < size; i++)
            {
                uint idx = (hash + i) & (size - 1);
                if (threadTimeTable[idx].ThreadId == threadId)
                {
                    long delta = totalTime - threadTimeTable[idx].LastTime;
                    threadTimeTable[idx].LastTime = totalTime;
                    return delta;
                }
                if (threadTimeTable[idx].ThreadId == 0)
                {
                    threadTimeTable[idx].ThreadId = threadId;
                    threadTimeTable[idx].LastTime = totalTime;
                    return 0;
                }
            }

            threadTimeTable[0].ThreadId = threadId;
            threadTimeTable[0].LastTime = totalTime;
            return 0;
        }

        static void ClearThreadTimeCache()
        {
            for (int i = 0; i < threadTimeTable.Length; i++)
            {
                threadTimeTable[i].ThreadId = 0;
                threadTimeTable[i].LastTime = 0;
            }
        }

        class ActiveGameContext
        {
            public uint ProcessId;
            public string Name;
            public IntPtr ProcessHandle;
            public Thread PinningThread;
            public volatile bool Exited;
        }

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

        protected override void OnStart(string[] args)
        {
            stopEvent.Reset();
            Log.Init(EventLog);
            Log.Write("[albusbx] starting precision daemon v4.8 (zero-allocation)...");

            CpuTopology.Detect();
            SetSelfPriority();
            SetSelfAffinity();

            Safe.Run("threadpool", () =>
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 32), Math.Max(io, 16));
            });

            Safe.Run("gc", () =>
            {
                try { GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency; }
                catch { try { GCSettings.LatencyMode = GCLatencyMode.LowLatency; } catch { } }
            });

            PreJitMethods();

            // Gecikme stabilizasyonu için hassas waitable timer oluştur
            Safe.Run("waittimer", () =>
            {
                hWaitTimer = CreateWaitableTimerExW(IntPtr.Zero, null,
                    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
            });

            // Servis bellek çalışma kümesini kilitle
            Safe.Run("workingset", () =>
                SetProcessWorkingSetSizeEx(
                    GetCurrentProcess(),
                    (UIntPtr)(16  * 1024 * 1024),
                    (UIntPtr)(256 * 1024 * 1024),
                    QUOTA_LIMITS_HARDWS_MIN_ENABLE));

            // MMCSS Ses öncelik modunu servise ata
            ApplyMmcss();
            DisableThrottling();

            Safe.Run("execstate", () =>
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED));

            // Bellek LFH Heap modunu aktif et
            Safe.Run("mem_lfh", () =>
            {
                IntPtr heap = GetProcessHeap();
                uint info = 2; // HEAP_INFORMATION_LFH
                HeapSetInformation(heap, HeapCompatibilityInformation, ref info, sizeof(uint));
                Log.Write("[mem] LFH heap active.");
            });

            ReadConfig();

            // Hassas timer çözünürlüğünü başlat
            NtQueryTimerResolution(out minRes, out maxRes, out defaultRes);
            targetRes = customRes > 0 ? customRes : Math.Min(TARGET_RESOLUTION, maxRes);

            Log.Write(string.Format(
                "[albusbx] timer min={0} max={1} default={2} target={3} ({4:F3}ms)",
                minRes, maxRes, defaultRes, targetRes, targetRes / 10000.0));

            ThreadPool.QueueUserWorkItem(delegate { MeasureDpcBaseline(); });
            OptimizeAudioEngine();

            if (processNames == null || processNames.Count == 0)
            {
                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
            }
            else
            {
                StartEtwWatcher();
            }

            StartGuard();
            StartPurge();
            StartWatchdog();
            StartHealthMonitor();
            StartIniWatcher();
            StartAudioThread();

            GhostMemory();
            Log.Write("[albusbx] all daemon subsystems armed.");
            base.OnStart(args);
        }

        void PreJitMethods()
        {
            Safe.Run("prejit", () =>
            {
                var flags = BindingFlags.DeclaredOnly | BindingFlags.NonPublic | 
                            BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static;
                
                var methods = typeof(AlbusBService).GetMethods(flags);
                for (int i = 0; i < methods.Length; i++)
                {
                    var method = methods[i];
                    if (method.IsGenericMethod || method.ContainsGenericParameters) continue;
                    try { System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle); } catch { }
                }

                var topoMethods = typeof(CpuTopology).GetMethods(flags);
                for (int i = 0; i < topoMethods.Length; i++)
                {
                    var method = topoMethods[i];
                    if (method.IsGenericMethod || method.ContainsGenericParameters) continue;
                    try { System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle); } catch { }
                }

                var logMethods = typeof(Log).GetMethods(flags);
                for (int i = 0; i < logMethods.Length; i++)
                {
                    var method = logMethods[i];
                    if (method.IsGenericMethod || method.ContainsGenericParameters) continue;
                    try { System.Runtime.CompilerServices.RuntimeHelpers.PrepareMethod(method.MethodHandle); } catch { }
                }

                Log.Write("[jit] all daemon methods pre-compiled successfully.");
            });
        }

        protected override void OnStop()
        {
            stopEvent.Set();

            Safe.Run("execstate", () => SetThreadExecutionState(ES_CONTINUOUS));

            foreach (var kv in mmcssHandles)
                Safe.Run("mmcss_revert", () => { if (kv.Value != IntPtr.Zero) AvRevertMmThreadCharacteristics(kv.Value); });
            mmcssHandles.Clear();

            DropTimer(ref guardTimer);
            DropTimer(ref purgeTimer);
            DropTimer(ref watchdogTimer);
            DropTimer(ref healthTimer);

            Safe.Run("watcher_stop", () =>
            {
                ManagementEventWatcher w;
                lock (_watcherLock) { w = startWatch; startWatch = null; }
                if (w != null) { try { w.Stop(); } catch { } try { w.Dispose(); } catch { } }
            });

            Safe.Run("iniwatcher_stop", () =>
            {
                if (iniWatcher != null)
                { iniWatcher.EnableRaisingEvents = false; iniWatcher.Dispose(); }
            });

            Safe.Run("waittimer_stop", () =>
            {
                if (hWaitTimer != IntPtr.Zero) { CloseHandle(hWaitTimer); hWaitTimer = IntPtr.Zero; }
            });

            Safe.Run("audio_com_release", () =>
            {
                lock (audioClients)
                {
                    foreach (var e in audioClients)
                    {
                        e.Disposed = true;
                        try { e.Client.Stop(); } catch { }
                        try { Marshal.ReleaseComObject(e.Client); } catch { }
                    }
                    audioClients.Clear();
                }
            });

            // Aktif oyun threadlerini ve optimizasyonları durdur
            lock (ActiveProcessesLock)
            {
                foreach (var game in ActiveGames)
                {
                    game.Exited = true;
                    if (game.ProcessHandle != IntPtr.Zero)
                    {
                        CloseHandle(game.ProcessHandle);
                        game.ProcessHandle = IntPtr.Zero;
                    }
                }
                ActiveGames.Clear();
            }

            RestoreBackgroundHogs();
            RestoreAudioEngine();

            Safe.Run("timer_restore", () =>
            {
                timeEndPeriod(1);
                uint actual = 0;
                NtSetTimerResolution(defaultRes, true, out actual);
                Log.Write(string.Format("[albusbx] timer restored: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            });

            Log.Write("[albusbx] stopped, dynamic tweaks reversed.");
            Log.Stop();
            base.OnStop();
        }

        protected override void OnShutdown() { Safe.Run("shutdown", () => OnStop()); }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(3000);
                CpuTopology.Detect();
                SetSelfPriority();
                SetSelfAffinity();
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
        //  Self priority / affinity
        // ══════════════════════════════════════════════════════════════════════
        void SetSelfPriority()
        {
            Safe.Run("self_priority", () =>
            {
                IntPtr hProcess = GetCurrentProcess();
                SetPriorityClass(hProcess, REALTIME_PRIORITY_CLASS);
                Thread.CurrentThread.Priority = ThreadPriority.Highest;
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
            });
        }

        void SetSelfAffinity()
        {
            Safe.Run("self_affinity", () =>
            {
                if (CpuTopology.PCoreMask == 0) return;
                IntPtr hProcess = GetCurrentProcess();
                SetProcessAffinityMask(hProcess, (UIntPtr)CpuTopology.PCoreMask);
                
                int ideal = 0;
                for (int i = 0; i < 64; i++)
                    if ((CpuTopology.PCoreMask & (1L << i)) != 0) { ideal = i; break; }
                SetThreadIdealProcessor(GetCurrentThread(), (uint)ideal);
                Log.Write("[cpu] self affinity=0x" + CpuTopology.PCoreMask.ToString("X") + " ideal=" + ideal);
            });
        }

        void ApplyMmcss(string task = "Pro Audio")
        {
            Safe.Run("mmcss_apply", () =>
            {
                uint taskIndex = 0;
                IntPtr h = AvSetMmThreadCharacteristics(task, ref taskIndex);
                if (h != IntPtr.Zero)
                {
                    int tid = GetCurrentThreadId();
                    mmcssHandles[tid] = h;
                    AvSetMmThreadPriority(h, AVRT_PRIORITY_CRITICAL);
                    Log.Write("[mmcss] tid=" + tid + " task=" + task + " CRITICAL");
                }
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
                SetProcessInformation(GetCurrentProcess(),
                    ProcessPowerThrottling, ref s,
                    Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
            });
        }

        void GhostMemory()
        {
            Safe.Run("ghost", () => EmptyWorkingSet(GetCurrentProcess()));
        }

        // ══════════════════════════════════════════════════════════════════════
        //  High-Precision Timer Resolution Lock
        // ══════════════════════════════════════════════════════════════════════
        void SetResolutionVerified()
        {
            long c = Interlocked.Increment(ref processCounter);
            if (c > 1) return;

            uint actual = 0;
            NtSetTimerResolution(targetRes, true, out actual);

            long deadline = Stopwatch.GetTimestamp() + (Stopwatch.Frequency / 50); // 20ms
            for (int i = 0; i < 50; i++)
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RES_TOLERANCE) break;
                if (Stopwatch.GetTimestamp() > deadline) break;

                if (hWaitTimer != IntPtr.Zero)
                {
                    long due = -1000L; // 100µs relative
                    SetWaitableTimerEx(hWaitTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0);
                    WaitForSingleObject(hWaitTimer, 1);
                }
                NtSetTimerResolution(targetRes, true, out actual);
            }

            Log.Write("[timer] lock set: " + actual + " (" + (actual / 10000.0).ToString("F3") + "ms)");
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
                TimeSpan.FromSeconds(GUARD_SEC), TimeSpan.FromSeconds(GUARD_SEC));
        }

        void GuardCallback(object _)
        {
            try
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur <= targetRes + RES_TOLERANCE) return;

                uint actual = 0;
                long deadline = Stopwatch.GetTimestamp() + (Stopwatch.Frequency / 100); // 10ms

                while (Stopwatch.GetTimestamp() < deadline)
                {
                    NtSetTimerResolution(targetRes, true, out actual);
                    NtQueryTimerResolution(out qMin, out qMax, out qCur);
                    if (qCur <= targetRes + RES_TOLERANCE) break;

                    if (hWaitTimer != IntPtr.Zero)
                    {
                        long due = -1000L; // 100µs
                        SetWaitableTimerEx(hWaitTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0);
                        WaitForSingleObject(hWaitTimer, 1);
                    }
                    else
                    {
                        Thread.Sleep(0);
                    }
                }
                Log.Write("[guard] timer drift corrected → " + (actual / 10000.0).ToString("F3") + "ms");
            }
            catch (Exception ex) { Log.Write("[guard] " + ex.Message, true); }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Standby Cache Purger (Bellek Temizleyici via GlobalMemoryStatusEx)
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
                MEMORYSTATUSEX memStatus = new MEMORYSTATUSEX();
                memStatus.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                if (GlobalMemoryStatusEx(ref memStatus))
                {
                    bool isGaming;
                    lock (ActiveProcessesLock)
                    {
                        isGaming = ActiveGames.Count > 0;
                    }

                    // Oyundayken disk ve bellek I/O takılmalarını önlemek için temizlik eşiğini 512MB'a çekiyoruz.
                    // Oyun yokken normal 1.5GB eşiğiyle temizleme yapıyoruz.
                    ulong threshold = isGaming ? (512UL * 1024 * 1024) : (1536UL * 1024 * 1024);

                    if (memStatus.ullAvailPhys < threshold)
                    {
                        PurgeStandbyList();
                        double availMB = memStatus.ullAvailPhys / (1024.0 * 1024.0);
                        Log.Write("[islc] standby purged. gaming=" + isGaming + " available=" + availMB.ToString("F0") + "MB.");
                    }
                }
            });
            GhostMemory();
        }

        void PurgeStandbyList()
        {
            Safe.Run("purge_cache",   () => SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0));
            Safe.Run("purge_standby", () => { int cmd = 4; NtSetSystemInformation(80, ref cmd, sizeof(int)); });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Watchdog
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
                IntPtr self = GetCurrentProcess();
                int prio = GetPriorityClass(self);
                if (prio != REALTIME_PRIORITY_CLASS)
                {
                    Log.Write("[watchdog] priority stolen, restoring.");
                    SetPriorityClass(self, REALTIME_PRIORITY_CLASS);
                }
            });

            Safe.Run("wd_affinity", () =>
            {
                if (CpuTopology.PCoreMask == 0) return;
                IntPtr self = GetCurrentProcess();
                // Basitlik ve sıfır-tahsis için afiniteyi direkt setle
                SetProcessAffinityMask(self, (UIntPtr)CpuTopology.PCoreMask);
            });

            Safe.Run("wd_dwm", () =>
            {
                ForEachProcessByName("dwm", (pid) =>
                {
                    try
                    {
                        IntPtr h = OpenProcess(PROCESS_SET_INFORMATION, false, pid);
                        if (h != IntPtr.Zero)
                        {
                            SetPriorityClass(h, HIGH_PRIORITY_CLASS);
                            CloseHandle(h);
                        }
                    }
                    catch { }
                });
            });

            Safe.Run("wd_audiodg", () =>
            {
                OptimizeAudioEngine();
            });

            Safe.Run("wd_timer", () =>
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur > targetRes + RES_TOLERANCE * 4)
                {
                    uint actual = 0;
                    NtSetTimerResolution(targetRes, true, out actual);
                    Log.Write("[watchdog] timer drifted → corrected.");
                }
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Health Monitor (Jitter / Gecikme Sağlık Takibi)
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

                MEMORYSTATUSEX memStatus = new MEMORYSTATUSEX();
                memStatus.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
                GlobalMemoryStatusEx(ref memStatus);
                double availMB = memStatus.ullAvailPhys / (1024.0 * 1024.0);

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
                double baseUs   = dpcBaselineTicks > 0
                    ? (dpcBaselineTicks * 1000000.0) / Stopwatch.Frequency : 0;
                bool jitterBad  = baseUs > 0 && jitterUs > baseUs * 3.0;

                Log.Write("[health] timer=" + (qCur / 10000.0).ToString("F3") + "ms" +
                          " | ram=" + availMB.ToString("F0") + "MB" +
                          " | jitter=" + jitterUs.ToString("F2") + "µs" +
                          " | glitches=" + audioGlitchCount +
                          (jitterBad ? " | WARNING: high jitter!" : ""));

                if (jitterBad)
                {
                    SetSelfPriority();
                    SetSelfAffinity();
                    SetResolutionVerified();
                    Log.Write("[health] auto-rearm triggered.");
                }
            });
        }

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
                Log.Write("[dpc] baseline jitter: " + us.ToString("F2") + "µs");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  ETW & WMI Süreç İzleyicileri
        // ══════════════════════════════════════════════════════════════════════
        static readonly Guid KernelProcessGuid =
            new Guid("3D6FA8D0-FE05-11D0-9DDA-00C04FD7BA7C");

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
            if (record.EventHeader.ProviderId != KernelProcessGuid) return;
            if (record.EventHeader.Opcode != 1) return;
            if (record.UserDataLength < 24) return;

            try
            {
                bool is64bit   = (record.EventHeader.Flags & 0x40) != 0;
                int nameOffset = is64bit ? 56 : 36;

                if (record.UserDataLength < nameOffset + 2) return;

                uint pid = (uint)Marshal.ReadInt32(record.UserData, 0);
                string img = Marshal.PtrToStringUni(IntPtr.Add(record.UserData, nameOffset));
                if (img == null) return;
                img = System.IO.Path.GetFileName(img);
                if (string.IsNullOrEmpty(img)) return;

                var tgts = processNamesSet;
                if (tgts == null || !tgts.Contains(img)) return;

                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid, img); });
            }
            catch { }
        }

        void StartWmiWatcher()
        {
            string q = string.Format(
                "SELECT * FROM __InstanceCreationEvent WITHIN 2 " +
                "WHERE TargetInstance isa \"Win32_Process\" AND (TargetInstance.Name=\"{0}\")",
                string.Join("\" OR TargetInstance.Name=\"", processNames));

            var w = new ManagementEventWatcher(q);
            w.EventArrived  += OnProcArrived;
            w.Stopped       += OnWatcherStopped;
            w.Start();

            lock (_watcherLock) { startWatch = w; }

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
                ManagementEventWatcher old;
                lock (_watcherLock) { old = startWatch; startWatch = null; }
                if (old != null) { try { old.Dispose(); } catch { } }
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
                string name = proc.Properties["Name"].Value.ToString();
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid, name); });
            });
        }

        void ProcessStarted(uint pid, string name)
        {
            ActiveGameContext gameContext = null;

            Safe.Run("game_init", () =>
            {
                ApplyMmcss();
                Thread.CurrentThread.Priority = ThreadPriority.Highest;

                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();

                IntPtr hProcess = OpenProcess(SYNCHRONIZE | PROCESS_SET_INFORMATION | PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
                if (hProcess != IntPtr.Zero)
                {
                    gameContext = new ActiveGameContext
                    {
                        ProcessId = pid,
                        Name = name,
                        ProcessHandle = hProcess,
                        Exited = false
                    };

                    lock (ActiveProcessesLock)
                    {
                        ActiveGames.Add(gameContext);
                    }

                    // Oyunu REALTIME moduna al ve öncelik artışını etkinleştir
                    SetPriorityClass(hProcess, REALTIME_PRIORITY_CLASS);
                    
                    // P-Core veya AMD CCD0 maskesini ata
                    if (CpuTopology.IsAmdDualCcd && CpuTopology.Ccd0Mask != 0)
                    {
                        SetProcessAffinityMask(hProcess, (UIntPtr)CpuTopology.Ccd0Mask);
                    }
                    else if (CpuTopology.AllPCoreMask != 0)
                    {
                        SetProcessAffinityMask(hProcess, (UIntPtr)CpuTopology.AllPCoreMask);
                    }

                    // EcoQoS (Power Throttling) kapat
                    PROCESS_POWER_THROTTLING powerThrottling;
                    powerThrottling.Version = 1;
                    powerThrottling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                    powerThrottling.StateMask = 0; // Throttling disable
                    SetProcessInformation(hProcess, ProcessPowerThrottling, ref powerThrottling, Marshal.SizeOf(powerThrottling));
                    
                    // Priority boost aktif et (boosting serbest bırak)
                    SetProcessPriorityBoost(hProcess, false);

                    Safe.Run("game_ws_lock", () =>
                    {
                        SetProcessWorkingSetSizeEx(hProcess,
                            (UIntPtr)(256 * 1024 * 1024),
                            (UIntPtr)(32UL * 1024 * 1024 * 1024),
                            QUOTA_LIMITS_HARDWS_MIN_ENABLE);
                    });

                    Safe.Run("purge_file_cache", () =>
                    {
                        SetSystemFileCacheSize((IntPtr)(-1), (IntPtr)(-1), 0);
                    });

                    // Alt süreçleri de önceliklendir
                    ApplyToChildren(pid);

                    // Arka plandaki gereksiz işlemci canavarlarını (Chrome, Brave, Discord vb.) yavaşlat
                    ThrottleBackgroundHogs();

                    // Thread Pinning optimizasyon motorunu bu oyun için başlat
                    Thread pinningThread = new Thread(delegate() { ThreadPinningWorker(gameContext); });
                    pinningThread.Name = "albusbx-pinning-" + name;
                    pinningThread.IsBackground = true;
                    pinningThread.Priority = ThreadPriority.AboveNormal;
                    gameContext.PinningThread = pinningThread;
                    pinningThread.Start();

                    Log.Write("[booster] " + name + " (PID: " + pid + ") launched. RealTime priority & Core affinity applied.");
                }
            });

            if (gameContext != null && gameContext.ProcessHandle != IntPtr.Zero)
            {
                // Süreç sonlanana kadar bekle
                WaitForSingleObject(gameContext.ProcessHandle, -1);
                
                // Kaynakları temizle
                Safe.Run("game_exit_clean", () =>
                {
                    gameContext.Exited = true;
                    lock (ActiveProcessesLock)
                    {
                        ActiveGames.Remove(gameContext);
                        if (ActiveGames.Count == 0)
                        {
                            // Başka aktif oyun kalmadıysa arka plandaki servisleri normale döndür
                            RestoreBackgroundHogs();
                        }
                    }
                    ClearThreadTimeCache();
                    if (gameContext.ProcessHandle != IntPtr.Zero)
                    {
                        CloseHandle(gameContext.ProcessHandle);
                        gameContext.ProcessHandle = IntPtr.Zero;
                    }
                });
            }

            RestoreResolution();
            PurgeStandbyList();
            GhostMemory();
            Log.Write("[proc] " + name + " exited. Priorities restored.");
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Thread Pinning Optimizasyon Döngüsü
        // ══════════════════════════════════════════════════════════════════════
        void ThreadPinningWorker(ActiveGameContext game)
        {
            uint[] tIds = new uint[256];
            int cycle = 0;

            while (!stopEvent.IsSet && !game.Exited)
            {
                int sleepMs = (cycle < 30) ? 500 : 5000;
                cycle++;

                stopEvent.Wait(sleepMs);
                if (stopEvent.IsSet || game.Exited) break;

                Safe.Run("thread_pin", () =>
                {
                    IntPtr hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
                    if (hSnap == new IntPtr(-1) || hSnap == IntPtr.Zero) return;

                    try
                    {
                        THREADENTRY32 te = new THREADENTRY32();
                        te.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));

                        int count = 0;
                        if (Thread32First(hSnap, ref te))
                        {
                            do
                            {
                                if (te.th32OwnerProcessID == game.ProcessId && count < tIds.Length)
                                {
                                    tIds[count] = te.th32ThreadID;
                                    count++;
                                }
                            } while (Thread32Next(hSnap, ref te) && count < tIds.Length);
                        }

                        if (count == 0) return;

                        // En çok CPU kullanan ana iş parçacığını bul (Game Loop / Render Thread)
                        uint mainThreadId = 0;
                        long maxCpuTime = -1;

                        for (int i = 0; i < count; i++)
                        {
                            IntPtr hThread = OpenThread(THREAD_QUERY_INFORMATION, false, tIds[i]);
                            if (hThread != IntPtr.Zero)
                            {
                                long creation, exit, kernel, user;
                                if (GetThreadTimes(hThread, out creation, out exit, out kernel, out user))
                                {
                                    long totalTime = kernel + user;
                                    long delta = GetThreadCpuTimeDelta(tIds[i], totalTime);

                                    if (delta > maxCpuTime)
                                    {
                                        maxCpuTime = delta;
                                        mainThreadId = tIds[i];
                                    }
                                }
                                CloseHandle(hThread);
                            }
                        }

                        // Çekirdek sabitleme işlemlerini uygula
                        // Core 0/1 genellikle OS/Network tarafından kullanıldığı için, Ana thread'i Core 2'ye (Logical Index 4) kilitliyoruz.
                        // Diğer worker threadleri ise kalan P-çekirdeklere (veya AMD CCD0'a) dağıtıyoruz.
                        ulong mainThreadAffinity = 0x10; // Default Core 2 (Logical 4)
                        ulong workerAffinityMask = (ulong)CpuTopology.AllPCoreMask;

                        if (CpuTopology.IsAmdDualCcd && CpuTopology.Ccd0Mask != 0)
                        {
                            workerAffinityMask = CpuTopology.Ccd0Mask;

                            // AMD CCD0 üzerindeki 2. fiziksel çekirdeğin ilk mantıksal thread'ini bul
                            for (int j = 0; j < CpuTopology.Cores.Count; j++)
                            {
                                var c = CpuTopology.Cores[j];
                                if (c.PhysicalCore == 2 && c.LogicalIndex < 64)
                                {
                                    mainThreadAffinity = (1UL << c.LogicalIndex);
                                    break;
                                }
                            }
                        }
                        else if (CpuTopology.Cores.Count > 4)
                        {
                            // Eğer işlemcide P-çekirdekler belirlenmişse, fiziksel 2. P-Core'un ilk mantıksal indeksini bul
                            for (int j = 0; j < CpuTopology.Cores.Count; j++)
                            {
                                var c = CpuTopology.Cores[j];
                                if (c.EfficiencyClass == CpuTopology.MaxEffClass && c.PhysicalCore == 2 && c.LogicalIndex < 64)
                                {
                                    mainThreadAffinity = (1UL << c.LogicalIndex);
                                    break;
                                }
                            }
                        }

                        for (int i = 0; i < count; i++)
                        {
                            IntPtr hThread = OpenThread(THREAD_SET_INFORMATION | THREAD_QUERY_INFORMATION, false, tIds[i]);
                            if (hThread != IntPtr.Zero)
                            {
                                // Thread seviyesinde EcoQoS / Güç kısıtlamasını tamamen devre dışı bırak
                                THREAD_POWER_THROTTLING_STATE threadThrottling = new THREAD_POWER_THROTTLING_STATE();
                                threadThrottling.Version = 1;
                                threadThrottling.ControlMask = 1; // THREAD_POWER_THROTTLING_EXECUTION_SPEED
                                threadThrottling.StateMask = 0;   // Disable throttling (EcoQoS = Off)
                                SetThreadInformation(hThread, ThreadPowerThrottling, ref threadThrottling, Marshal.SizeOf(threadThrottling));

                                if (tIds[i] == mainThreadId)
                                {
                                    // Ana Oyun Loop'unu en izole çekirdeğe sabitle ve önceliğini kritik yap
                                    SetThreadAffinityMask(hThread, (UIntPtr)mainThreadAffinity);
                                    SetThreadPriority(hThread, THREAD_PRIORITY_TIME_CRITICAL);
                                }
                                else
                                {
                                    // Diğer işçileri tüm P-core'lara (veya AMD CCD0'a) dağıt
                                    if (workerAffinityMask != 0)
                                    {
                                        SetThreadAffinityMask(hThread, (UIntPtr)workerAffinityMask);
                                    }
                                    SetThreadPriority(hThread, THREAD_PRIORITY_HIGHEST);
                                }
                                CloseHandle(hThread);
                            }
                        }
                    }
                    finally
                    {
                        CloseHandle(hSnap);
                    }
                });
            }
        }

        void ApplyToChildren(uint parentPid)
        {
            Safe.Run("proc_children", () =>
            {
                IntPtr hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
                if (hSnap == new IntPtr(-1) || hSnap == IntPtr.Zero) return;

                try
                {
                    PROCESSENTRY32 pe = new PROCESSENTRY32();
                    pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

                    if (Process32First(hSnap, ref pe))
                    {
                        do
                        {
                            if (pe.th32ParentProcessID == parentPid)
                            {
                                uint cpid = pe.th32ProcessID;
                                Safe.Run("child_opt", () =>
                                {
                                    IntPtr hChild = OpenProcess(PROCESS_SET_INFORMATION, false, cpid);
                                    if (hChild != IntPtr.Zero)
                                    {
                                        SetPriorityClass(hChild, HIGH_PRIORITY_CLASS);
                                        if (CpuTopology.AllPCoreMask != 0)
                                        {
                                            SetProcessAffinityMask(hChild, (UIntPtr)CpuTopology.AllPCoreMask);
                                        }

                                        // Priority boost aktif et
                                        SetProcessPriorityBoost(hChild, false);

                                        // EcoQoS (Power Throttling) kapat
                                        PROCESS_POWER_THROTTLING powerThrottling;
                                        powerThrottling.Version = 1;
                                        powerThrottling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
                                        powerThrottling.StateMask = 0; // Throttling disable
                                        SetProcessInformation(hChild, ProcessPowerThrottling, ref powerThrottling, Marshal.SizeOf(powerThrottling));

                                        CloseHandle(hChild);
                                    }
                                });
                            }
                        } while (Process32Next(hSnap, ref pe));
                    }
                }
                finally
                {
                    CloseHandle(hSnap);
                }
            });
        }

        delegate void ProcessIdAction(uint pid);

        static void ForEachProcessByName(string name, ProcessIdAction action)
        {
            IntPtr hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (hSnap == new IntPtr(-1) || hSnap == IntPtr.Zero) return;

            string nameWithExe = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
            string nameWithoutExe = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name.Substring(0, name.Length - 4) : name;

            try
            {
                PROCESSENTRY32 pe = new PROCESSENTRY32();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

                if (Process32First(hSnap, ref pe))
                {
                    do
                    {
                        if (pe.szExeFile.Equals(nameWithExe, StringComparison.OrdinalIgnoreCase) || 
                            pe.szExeFile.Equals(nameWithoutExe, StringComparison.OrdinalIgnoreCase))
                        {
                            action(pe.th32ProcessID);
                        }
                    } while (Process32Next(hSnap, ref pe));
                }
            }
            finally
            {
                CloseHandle(hSnap);
            }
        }

        void OptimizeAudioEngine()
        {
            Safe.Run("opt_audiodg", () =>
            {
                ForEachProcessByName("audiodg", (pid) =>
                {
                    try
                    {
                        IntPtr h = OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
                        if (h != IntPtr.Zero)
                        {
                            SetPriorityClass(h, HIGH_PRIORITY_CLASS);
                            if (CpuTopology.AllPCoreMask != 0)
                            {
                                SetProcessAffinityMask(h, (UIntPtr)CpuTopology.AllPCoreMask);
                            }
                            CloseHandle(h);
                        }
                    }
                    catch { }
                });
            });
        }

        void RestoreAudioEngine()
        {
            Safe.Run("restore_audiodg", () =>
            {
                ForEachProcessByName("audiodg", (pid) =>
                {
                    try
                    {
                        IntPtr h = OpenProcess(PROCESS_SET_INFORMATION, false, pid);
                        if (h != IntPtr.Zero)
                        {
                            SetPriorityClass(h, NORMAL_PRIORITY_CLASS);
                            CloseHandle(h);
                        }
                    }
                    catch { }
                });
            });
        }

        static bool IsBackgroundHog(string exeName)
        {
            for (int i = 0; i < BackgroundHogs.Length; i++)
            {
                if (exeName.Equals(BackgroundHogs[i], StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        void SetBackgroundHogsPriority(uint priorityClass, uint memoryPriority, uint ioPriority)
        {
            IntPtr hSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (hSnap == new IntPtr(-1) || hSnap == IntPtr.Zero) return;

            try
            {
                PROCESSENTRY32 pe = new PROCESSENTRY32();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

                if (Process32First(hSnap, ref pe))
                {
                    do
                    {
                        if (IsBackgroundHog(pe.szExeFile))
                        {
                            try
                            {
                                IntPtr h = OpenProcess(PROCESS_SET_INFORMATION, false, pe.th32ProcessID);
                                if (h != IntPtr.Zero)
                                {
                                    SetPriorityClass(h, priorityClass);

                                    MEMORY_PRIORITY_INFORMATION memInfo;
                                    memInfo.MemoryPriority = memoryPriority;
                                    SetProcessInformation(h, ProcessMemoryPriority, ref memInfo, Marshal.SizeOf(memInfo));

                                    IO_PRIORITY_INFO ioInfo;
                                    ioInfo.IoPriority = ioPriority;
                                    SetProcessInformation(h, ProcessIoPriority, ref ioInfo, Marshal.SizeOf(ioInfo));

                                    CloseHandle(h);
                                }
                            }
                            catch { }
                        }
                    } while (Process32Next(hSnap, ref pe));
                }
            }
            finally
            {
                CloseHandle(hSnap);
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Arka Plan Süreçlerini Yavaşlatma / Throttling (Zero-Allocation)
        // ══════════════════════════════════════════════════════════════════════
        void ThrottleBackgroundHogs()
        {
            Safe.Run("throttle_bg", () =>
            {
                SetBackgroundHogsPriority(BELOW_NORMAL_PRIORITY_CLASS, 1, 0); // Bellek: 1 (Çok Düşük), IO: 0 (Çok Düşük)
                Log.Write("[booster] Background processes throttled to BelowNormal, Low Memory & Low I/O Priority.");
            });
        }

        void RestoreBackgroundHogs()
        {
            Safe.Run("restore_bg", () =>
            {
                SetBackgroundHogsPriority(NORMAL_PRIORITY_CLASS, 5, 2); // Bellek: 5 (Normal), IO: 2 (Normal)
                Log.Write("[booster] Background processes restored to Normal priority.");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Hassas WASAPI Audio Optimizasyonu
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
            Safe.Run("audio_mmcss",  () => ApplyMmcss());
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
                        if (dev.Activate(ref IID_AC3, CLSCTX_ALL, IntPtr.Zero, out co) != 0)
                        { try { Marshal.ReleaseComObject(dev); } catch { } return; }

                        IAudioClient3 client = (IAudioClient3)co;

                        IntPtr pFmt = IntPtr.Zero;
                        if (client.GetMixFormat(out pFmt) != 0)
                        { try { Marshal.ReleaseComObject(client); } catch { }
                          try { Marshal.ReleaseComObject(dev);    } catch { } return; }

                        uint defF, fundF, minF, maxF;
                        if (client.GetSharedModeEnginePeriod(pFmt, out defF, out fundF,
                                out minF, out maxF) != 0)
                        { if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
                          try { Marshal.ReleaseComObject(client); } catch { }
                          try { Marshal.ReleaseComObject(dev);    } catch { } return; }

                        if (minF < defF && minF > 0)
                        {
                            if (client.InitializeSharedAudioStream(0, minF, pFmt, IntPtr.Zero) == 0 &&
                                client.Start() == 0)
                            {
                                var entry = new AudioClientEntry { Client = client, Disposed = false };
                                lock (audioClients) audioClients.Add(entry);

                                WAVEFORMATEX fmt = (WAVEFORMATEX)Marshal.PtrToStructure(
                                    pFmt, typeof(WAVEFORMATEX));
                                string devId; dev.GetId(out devId);
                                string sid = (devId != null && devId.Length > 8)
                                    ? devId.Substring(devId.Length - 8) : "?";
                                Log.Write("[audio] " + sid + ": " +
                                    ((defF / (double)fmt.nSamplesPerSec) * 1000.0).ToString("F3") +
                                    "ms → " +
                                    ((minF / (double)fmt.nSamplesPerSec) * 1000.0).ToString("F3") + "ms");

                                var capturedEntry = entry;
                                Thread gd = new Thread(delegate() { GlitchDetector(capturedEntry); });
                                gd.Name = "albusbx-glitch"; gd.IsBackground = true;
                                gd.Priority = ThreadPriority.AboveNormal;
                                gd.Start();
                            }
                            else { try { Marshal.ReleaseComObject(client); } catch { } }
                        }
                        else { try { Marshal.ReleaseComObject(client); } catch { } }

                        if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
                        try { Marshal.ReleaseComObject(dev); } catch { }
                    });
                }
                try { Marshal.ReleaseComObject(col); } catch { }
            });
        }

        void GlitchDetector(AudioClientEntry entry)
        {
            int  consecutiveZero = 0;
            long lastNonZeroTick = Stopwatch.GetTimestamp();

            while (!stopEvent.IsSet && !entry.Disposed)
            {
                stopEvent.Wait(100);
                if (stopEvent.IsSet || entry.Disposed) break;

                try
                {
                    uint padding;
                    int hr = entry.Client.GetCurrentPadding(out padding);
                    if (hr != 0 || entry.Disposed) break;

                    if (padding == 0)
                    {
                        consecutiveZero++;
                        long   elapsed   = Stopwatch.GetTimestamp() - lastNonZeroTick;
                        double elapsedMs = (elapsed * 1000.0) / Stopwatch.Frequency;

                        if (consecutiveZero >= 2 && elapsedMs > 150.0)
                        {
                            Interlocked.Increment(ref audioGlitchCount);
                            Log.Write("[audio] glitch: underrun silent=" +
                                      elapsedMs.ToString("F0") + "ms");
                            consecutiveZero = 0;
                            lastNonZeroTick = Stopwatch.GetTimestamp();
                        }
                    }
                    else
                    {
                        consecutiveZero = 0;
                        lastNonZeroTick = Stopwatch.GetTimestamp();
                    }
                }
                catch { break; }
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        //  Config + ini watcher
        // ══════════════════════════════════════════════════════════════════════
        void ReadConfig()
        {
            processNames = null;
            customRes    = 0;
            
            string loc = Assembly.GetExecutingAssembly().Location;
            string ini = loc + ".ini";
            if (!File.Exists(ini))
            {
                string dir = Path.GetDirectoryName(loc);
                ini = Path.Combine(dir, "AlbusX.exe.ini");
                if (!File.Exists(ini)) ini = Path.Combine(dir, "AlbusB.exe.ini");
            }
            
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
            if (names.Count > 0)
            {
                processNames = names;
                processNamesSet = new CpuTopology.SimpleHashSet<string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < names.Count; i++)
                {
                    processNamesSet.Add(names[i]);
                }
            }
            else
            {
                processNames = null;
                processNamesSet = null;
            }
        }

        void StartIniWatcher()
        {
            Safe.Run("ini_watch", () =>
            {
                string loc = Assembly.GetExecutingAssembly().Location;
                string ini = loc + ".ini";
                if (!File.Exists(ini))
                {
                    string dir = Path.GetDirectoryName(loc);
                    ini = Path.Combine(dir, "AlbusX.exe.ini");
                    if (!File.Exists(ini)) ini = Path.Combine(dir, "AlbusB.exe.ini");
                }
                
                if (!File.Exists(ini)) return;
                
                iniWatcher = new FileSystemWatcher(
                    Path.GetDirectoryName(ini), Path.GetFileName(ini));
                iniWatcher.NotifyFilter        = NotifyFilters.LastWrite;
                iniWatcher.Changed            += OnIniChanged;
                iniWatcher.EnableRaisingEvents = true;
            });
        }

        void OnIniChanged(object s, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            Safe.Run("ini_reload", () =>
            {
                ReadConfig();
                targetRes = customRes > 0 ? customRes : Math.Min(TARGET_RESOLUTION, maxRes);

                ManagementEventWatcher old;
                lock (_watcherLock) { old = startWatch; startWatch = null; }
                if (old != null) { try { old.Stop(); old.Dispose(); } catch { } }

                if (processNames != null && processNames.Count > 0) StartEtwWatcher();
                else { SetResolutionVerified(); }
                Log.Write("[ini] config reloaded.");
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        //  P/Invoke ve Bildirimler
        // ══════════════════════════════════════════════════════════════════════
        [DllImport("ntdll.dll")] static extern int  NtSetTimerResolution(uint des, bool set, out uint cur);
        [DllImport("ntdll.dll")] static extern int  NtQueryTimerResolution(out uint min, out uint max, out uint cur);
        [DllImport("ntdll.dll")] static extern int  NtSetSystemInformation(int cls, ref int info, int len);

        [DllImport("kernel32.dll", SetLastError = true)] static extern bool   CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
        [DllImport("kernel32.dll")] static extern int    WaitForSingleObject(IntPtr h, int ms);
        [DllImport("kernel32.dll")] static extern bool   SetSystemFileCacheSize(IntPtr min, IntPtr max, int fl);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr a, string n, uint f, uint acc);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern bool SetWaitableTimerEx(IntPtr h, ref long due, int period,
            IntPtr comp, IntPtr arg, IntPtr reason, uint tolerableDelay);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr h, int cls,
            ref PROCESS_POWER_THROTTLING info, int sz);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr h, int cls,
            ref MEMORY_PRIORITY_INFORMATION info, int sz);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessInformation(IntPtr h, int cls,
            ref IO_PRIORITY_INFO info, int sz);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessPriorityBoost(IntPtr hProcess, bool disablePriorityBoost);
        [DllImport("kernel32.dll")] static extern uint   SetThreadExecutionState(uint f);
        [DllImport("kernel32.dll")]
        static extern bool SetProcessWorkingSetSizeEx(IntPtr h, UIntPtr min, UIntPtr max, uint f);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll")] static extern bool   SetThreadPriority(IntPtr h, int p);
        [DllImport("kernel32.dll")] static extern uint   SetThreadIdealProcessor(IntPtr h, uint p);
        [DllImport("kernel32.dll")] static extern int  GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr GetProcessHeap();
        [DllImport("kernel32.dll")]
        static extern bool HeapSetInformation(IntPtr heap, int infoClass,
            ref uint info, int infoLength);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

        // Native Process Priority & Thread Affinity
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);
        [DllImport("kernel32.dll", SetLastError = true)] static extern int  GetPriorityClass(IntPtr hProcess);
        [DllImport("kernel32.dll", SetLastError = true)] static extern UIntPtr SetProcessAffinityMask(IntPtr hProcess, UIntPtr dwProcessAffinityMask);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint dwDesiredAccess, bool bInheritHandle, uint dwThreadId);
        [DllImport("kernel32.dll", SetLastError = true)] static extern UIntPtr SetThreadAffinityMask(IntPtr hThread, UIntPtr dwThreadAffinityMask);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetThreadTimes(IntPtr hThread, out long lpCreationTime, out long lpExitTime, out long lpKernelTime, out long lpUserTime);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetThreadInformation(IntPtr hThread, int threadInformationClass, ref THREAD_POWER_THROTTLING_STATE threadInformation, int threadInformationSize);

        // Snapshot ve Thread/Process Entegrasyonu
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Thread32First(IntPtr hSnapshot, ref THREADENTRY32 lpte);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Thread32Next(IntPtr hSnapshot, ref THREADENTRY32 lpte);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        // GlobalMemoryStatusEx P/Invoke
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr OpenTrace(ref EVENT_TRACE_LOGFILE f);
        [DllImport("advapi32.dll")]
        static extern uint ProcessTrace(IntPtr[] arr, uint cnt, IntPtr s, IntPtr e);
        [DllImport("advapi32.dll")]
        static extern uint CloseTrace(IntPtr h);

        [DllImport("psapi.dll")]    static extern int    EmptyWorkingSet(IntPtr h);
        [DllImport("avrt.dll")]     static extern IntPtr AvSetMmThreadCharacteristics(string t, ref uint i);
        [DllImport("avrt.dll")]     static extern bool   AvRevertMmThreadCharacteristics(IntPtr h);
        [DllImport("avrt.dll")]     static extern bool   AvSetMmThreadPriority(IntPtr h, int priority);
        [DllImport("ole32.dll")]    static extern int    CoInitializeEx(IntPtr p, uint c);
        [DllImport("winmm.dll")]    static extern uint timeBeginPeriod(uint p);
        [DllImport("winmm.dll")]    static extern uint timeEndPeriod(uint p);

        // Sabitler
        const uint SYNCHRONIZE                              = 0x00100000u;
        const uint PROCESS_SET_INFORMATION                  = 0x0200u;
        const uint PROCESS_SET_QUOTA                        = 0x0100u;
        const uint PROCESS_QUERY_LIMITED_INFORMATION        = 0x1000u;
        const uint THREAD_SET_INFORMATION                   = 0x0020u;
        const uint THREAD_QUERY_INFORMATION                 = 0x0040u;
        const uint TH32CS_SNAPTHREAD                        = 0x00000004u;
        const uint TH32CS_SNAPPROCESS                       = 0x00000002u;

        const uint REALTIME_PRIORITY_CLASS                  = 0x00000100u;
        const uint HIGH_PRIORITY_CLASS                      = 0x00000080u;
        const uint BELOW_NORMAL_PRIORITY_CLASS              = 0x00004000u;
        const uint NORMAL_PRIORITY_CLASS                    = 0x00000020u;

        const uint ES_CONTINUOUS                            = 0x80000000u;
        const uint ES_SYSTEM_REQUIRED                       = 0x00000001u;
        const uint ES_DISPLAY_REQUIRED                      = 0x00000002u;
        const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION    = 0x00000002u;
        const uint TIMER_ALL_ACCESS                         = 0x1F0003u;
        const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE           = 0x00000001u;
        const int  ProcessPowerThrottling                   = 4;
        const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x4u;
        const int  ThreadPowerThrottling                    = 3;
        const int  ProcessMemoryPriority                     = 39;
        const int  ProcessIoPriority                         = 2;
        const int  THREAD_PRIORITY_TIME_CRITICAL            = 15;
        const int  THREAD_PRIORITY_HIGHEST                  = 2;
        const int  EDataFlow_eRender                        = 0;
        const int  DEVICE_STATE_ACTIVE                      = 1;
        const int  CLSCTX_ALL                               = 0x17;
        const uint COINIT_MULTITHREADED                     = 0u;
        const int  PROCESS_TRACE_MODE_REAL_TIME             = 0x00000100;
        const int  PROCESS_TRACE_MODE_EVENT_RECORD          = 0x10000000;
        const int  HeapCompatibilityInformation             = 0;
        const int  AVRT_PRIORITY_CRITICAL                   = 2;
        static readonly IntPtr INVALID_PROCESSTRACE_HANDLE  = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING { public uint Version, ControlMask, StateMask; }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORY_PRIORITY_INFORMATION { public uint MemoryPriority; }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_PRIORITY_INFO { public uint IoPriority; }

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

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
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

        [StructLayout(LayoutKind.Sequential)]
        struct THREADENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ThreadID;
            public uint th32OwnerProcessID;
            public int  tpBasePri;
            public int  tpDeltaPri;
            public uint dwFlags;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
        struct PROCESSENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int  pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct THREAD_POWER_THROTTLING_STATE
        {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

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
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role,
                [MarshalAs(UnmanagedType.LPWStr)] string id);
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
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int acc, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int st);
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

            long _lastReopt = 0;

            public int OnDeviceStateChanged(string id, int st) { return 0; }
            public int OnDeviceAdded(string id)                { return 0; }
            public int OnDeviceRemoved(string id)              { return 0; }
            public int OnPropertyValueChanged(string id, IntPtr k) { return 0; }

            public int OnDefaultDeviceChanged(int flow, int role, string id)
            {
                long now = Stopwatch.GetTimestamp();
                long debounce = (long)(Stopwatch.Frequency * 0.5); // 500ms
                long prev = Interlocked.Exchange(ref _lastReopt, now);
                if (now - prev < debounce) return 0;

                Safe.Run("audio_devchg", () =>
                {
                    if (Service == null) return;
                    Service.Log_("[audio] default endpoint changed — re-optimizing streams.");
                    lock (Service.audioClients)
                    {
                        foreach (var e in Service.audioClients)
                        {
                            e.Disposed = true;
                            try { Marshal.ReleaseComObject(e.Client); } catch { }
                        }
                        Service.audioClients.Clear();
                    }
                    if (Enumerator != null) Service.OptimizeAllEndpoints(Enumerator);
                });
                return 0;
            }
        }

        internal void Log_(string msg) { Log.Write(msg); }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Servis Kurulumu
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
            si.ServiceName  = "AlbusXSvc";
            si.DisplayName  = "AlbusX";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "AlbusB v4.8 — ultimate zero-allocation latency daemon. " +
                "Enforces 0.5ms timer resolution, locks scheduling stability, " +
                "optimizes WASAPI audio periods, purges standby list under memory pressure, " +
                "throttles background tasks, and performs dynamic thread-level core pinning.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
