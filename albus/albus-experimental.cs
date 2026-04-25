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

[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]
[assembly: AssemblyInformationalVersion("2.0.0")]
[assembly: AssemblyProduct("AlbusX")]
[assembly: AssemblyDescription("albus core engine 2.0 — precision timer, audio latency, memory, interrupt affinity, game profiles")]
[assembly: AssemblyCopyright("oqullcan")]

namespace AlbusCore
{
    // —————————————————————————————————————————————————————————————————————————
    // game profiles
    // —————————————————————————————————————————————————————————————————————————

    static class GameProfiles
    {
        public class Profile
        {
            public string   Name;
            public string[] Executables;
            public bool     LockWorkingSet;
            public bool     MmcssInject;
            public bool     BoostPriority;
            public int      AffinityIsolateFromCore; // -1 = no isolation
        }

        public static readonly Profile[] All = new[]
        {
            new Profile
            {
                Name                    = "cs2",
                Executables             = new[] { "cs2.exe" },
                LockWorkingSet          = true,
                MmcssInject             = true,
                BoostPriority           = true,
                AffinityIsolateFromCore = 0
            },
            new Profile
            {
                Name                    = "apex",
                Executables             = new[] { "r5apex.exe", "r5apex_dx12.exe" },
                LockWorkingSet          = true,
                MmcssInject             = true,
                BoostPriority           = true,
                AffinityIsolateFromCore = 0
            },
            new Profile
            {
                Name                    = "lol",
                Executables             = new[] { "league of legends.exe", "leagueclient.exe" },
                LockWorkingSet          = true,
                MmcssInject             = true,
                BoostPriority           = false,
                AffinityIsolateFromCore = -1
            },
            new Profile
            {
                Name                    = "rust",
                Executables             = new[] { "rustclient.exe" },
                LockWorkingSet          = true,
                MmcssInject             = true,
                BoostPriority           = true,
                AffinityIsolateFromCore = 0
            }
        };

        public static Profile Resolve(string exeName)
        {
            string lower = exeName.ToLower();
            foreach (var p in All)
                foreach (var exe in p.Executables)
                    if (exe == lower) return p;
            return null;
        }

        public static string[] AllExecutables()
        {
            var list = new List<string>();
            foreach (var p in All)
                foreach (var exe in p.Executables)
                    if (!list.Contains(exe)) list.Add(exe);
            return list.ToArray();
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // structured logger
    // —————————————————————————————————————————————————————————————————————————

    static class Log
    {
        static readonly string LogPath  = @"C:\Albus\albusx.log";
        static readonly object FileLock = new object();
        static System.Diagnostics.EventLog _ev;

        public static void Init(System.Diagnostics.EventLog ev)
        {
            _ev = ev;
            try
            {
                string dir = Path.GetDirectoryName(LogPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            }
            catch { }
        }

        public static void Write(string engine, string evt, string detail = null)
        {
            string ts  = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
            string msg = detail != null
                ? "[" + engine + "] " + evt + " \u2014 " + detail
                : "[" + engine + "] " + evt;
            string json = detail != null
                ? "{\"ts\":\"" + ts + "\",\"engine\":\"" + engine + "\",\"event\":\"" + evt + "\",\"detail\":\"" + Esc(detail) + "\"}"
                : "{\"ts\":\"" + ts + "\",\"engine\":\"" + engine + "\",\"event\":\"" + evt + "\"}";

            try { if (_ev != null) _ev.WriteEntry(msg); } catch { }
            lock (FileLock) { try { File.AppendAllText(LogPath, json + "\n"); } catch { } }
        }

        static string Esc(string s)
        {
            if (s == null) return "";
            return s.Replace("\"", "\\\"").Replace("\n", " ");
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // engine interface
    // —————————————————————————————————————————————————————————————————————————

    interface IEngine
    {
        string   Name          { get; }
        DateTime LastHeartbeat { get; }
        void Start();
        void Stop();
    }

    // —————————————————————————————————————————————————————————————————————————
    // service entry
    // —————————————————————————————————————————————————————————————————————————

    class AlbusService : ServiceBase
    {
        TimerEngine     _timer;
        AudioEngine     _audio;
        MemoryEngine    _memory;
        InterruptEngine _interrupt;
        ProcessEngine   _process;
        WatchdogEngine  _watchdog;

        public AlbusService()
        {
            ServiceName                 = "AlbusXSvc";
            EventLog.Log                = "Application";
            CanStop                     = true;
            CanHandlePowerEvent         = true;
            CanHandleSessionChangeEvent = false;
            CanPauseAndContinue         = false;
            CanShutdown                 = true;
        }

        static void Main() { ServiceBase.Run(new AlbusService()); }

        protected override void OnStart(string[] args)
        {
            Log.Init(EventLog);

            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; }              catch { }
            try { GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency; }         catch { }
            try { uint i = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref i); } catch { }
            try
            {
                var s = new NativeMethods.PROCESS_POWER_THROTTLING_STATE
                    { Version = 1, ControlMask = 0x4, StateMask = 0 };
                NativeMethods.SetProcessInformation(
                    Process.GetCurrentProcess().Handle, 4, ref s, Marshal.SizeOf(s));
            } catch { }
            try { NativeMethods.SetThreadExecutionState(0x80000003); } catch { }
            try { NativeMethods.VirtualLock(
                Process.GetCurrentProcess().Handle, (UIntPtr)Environment.WorkingSet); } catch { }

            _timer     = new TimerEngine();
            _audio     = new AudioEngine();
            _memory    = new MemoryEngine();
            _interrupt = new InterruptEngine();
            _process   = new ProcessEngine();
            _watchdog  = new WatchdogEngine(
                new IEngine[] { _timer, _audio, _memory, _interrupt, _process });

            _timer.Start();
            _audio.Start();
            _memory.Start();
            _interrupt.Start();
            _process.Start();
            _watchdog.Start();

            Log.Write("service", "started", "albusx 2.0.0");
        }

        protected override void OnStop()
        {
            try { NativeMethods.SetThreadExecutionState(0x80000000); } catch { }
            if (_watchdog  != null) _watchdog.Stop();
            if (_process   != null) _process.Stop();
            if (_interrupt != null) _interrupt.Stop();
            if (_memory    != null) _memory.Stop();
            if (_audio     != null) _audio.Stop();
            if (_timer     != null) _timer.Stop();
            Log.Write("service", "stopped");
        }

        protected override void OnShutdown() { OnStop(); }

        protected override bool OnPowerEvent(PowerBroadcastStatus status)
        {
            if (status == PowerBroadcastStatus.ResumeSuspend ||
                status == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2000);
                if (_timer     != null) _timer.ForceReapply();
                if (_interrupt != null) _interrupt.Reapply();
                if (_memory    != null) _memory.Purge("resume");
                Log.Write("service", "resume", "re-applied after sleep");
            }
            return true;
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // watchdog — restarts any engine silent >60s
    // —————————————————————————————————————————————————————————————————————————

    class WatchdogEngine
    {
        readonly IEngine[] _engines;
        Timer _timer;

        public WatchdogEngine(IEngine[] engines) { _engines = engines; }

        public void Start()
        {
            _timer = new Timer(Tick, null,
                TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));
        }

        public void Stop() { if (_timer != null) _timer.Dispose(); }

        void Tick(object state)
        {
            foreach (var e in _engines)
            {
                try
                {
                    double age = (DateTime.UtcNow - e.LastHeartbeat).TotalSeconds;
                    if (age > 60)
                    {
                        Log.Write("watchdog", "restart",
                            "engine=" + e.Name + " silent=" + age.ToString("F0") + "s");
                        try { e.Stop(); } catch { }
                        Thread.Sleep(500);
                        try { e.Start(); } catch { }
                    }
                }
                catch { }
            }
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // timer engine 2.0
    // —————————————————————————————————————————————————————————————————————————

    class TimerEngine : IEngine
    {
        public string Name { get { return "timer"; } }

        private DateTime _lastHeartbeat = DateTime.UtcNow;
        public DateTime LastHeartbeat   { get { return _lastHeartbeat; } }

        uint _min, _max, _default, _target;
        long _passiveDrifts, _externalOverrides, _hwDrifts;

        Timer         _guardTimer;
        Thread        _precisionThread;
        IntPtr        _hTimer  = IntPtr.Zero;
        volatile bool _running = false;

        const int  GUARD_MS        = 5000;
        const uint DRIFT_TOLERANCE = 500;   // 50 µs in 100-ns units
        const int  CLASS_181       = 181;   // timer coalescing

        public void Start()
        {
            uint reserved, current;
            NativeMethods.NtQueryTimerResolution(out _min, out _max, out reserved, out current);
            _default = current;
            _target  = _max;

            DisableCoalescing();
            Apply();
            HoldTimer();
            StartPrecisionThread();
            StartGuard();

            Log.Write("timer", "started",
                "min=" + _min + " max=" + _max + " default=" + _default + " target=" + _target);
        }

        public void Stop()
        {
            _running = false;
            if (_guardTimer      != null) _guardTimer.Dispose();
            if (_precisionThread != null) _precisionThread.Join(1000);

            if (_hTimer != IntPtr.Zero)
            {
                try { NativeMethods.CloseHandle(_hTimer); } catch { }
                _hTimer = IntPtr.Zero;
            }

            try
            {
                uint a = 0;
                NativeMethods.NtSetTimerResolution(_default, true, out a);
                Log.Write("timer", "restored", "resolution=" + a);
            } catch { }
        }

        public void ForceReapply()
        {
            uint a;
            Apply(out a);
            Log.Write("timer", "force-reapply", "actual=" + a);
        }

        void DisableCoalescing()
        {
            try
            {
                int v = 1;
                NativeMethods.NtSetSystemInformation(CLASS_181, ref v, sizeof(int));
                Log.Write("timer", "coalescing-disabled");
            }
            catch { Log.Write("timer", "coalescing-skip", "unsupported on this kernel"); }
        }

        void HoldTimer()
        {
            try
            {
                _hTimer = NativeMethods.CreateWaitableTimerExW(
                    IntPtr.Zero, null,
                    0x00000002,   // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
                    0x1F0003);
            } catch { }
        }

        void StartPrecisionThread()
        {
            _running         = true;
            _precisionThread = new Thread(() =>
            {
                try { uint i = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref i); } catch { }
                try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch { }
                try { NativeMethods.SetThreadIdealProcessor(NativeMethods.GetCurrentThread(), 1); } catch { }

                long oneMs = -10000L; // 1 ms in 100-ns negative units

                while (_running)
                {
                    try
                    {
                        NativeMethods.NtDelayExecution(false, ref oneMs);

                        long deadline = Stopwatch.GetTimestamp() +
                            (long)(Stopwatch.Frequency * 0.00005);
                        while (Stopwatch.GetTimestamp() < deadline)
                            Thread.SpinWait(10);

                        _lastHeartbeat = DateTime.UtcNow;
                    }
                    catch { }
                }
            })
            { IsBackground = true, Priority = ThreadPriority.Highest };
            _precisionThread.Start();
        }

        void StartGuard()
        {
            _guardTimer = new Timer(Tick, null,
                TimeSpan.FromMilliseconds(GUARD_MS),
                TimeSpan.FromMilliseconds(GUARD_MS));
        }

        void Tick(object state)
        {
            try
            {
                uint d1, d2, d3, actual;
                NativeMethods.NtQueryTimerResolution(out d1, out d2, out d3, out actual);

                if (actual > _target + DRIFT_TOLERANCE)
                {
                    uint corrected;
                    Apply(out corrected);

                    string type;
                    if (actual > _default + 5000)
                    {
                        type = "hardware-event";
                        Interlocked.Increment(ref _hwDrifts);
                    }
                    else if (actual > _target + 2000)
                    {
                        type = "external-override";
                        Interlocked.Increment(ref _externalOverrides);
                    }
                    else
                    {
                        type = "passive-drift";
                        Interlocked.Increment(ref _passiveDrifts);
                    }

                    Log.Write("timer", "drift-corrected",
                        "type=" + type + " actual=" + actual + " corrected=" + corrected +
                        " passive=" + _passiveDrifts + " override=" + _externalOverrides +
                        " hw=" + _hwDrifts);
                }

                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }

        void Apply() { uint dummy; Apply(out dummy); }

        void Apply(out uint actual)
        {
            actual = 0;
            try
            {
                for (int i = 0; i < 10; i++)
                {
                    NativeMethods.NtSetTimerResolution(_target, true, out actual);
                    uint d1, d2, d3, q;
                    NativeMethods.NtQueryTimerResolution(out d1, out d2, out d3, out q);
                    if (q <= _target + DRIFT_TOLERANCE) break;
                    Thread.SpinWait(5000);
                }
            }
            catch { }
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // audio engine 2.0
    // —————————————————————————————————————————————————————————————————————————

    class AudioEngine : IEngine
    {
        public string Name { get { return "audio"; } }

        private DateTime _lastHeartbeat = DateTime.UtcNow;
        public DateTime LastHeartbeat   { get { return _lastHeartbeat; } }

        readonly List<object> _clients = new List<object>();
        readonly object       _lock    = new object();

        IMMDeviceEnumerator _enum;
        AudioNotifier       _notifier;
        Thread              _thread;
        volatile bool       _running;

        public void Start()
        {
            _running = true;
            _thread  = new Thread(Worker) { IsBackground = true, Priority = ThreadPriority.Highest };
            _thread.Start();
        }

        public void Stop()
        {
            _running = false;
            lock (_lock) { Release(); }
        }

        void Worker()
        {
            try { uint i = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref i); } catch { }
            try { NativeMethods.CoInitializeEx(IntPtr.Zero, 0); } catch { }

            try
            {
                _enum = (IMMDeviceEnumerator)Activator.CreateInstance(
                    Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));

                _notifier = new AudioNotifier(() =>
                {
                    Thread.Sleep(800);
                    lock (_lock) { Release(); OptimizeAll(); }
                    Log.Write("audio", "hot-swap", "re-optimized all endpoints");
                });

                _enum.RegisterEndpointNotificationCallback(_notifier);
                lock (_lock) { OptimizeAll(); }
            }
            catch (Exception ex) { Log.Write("audio", "init-failed", ex.Message); }

            while (_running) { Thread.Sleep(1000); _lastHeartbeat = DateTime.UtcNow; }
        }

        void OptimizeAll()
        {
            try
            {
                var iid = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                IMMDeviceCollection col;
                _enum.EnumAudioEndpoints(2, 1, out col);
                uint count;
                col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    try
                    {
                        IMMDevice dev;
                        col.Item(i, out dev);
                        object obj;
                        dev.Activate(ref iid, 0x17, IntPtr.Zero, out obj);
                        var client = (IAudioClient3)obj;

                        IntPtr pFmt;
                        client.GetMixFormat(out pFmt);
                        var fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pFmt, typeof(WAVEFORMATEX));
                        uint def, dummy1, min, dummy2;
                        client.GetSharedModeEnginePeriod(pFmt, out def, out dummy1, out min, out dummy2);

                        if (min < def && min > 0 &&
                            client.InitializeSharedAudioStream(0, min, pFmt, IntPtr.Zero) == 0 &&
                            client.Start() == 0)
                        {
                            _clients.Add(obj);
                            double minMs = (min / (double)fmt.nSamplesPerSec) * 1000.0;
                            double defMs = (def / (double)fmt.nSamplesPerSec) * 1000.0;
                            Log.Write("audio", "optimized",
                                defMs.ToString("F2") + "ms\u2192" + minMs.ToString("F2") +
                                "ms frames=" + def + "\u2192" + min);
                        }

                        Marshal.FreeCoTaskMem(pFmt);
                    }
                    catch { }
                }

                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }

        void Release()
        {
            foreach (var c in _clients)
            {
                try { ((IAudioClient3)c).Stop();  } catch { }
                try { ((IAudioClient3)c).Reset(); } catch { }
                try { Marshal.ReleaseComObject(c); } catch { }
            }
            _clients.Clear();
        }

        public static void InjectMmcss(int pid)
        {
            try
            {
                foreach (ProcessThread t in Process.GetProcessById(pid).Threads)
                {
                    IntPtr h = NativeMethods.OpenThread(0x0060, false, (uint)t.Id);
                    if (h == IntPtr.Zero) continue;
                    try   { uint idx = 0; NativeMethods.AvSetMmThreadCharacteristics("Pro Audio", ref idx); }
                    finally { NativeMethods.CloseHandle(h); }
                }
                Log.Write("audio", "mmcss-injected", "pid=" + pid);
            }
            catch { }
        }

        class AudioNotifier : IMMNotificationClient
        {
            readonly Action _cb;
            public AudioNotifier(Action cb) { _cb = cb; }
            public int OnDeviceStateChanged(string id, int s)          { try { _cb(); } catch { } return 0; }
            public int OnDeviceAdded(string id)                        { try { _cb(); } catch { } return 0; }
            public int OnDeviceRemoved(string id)                      { try { _cb(); } catch { } return 0; }
            public int OnDefaultDeviceChanged(int f, int r, string id) { try { _cb(); } catch { } return 0; }
            public int OnPropertyValueChanged(string id, IntPtr k)     { return 0; }
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // memory engine 2.0
    // —————————————————————————————————————————————————————————————————————————

    class MemoryEngine : IEngine
    {
        public string Name { get { return "memory"; } }

        private DateTime _lastHeartbeat = DateTime.UtcNow;
        public DateTime LastHeartbeat   { get { return _lastHeartbeat; } }

        Timer _timer;
        const long THRESHOLD_MB = 1024;

        public void Start()
        {
            Trim();
            _timer = new Timer(Tick, null,
                TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5));
        }

        public void Stop() { if (_timer != null) _timer.Dispose(); }

        public void Purge(string reason)
        {
            try { NativeMethods.SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); } catch { }
            try { int cmd = 4; NativeMethods.NtSetSystemInformation(80, ref cmd, sizeof(int)); } catch { }
            Trim();
            Log.Write("memory", "purged", "reason=" + reason);
        }

        public static void LockWorkingSet(int pid)
        {
            try
            {
                var proc = Process.GetProcessById(pid);
                long ws  = proc.WorkingSet64;
                NativeMethods.SetProcessWorkingSetSizeEx(
                    proc.Handle,
                    (IntPtr)ws,
                    (IntPtr)(ws * 2),
                    0x00000001 | 0x00000002);
                Log.Write("memory", "ws-locked",
                    "pid=" + pid + " size=" + (ws / 1024 / 1024) + "mb");
            }
            catch { }
        }

        public static void UnlockWorkingSet(int pid)
        {
            try
            {
                var proc = Process.GetProcessById(pid);
                NativeMethods.SetProcessWorkingSetSizeEx(
                    proc.Handle, (IntPtr)(-1), (IntPtr)(-1), 0);
                Log.Write("memory", "ws-unlocked", "pid=" + pid);
            }
            catch { }
        }

        void Tick(object state)
        {
            try
            {
                var pc      = new PerformanceCounter("Memory", "Available MBytes");
                float avail = pc.NextValue();
                pc.Dispose();

                if (avail < THRESHOLD_MB)
                    Purge("threshold avail=" + avail.ToString("F0") + "mb");
                else
                    Trim();

                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }

        void Trim()
        {
            try { NativeMethods.EmptyWorkingSet(Process.GetCurrentProcess().Handle); } catch { }
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // interrupt engine 2.0
    // —————————————————————————————————————————————————————————————————————————

    class InterruptEngine : IEngine
    {
        public string Name { get { return "interrupt"; } }

        private DateTime _lastHeartbeat = DateTime.UtcNow;
        public DateTime LastHeartbeat   { get { return _lastHeartbeat; } }

        Timer _guardTimer;
        Timer _dpcTimer;

        public void Start()
        {
            Reapply();

            _guardTimer = new Timer(delegate(object state)
            {
                Reapply();
                _lastHeartbeat = DateTime.UtcNow;
            }, null,
            TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));

            _dpcTimer = new Timer(DpcTick, null,
                TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(10));

            Log.Write("interrupt", "started");
        }

        public void Stop()
        {
            if (_guardTimer != null) _guardTimer.Dispose();
            if (_dpcTimer   != null) _dpcTimer.Dispose();
        }

        public void Reapply() { SetAffinity(); }

        void SetAffinity()
        {
            try
            {
                string basePath = @"SYSTEM\CurrentControlSet\Enum";
                using (var root = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(basePath))
                {
                    if (root == null) return;
                    foreach (string bus in root.GetSubKeyNames())
                    {
                        if (!bus.StartsWith("PCI") && !bus.StartsWith("USB")) continue;
                        using (var busKey = root.OpenSubKey(bus))
                        {
                            if (busKey == null) continue;
                            foreach (string dev in busKey.GetSubKeyNames())
                            {
                                try
                                {
                                    string path = basePath + "\\" + bus + "\\" + dev +
                                        "\\Device Parameters\\Interrupt Management\\Affinity Policy";
                                    using (var k = Microsoft.Win32.Registry.LocalMachine.CreateSubKey(path, true))
                                    {
                                        if (k == null) continue;
                                        k.SetValue("AssignmentSetOverride",
                                            new byte[] { 0x01, 0, 0, 0, 0, 0, 0, 0 },
                                            Microsoft.Win32.RegistryValueKind.Binary);
                                        k.SetValue("AffinityPolicyOverride", 4,
                                            Microsoft.Win32.RegistryValueKind.DWord);
                                    }
                                }
                                catch { }
                            }
                        }
                    }
                }
            }
            catch { }
        }

        void DpcTick(object state)
        {
            try
            {
                int size = 48 * Environment.ProcessorCount;
                var buf  = new byte[size];
                int returned;
                int ret  = NativeMethods.NtQuerySystemInformationRaw(8, buf, size, out returned);

                if (ret == 0)
                {
                    long total = 0;
                    for (int i = 0; i < Environment.ProcessorCount; i++)
                        total += BitConverter.ToInt64(buf, i * 48 + 24);

                    if (total > 5000)
                        Log.Write("interrupt", "dpc-elevated", "total=" + total);
                }

                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // process engine 2.0
    // —————————————————————————————————————————————————————————————————————————

    class ProcessEngine : IEngine
    {
        public string Name { get { return "process"; } }

        private DateTime _lastHeartbeat = DateTime.UtcNow;
        public DateTime LastHeartbeat   { get { return _lastHeartbeat; } }

        System.Management.ManagementEventWatcher _startW;
        System.Management.ManagementEventWatcher _stopW;

        readonly Dictionary<int, GameProfiles.Profile> _active =
            new Dictionary<int, GameProfiles.Profile>();
        readonly object _lock = new object();

        int _retry;
        const int MAX_RETRY = 20;

        public void Start()
        {
            Connect();
            Log.Write("process", "started",
                "watching=" + string.Join(",", GameProfiles.AllExecutables()));
        }

        public void Stop()
        {
            Disconnect();
            lock (_lock) { _active.Clear(); }
        }

        void Connect()
        {
            try
            {
                string exes = string.Join(
                    "\" OR TargetInstance.Name=\"",
                    GameProfiles.AllExecutables());

                string sq = "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 " +
                            "WHERE TargetInstance ISA \"Win32_Process\" " +
                            "AND (TargetInstance.Name=\"" + exes + "\")";

                string eq = "SELECT * FROM __InstanceDeletionEvent WITHIN 0.5 " +
                            "WHERE TargetInstance ISA \"Win32_Process\" " +
                            "AND (TargetInstance.Name=\"" + exes + "\")";

                _startW = new System.Management.ManagementEventWatcher(sq);
                _stopW  = new System.Management.ManagementEventWatcher(eq);

                _startW.EventArrived += OnProcessStart;
                _stopW.EventArrived  += OnProcessStop;
                _startW.Stopped      += OnDrop;
                _stopW.Stopped       += OnDrop;

                _startW.Start();
                _stopW.Start();
                _retry = 0;
            }
            catch (Exception ex)
            {
                Log.Write("process", "wmi-connect-failed", ex.Message);
                Reconnect();
            }
        }

        void Disconnect()
        {
            try { if (_startW != null) { _startW.Stop(); _startW.Dispose(); } } catch { }
            try { if (_stopW  != null) { _stopW.Stop();  _stopW.Dispose();  } } catch { }
        }

        void OnDrop(object s, System.Management.StoppedEventArgs e)
        {
            Log.Write("process", "wmi-dropped");
            Reconnect();
        }

        void Reconnect()
        {
            if (_retry >= MAX_RETRY) { Log.Write("process", "wmi-gave-up"); return; }
            int delay = Math.Min(3000 * (1 << _retry), 60000);
            _retry++;
            new Timer(delegate(object state) { Disconnect(); Connect(); }, null, delay, Timeout.Infinite);
            Log.Write("process", "wmi-reconnect", "delay=" + delay + "ms attempt=" + _retry);
        }

        void OnProcessStart(object s, System.Management.EventArrivedEventArgs e)
        {
            try
            {
                var proc    = (System.Management.ManagementBaseObject)e.NewEvent["TargetInstance"];
                uint pid    = (uint)proc["ProcessId"];
                string name = ((string)proc["Name"]).ToLower();
                var profile = GameProfiles.Resolve(name);
                if (profile == null) return;

                Thread.Sleep(1500);
                Apply((int)pid, profile);
                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }

        void OnProcessStop(object s, System.Management.EventArrivedEventArgs e)
        {
            try
            {
                var proc = (System.Management.ManagementBaseObject)e.NewEvent["TargetInstance"];
                uint pid = (uint)proc["ProcessId"];
                Revert((int)pid);
                _lastHeartbeat = DateTime.UtcNow;
            }
            catch { }
        }

        void Apply(int pid, GameProfiles.Profile p)
        {
            try
            {
                var proc = Process.GetProcessById(pid);

                if (p.BoostPriority)
                    proc.PriorityClass = ProcessPriorityClass.High;

                if (p.LockWorkingSet)
                    MemoryEngine.LockWorkingSet(pid);

                if (p.MmcssInject)
                    AudioEngine.InjectMmcss(pid);

                if (p.AffinityIsolateFromCore >= 0 && Environment.ProcessorCount > 1)
                {
                    long mask = 0;
                    for (int i = 0; i < Environment.ProcessorCount; i++)
                        if (i != p.AffinityIsolateFromCore) mask |= (1L << i);
                    proc.ProcessorAffinity = (IntPtr)mask;
                }

                foreach (var d in Process.GetProcessesByName("dwm"))
                    try { d.PriorityClass = ProcessPriorityClass.High; } catch { }
                foreach (var exp in Process.GetProcessesByName("explorer"))
                    try { exp.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }

                lock (_lock) { _active[pid] = p; }

                Log.Write("process", "game-start",
                    "game=" + p.Name + " pid=" + pid +
                    " boost=" + p.BoostPriority +
                    " ws-lock=" + p.LockWorkingSet +
                    " mmcss=" + p.MmcssInject +
                    " affinity-isolated=" + (p.AffinityIsolateFromCore >= 0));
            }
            catch (Exception ex) { Log.Write("process", "apply-failed", ex.Message); }
        }

        void Revert(int pid)
        {
            GameProfiles.Profile p;
            lock (_lock)
            {
                if (!_active.TryGetValue(pid, out p)) return;
                _active.Remove(pid);
            }

            if (p.LockWorkingSet) MemoryEngine.UnlockWorkingSet(pid);

            bool anyActive;
            lock (_lock) { anyActive = _active.Count > 0; }

            if (!anyActive)
            {
                foreach (var exp in Process.GetProcessesByName("explorer"))
                    try { exp.PriorityClass = ProcessPriorityClass.Normal; } catch { }
            }

            Log.Write("process", "game-exit", "game=" + p.Name + " pid=" + pid);
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // native methods
    // —————————————————————————————————————————————————————————————————————————

    static class NativeMethods
    {
        [DllImport("ntdll.dll")]
        public static extern int NtSetTimerResolution(uint desired, bool set, out uint current);

        [DllImport("ntdll.dll")]
        public static extern int NtQueryTimerResolution(
            out uint min, out uint max, out uint reserved, out uint actual);

        [DllImport("ntdll.dll")]
        public static extern int NtSetSystemInformation(int cls, ref int info, int len);

        [DllImport("ntdll.dll")]
        public static extern int NtDelayExecution(bool alertable, ref long interval);

        [DllImport("ntdll.dll", EntryPoint = "NtQuerySystemInformation")]
        public static extern int NtQuerySystemInformationRaw(
            int cls, [Out] byte[] buf, int len, out int returned);

        [DllImport("kernel32.dll")]
        public static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);

        [DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint flags);

        [DllImport("kernel32.dll")]
        public static extern bool SetProcessInformation(
            IntPtr h, int cls, ref PROCESS_POWER_THROTTLING_STATE info, int size);

        [DllImport("kernel32.dll")]
        public static extern bool SetProcessWorkingSetSizeEx(
            IntPtr h, IntPtr min, IntPtr max, uint flags);

        [DllImport("kernel32.dll")]
        public static extern IntPtr CreateWaitableTimerExW(
            IntPtr attr, string name, uint flags, uint access);

        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentThread();

        [DllImport("kernel32.dll")]
        public static extern int SetThreadIdealProcessor(IntPtr h, int proc);

        [DllImport("kernel32.dll")]
        public static extern IntPtr OpenThread(uint access, bool inherit, uint tid);

        [DllImport("kernel32.dll")]
        public static extern bool VirtualLock(IntPtr addr, UIntPtr size);

        [DllImport("psapi.dll")]
        public static extern int EmptyWorkingSet(IntPtr h);

        [DllImport("avrt.dll")]
        public static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint index);

        [DllImport("ole32.dll")]
        public static extern int CoInitializeEx(IntPtr reserved, uint mode);

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_POWER_THROTTLING_STATE
        {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
        }
    }

    // —————————————————————————————————————————————————————————————————————————
    // com interfaces
    // —————————————————————————————————————————————————————————————————————————

    [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint n);
        [PreserveSig] int Item(uint i, out IMMDevice dev);
    }

    [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p,
            [MarshalAs(UnmanagedType.IUnknown)] out object obj);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection col);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
        [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient cb);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient cb);
    }

    [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMNotificationClient
    {
        [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
        [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDefaultDeviceChanged(
            int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnPropertyValueChanged(
            [MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
    }

    [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient3
    {
        [PreserveSig] int Initialize(int mode, uint flags, long dur, long period, IntPtr fmt, IntPtr session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr fmt);
        [PreserveSig] int GetDevicePeriod(out long def, out long min);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr h);
        [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
        [PreserveSig] int IsOffloadCapable(int cat, out int capable);
        [PreserveSig] int SetClientProperties(IntPtr props);
        [PreserveSig] int GetSharedModeEnginePeriod(
            IntPtr fmt, out uint def, out uint fund, out uint min, out uint max);
        [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr fmt, out uint period);
        [PreserveSig] int InitializeSharedAudioStream(
            uint flags, uint period, IntPtr fmt, IntPtr session);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint   nSamplesPerSec;
        public uint   nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    // —————————————————————————————————————————————————————————————————————————
    // installer
    // —————————————————————————————————————————————————————————————————————————

    [RunInstaller(true)]
    public class AlbusInstaller : Installer
    {
        public AlbusInstaller()
        {
            var spi = new ServiceProcessInstaller { Account = ServiceAccount.LocalSystem };
            var si  = new ServiceInstaller
            {
                ServiceName = "AlbusXSvc",
                DisplayName = "AlbusX",
                Description = "albus core engine 2.0 — precision timer, audio latency, memory, interrupt affinity, game profiles",
                StartType   = ServiceStartMode.Automatic
            };
            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
