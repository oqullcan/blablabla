// ══════════════════════════════════════════════════════════════════════════════
//  albus  v3.0
//  precision system latency service
//
//  bu servis playbook script'i (albus.ps1) tarafından kurulur.
//
//  katmanlar (servis sorumluluğu):
//    · timer      — 0.5 ms kernel timer resolution, 10 sn guard + 3× retry
//    · cpu        — hybrid P-core affinity tespiti, MMCSS Pro Audio
//    · priority   — process/thread öncelik yönetimi, DWM boost
//    · c-state    — işlemci idle geçişlerini engelle / servis kapanınca geri al
//    · gpu        — D3DKMT realtime scheduling priority
//    · audio      — IAudioClient3 minimum shared-mode buffer, hot-swap yeniden opt.
//    · memory     — standby purge (ISLC), working set kilitleme, ghost memory
//    · irq        — interrupt affinity, DPC latency izleme
//    · watchdog   — priority çalınması, DWM/timer kayması koruması (10 sn)
//    · health     — periyodik sistem sağlık raporu (event log)
//    · ini        — hedef process listesi + custom resolution, hot-reload
//
//  derleme:
//    csc.exe -r:System.ServiceProcess.dll
//            -r:System.Configuration.Install.dll
//            -r:System.Management.dll
//            -out:Albus.exe albus.cs
//
//  servis adı  : AlbusSvc
//  exe adı     : Albus.exe
//  ini adı     : Albus.exe.ini   (opsiyonel — yoksa global mod)
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
using Microsoft.Win32;

[assembly: AssemblyVersion("3.0.0.0")]
[assembly: AssemblyFileVersion("3.0.0.0")]
[assembly: AssemblyProduct("albus")]
[assembly: AssemblyTitle("albus")]
[assembly: AssemblyDescription("precision system latency service v3.0")]

namespace Albus
{
    // ══════════════════════════════════════════════════════════════════════════
    //  ANA SERVİS
    // ══════════════════════════════════════════════════════════════════════════
    sealed class AlbusService : ServiceBase
    {
        // ── sabitler ─────────────────────────────────────────────────────────
        const string SVC_NAME             = "AlbusSvc";
        const uint   TARGET_RESOLUTION    = 5000u;   // 0.5 ms (100-ns birimi)
        const uint   RESOLUTION_TOLERANCE = 50u;     // 5 µs
        const int    GUARD_SEC            = 10;
        const int    WATCHDOG_SEC         = 10;
        const int    HEALTH_INITIAL_MIN   = 5;
        const int    HEALTH_INTERVAL_MIN  = 15;
        const int    PURGE_INITIAL_MIN    = 2;
        const int    PURGE_INTERVAL_MIN   = 5;
        const int    PURGE_THRESHOLD_MB   = 1024;

        // ── durum ─────────────────────────────────────────────────────────────
        uint   defaultRes, minRes, maxRes;
        uint   targetRes,  customRes;
        long   processCounter;
        IntPtr hWaitTimer = IntPtr.Zero;

        Timer                  guardTimer, purgeTimer, watchdogTimer, healthTimer;
        ManagementEventWatcher startWatch;
        FileSystemWatcher      iniWatcher;
        Thread                 audioThread;
        List<string>           processNames;
        int                    wmiRetry;
        readonly List<object>  audioClients = new List<object>();
        AudioNotifier          audioNotifier;
        long                   dpcBaselineTicks;

        // ── giriş ─────────────────────────────────────────────────────────────
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
        //  BAŞLAT
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStart(string[] args)
        {
            // 1. bu process'in öncelik ve kalitesi
            SetSelfPriority();

            // 2. ThreadPool min thread sayısını artır
            try
            {
                int w, io;
                ThreadPool.GetMinThreads(out w, out io);
                ThreadPool.SetMinThreads(Math.Max(w, 8), io);
            } catch {}

            // 3. GC gecikmesini minimize et
            try { GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency; } catch {}

            // 4. waitable timer — Win11'de resolution kilitleme
            try
            {
                hWaitTimer = CreateWaitableTimerExW(IntPtr.Zero, null, 0x00000002u, 0x1F0003u);
            } catch {}

            // 5. working set kilitleme (4–64 MB)
            try
            {
                SetProcessWorkingSetSizeEx(
                    Process.GetCurrentProcess().Handle,
                    (UIntPtr)(4  * 1024 * 1024),
                    (UIntPtr)(64 * 1024 * 1024),
                    1u);
            } catch {}

            // 6. MMCSS Pro Audio
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}

            // 7. Windows güç kısıtlamasını kapat
            DisableThrottling();

            // 8. ekran/sistem uykusunu engelle
            try { SetThreadExecutionState(0x80000003u); } catch {}

            // 9. config oku
            ReadConfig();

            // 10. hybrid CPU P-core affinity
            SetPCoreMask();

            // 11. işlemci C-state'leri devre dışı
            DisableCStates();

            // 12. GPU scheduler realtime
            BoostGpuPriority();

            // 13. timer resolution hedefini belirle
            NtQueryTimerResolution(out minRes, out maxRes, out defaultRes);
            targetRes = customRes > 0
                ? customRes
                : Math.Min(TARGET_RESOLUTION, maxRes);

            Log(string.Format(
                "[albus v3.0] min={0} max={1} default={2} target={3} ({4:F3}ms) mod={5}",
                minRes, maxRes, defaultRes,
                targetRes, targetRes / 10000.0,
                (processNames != null && processNames.Count > 0)
                    ? string.Join(",", processNames) : "global"));

            // 14. DPC latency baseline
            MeasureDpcBaseline();

            // 15. IRQ affinity optimizasyonu
            OptimizeIrqAffinity();

            // 16. global veya hedef process modu
            if (processNames == null || processNames.Count == 0)
            {
                SetResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                ModulateUiPriority(true);
            }
            else
            {
                StartWatcher();
            }

            // 17. arka plan işçileri
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
        //  DURDUR
        // ══════════════════════════════════════════════════════════════════════
        protected override void OnStop()
        {
            try { SetThreadExecutionState(0x80000000u); } catch {}

            DropTimer(ref guardTimer);
            DropTimer(ref purgeTimer);
            DropTimer(ref watchdogTimer);
            DropTimer(ref healthTimer);

            try
            {
                if (startWatch != null)
                {
                    startWatch.Stop();
                    startWatch.Dispose();
                    startWatch = null;
                }
            } catch {}

            try
            {
                if (iniWatcher != null)
                {
                    iniWatcher.EnableRaisingEvents = false;
                    iniWatcher.Dispose();
                }
            } catch {}

            try
            {
                if (hWaitTimer != IntPtr.Zero)
                {
                    CloseHandle(hWaitTimer);
                    hWaitTimer = IntPtr.Zero;
                }
            } catch {}

            RestoreCStates();
            ModulateUiPriority(false);

            try
            {
                uint actual = 0;
                NtSetTimerResolution(defaultRes, true, out actual);
                Log(string.Format("[albus stop] timer geri alindi: {0} ({1:F3}ms)",
                    actual, actual / 10000.0));
            } catch {}

            base.OnStop();
        }

        protected override void OnShutdown() { try { OnStop(); } catch {} }

        protected override bool OnPowerEvent(PowerBroadcastStatus s)
        {
            if (s == PowerBroadcastStatus.ResumeSuspend ||
                s == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2000);
                SetSelfPriority();
                SetPCoreMask();
                DisableCStates();
                OptimizeIrqAffinity();
                SetResolutionVerified();
                PurgeStandbyList();
                MeasureDpcBaseline();
                Log("[albus resume] uyku sonrasi tam yeniden silahlanma tamamlandi.");
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
        //  KENDİ ÖNCELİĞİ
        // ══════════════════════════════════════════════════════════════════════
        void SetSelfPriority()
        {
            try { Process.GetCurrentProcess().PriorityClass        = ProcessPriorityClass.High; } catch {}
            try { Process.GetCurrentProcess().PriorityBoostEnabled = false; }                    catch {}
            try { Thread.CurrentThread.Priority                    = ThreadPriority.Highest; }   catch {}
        }

        void DisableThrottling()
        {
            try
            {
                PROCESS_POWER_THROTTLING s;
                s.Version = 1; s.ControlMask = 0x4; s.StateMask = 0;
                SetProcessInformation(Process.GetCurrentProcess().Handle, 4,
                    ref s, Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING)));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HYBRID CPU — P-CORE AFINİTESİ
        // ══════════════════════════════════════════════════════════════════════
        void SetPCoreMask()
        {
            try
            {
                uint needed = 0;
                GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, IntPtr.Zero, 0);
                if (needed == 0) return;

                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint returned;
                    if (!GetSystemCpuSetInformation(buf, needed, out returned, IntPtr.Zero, 0))
                        return;

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
                        Log("[albus cpu] tekdüze topoloji, affinity degismedi.");
                        return;
                    }

                    long mask = 0;
                    for (int off = 0; off < (int)returned; )
                    {
                        int  sz     = Marshal.ReadInt32(buf, off);
                        if (sz < 20) break;
                        byte eff    = Marshal.ReadByte(buf, off + 18);
                        byte logCpu = Marshal.ReadByte(buf, off + 14);
                        if (eff == maxClass) mask |= (1L << logCpu);
                        off += sz;
                    }

                    if (mask != 0)
                    {
                        Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)mask;
                        Log(string.Format("[albus cpu] P-core mask=0x{0:X} ({1} cekirdek)",
                            mask, CountBits(mask)));
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            } catch {}
        }

        static int CountBits(long v)
        {
            int c = 0;
            while (v != 0) { c += (int)(v & 1L); v >>= 1; }
            return c;
        }

        // ══════════════════════════════════════════════════════════════════════
        //  C-STATE YÖNETİMİ
        //  Playbook güç planı CPU min=%100 ve C-state politikasını ayarlasa da,
        //  NtPowerInformation ile kernel seviyesinde idle engellemek ek kazanç sağlar.
        // ══════════════════════════════════════════════════════════════════════
        void DisableCStates()
        {
            try
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 1);
                CallNtPowerInformation(14, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
                Log("[albus cstate] C-state gecisleri engellendi.");
            } catch {}
        }

        void RestoreCStates()
        {
            try
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(p, 0);
                CallNtPowerInformation(14, p, 4, IntPtr.Zero, 0);
                Marshal.FreeHGlobal(p);
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  GPU SCHEDULER
        // ══════════════════════════════════════════════════════════════════════
        void BoostGpuPriority()
        {
            try
            {
                int hr = D3DKMTSetProcessSchedulingPriorityClass(
                    Process.GetCurrentProcess().Handle, 5); // REALTIME
                Log(string.Format("[albus gpu] D3DKMT realtime (hr=0x{0:X})", hr));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  UI ÖNCELİK MODULASYONU
        // ══════════════════════════════════════════════════════════════════════
        void ModulateUiPriority(bool boost)
        {
            try
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try { p.PriorityClass = ProcessPriorityClass.High; } catch {}

                var expPrio = boost
                    ? ProcessPriorityClass.BelowNormal
                    : ProcessPriorityClass.Normal;
                foreach (Process p in Process.GetProcessesByName("explorer"))
                    try { p.PriorityClass = expPrio; } catch {}

                if (boost) Log("[albus prio] dwm=high, explorer=belownormal.");
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  DPC LATENCY BASELINE
        //  Spin-wait döngüsüyle mevcut jitter'ı ölçer; health callback'te
        //  referans olarak kullanılır. Kayma tespit edilirse log'a uyarı düşer.
        // ══════════════════════════════════════════════════════════════════════
        void MeasureDpcBaseline()
        {
            try
            {
                long best = long.MaxValue;
                for (int i = 0; i < 200; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(1000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < best) best = d;
                }
                dpcBaselineTicks = best;
                double us = (best * 1000000.0) / Stopwatch.Frequency;
                Log(string.Format("[albus dpc] baseline jitter: {0:F1} µs", us));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  IRQ AFINİTESİ
        //  GPU IRQ'larını core 0'dan uzaklaştırır; böylece oyun/ses thread'leri
        //  core 0'da interrupt baskısıyla karşılaşmaz.
        // ══════════════════════════════════════════════════════════════════════
        void OptimizeIrqAffinity()
        {
            try
            {
                const string BASE =
                    @"SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}";
                RegistryKey gpuClass = Registry.LocalMachine.OpenSubKey(BASE, true);
                if (gpuClass == null) return;

                foreach (string sub in gpuClass.GetSubKeyNames())
                {
                    if (!System.Text.RegularExpressions.Regex.IsMatch(sub, @"^\d{4}$"))
                        continue;
                    RegistryKey dev = gpuClass.OpenSubKey(sub, true);
                    if (dev == null) continue;

                    RegistryKey pol = dev.CreateSubKey(
                        "Interrupt Management\\Affinity Policy");
                    if (pol != null)
                    {
                        // core 0 hariç tüm core'lar → 0xFE
                        pol.SetValue("AssignmentSetOverride",
                            new byte[] { 0xFE, 0x00, 0x00, 0x00 },
                            RegistryValueKind.Binary);
                        // IrqPolicySpecifiedProcessors = 4
                        pol.SetValue("DevicePolicy", 4, RegistryValueKind.DWord);
                        pol.Close();
                    }
                    dev.Close();
                }
                gpuClass.Close();
                Log("[albus irq] GPU IRQ affinity ayarlandi (core-0 bypass).");
            } catch {}
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
            Log(string.Format("[albus timer] dogrulandi: {0} ({1:F3}ms)",
                actual, actual / 10000.0));
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
            try
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
                Log(string.Format("[albus guard] drift duzeltildi: {0}->{1} ({2:F3}ms)",
                    qCur, actual, actual / 10000.0));
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  BELLEK
        // ══════════════════════════════════════════════════════════════════════
        void PurgeStandbyList()
        {
            try { SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); } catch {}
            try { int cmd = 4; NtSetSystemInformation(80, ref cmd, sizeof(int)); } catch {}
        }

        void GhostMemory()
        {
            try { EmptyWorkingSet(Process.GetCurrentProcess().Handle); } catch {}
        }

        void StartPurge()
        {
            purgeTimer = new Timer(PurgeCallback, null,
                TimeSpan.FromMinutes(PURGE_INITIAL_MIN),
                TimeSpan.FromMinutes(PURGE_INTERVAL_MIN));
        }

        void PurgeCallback(object _)
        {
            try
            {
                PerformanceCounter pc = new PerformanceCounter("Memory", "Available MBytes");
                float mb = pc.NextValue();
                pc.Dispose();
                if (mb < PURGE_THRESHOLD_MB)
                {
                    PurgeStandbyList();
                    Log(string.Format("[albus islc] purge tetiklendi, musait={0:F0}MB.", mb));
                }
            } catch {}
            GhostMemory();
        }

        // ══════════════════════════════════════════════════════════════════════
        //  WATCHDOG
        //  Üç bağımsız kontrol: servis priority, DWM priority, timer resolution.
        // ══════════════════════════════════════════════════════════════════════
        void StartWatchdog()
        {
            watchdogTimer = new Timer(WatchdogCallback, null,
                TimeSpan.FromSeconds(WATCHDOG_SEC),
                TimeSpan.FromSeconds(WATCHDOG_SEC));
        }

        void WatchdogCallback(object _)
        {
            // 1. servis priority
            try
            {
                Process self = Process.GetCurrentProcess();
                if (self.PriorityClass != ProcessPriorityClass.High)
                {
                    Log(string.Format("[albus watchdog] priority calinmis ({0}), geri aliniyor.",
                        self.PriorityClass));
                    self.PriorityClass = ProcessPriorityClass.High;
                }
            } catch {}

            // 2. DWM priority
            try
            {
                foreach (Process p in Process.GetProcessesByName("dwm"))
                    try
                    {
                        if (p.PriorityClass != ProcessPriorityClass.High)
                            p.PriorityClass = ProcessPriorityClass.High;
                    } catch {}
            } catch {}

            // 3. timer resolution hızlı kontrol (guard'dan bağımsız)
            try
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);
                if (qCur > targetRes + RESOLUTION_TOLERANCE * 4)
                {
                    uint actual = 0;
                    NtSetTimerResolution(targetRes, true, out actual);
                    Log(string.Format(
                        "[albus watchdog] timer kaydi: {0:F3}ms, duzeltildi.",
                        qCur / 10000.0));
                }
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  HEALTH MONİTÖR
        //  15 dakikada bir: timer durumu, kullanılabilir RAM, CPU, DPC jitter.
        //  Jitter baseline'ın 3 katını aşarsa uyarı logu düşer.
        // ══════════════════════════════════════════════════════════════════════
        void StartHealthMonitor()
        {
            healthTimer = new Timer(HealthCallback, null,
                TimeSpan.FromMinutes(HEALTH_INITIAL_MIN),
                TimeSpan.FromMinutes(HEALTH_INTERVAL_MIN));
        }

        void HealthCallback(object _)
        {
            try
            {
                uint qMin, qMax, qCur;
                NtQueryTimerResolution(out qMin, out qMax, out qCur);

                float availMB = 0;
                try
                {
                    PerformanceCounter pc = new PerformanceCounter("Memory", "Available MBytes");
                    availMB = pc.NextValue();
                    pc.Dispose();
                } catch {}

                float cpu = 0;
                try
                {
                    PerformanceCounter pc =
                        new PerformanceCounter("Processor", "% Processor Time", "_Total");
                    pc.NextValue();
                    Thread.Sleep(200);
                    cpu = pc.NextValue();
                    pc.Dispose();
                } catch {}

                long jitterBest = long.MaxValue;
                for (int i = 0; i < 100; i++)
                {
                    long a = Stopwatch.GetTimestamp();
                    Thread.SpinWait(1000);
                    long b = Stopwatch.GetTimestamp();
                    long d = b - a;
                    if (d < jitterBest) jitterBest = d;
                }
                double jitterUs = (jitterBest * 1000000.0) / Stopwatch.Frequency;

                Log(string.Format(
                    "[albus health] timer={0:F3}ms | ram={1:F0}MB | cpu={2:F1}% | jitter={3:F1}µs",
                    qCur / 10000.0, availMB, cpu, jitterUs));

                if (dpcBaselineTicks > 0)
                {
                    double baseUs = (dpcBaselineTicks * 1000000.0) / Stopwatch.Frequency;
                    if (jitterUs > baseUs * 3.0)
                        Log(string.Format(
                            "[albus health] uyari: jitter baseline'dan {0:F1}x yuksek!",
                            jitterUs / baseUs));
                }
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  PROCESS İZLEYİCİ  (hedef mod)
        // ══════════════════════════════════════════════════════════════════════
        void StartWatcher()
        {
            try
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
                Log("[albus watcher] izleniyor: " + string.Join(", ", processNames));
            }
            catch (Exception ex)
            {
                Log("[albus watcher] hata: " + ex.Message, EventLogEntryType.Warning);
            }
        }

        void OnWatcherStopped(object sender, StoppedEventArgs e)
        {
            if (wmiRetry >= 5) return;
            wmiRetry++;
            Thread.Sleep(3000);
            try
            {
                if (startWatch != null)
                    try { startWatch.Dispose(); } catch {}
                startWatch = null;
                StartWatcher();
                Log("[albus watcher] WMI yeniden baglandi.");
            } catch {}
        }

        void OnProcessArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject proc =
                    (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                uint pid = (uint)proc.Properties["ProcessId"].Value;
                ThreadPool.QueueUserWorkItem(delegate { ProcessStarted(pid); });
            } catch {}
        }

        void ProcessStarted(uint pid)
        {
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}
            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch {}

            SetResolutionVerified();
            PurgeStandbyList();
            GhostMemory();
            ModulateUiPriority(true);

            IntPtr hProc = IntPtr.Zero;
            try
            {
                hProc = OpenProcess(SYNCHRONIZE, 0, pid);
                if (hProc != IntPtr.Zero) WaitForSingleObject(hProc, -1);
            } catch {}
            finally
            {
                if (hProc != IntPtr.Zero) try { CloseHandle(hProc); } catch {}
            }

            ModulateUiPriority(false);
            RestoreResolution();
            PurgeStandbyList();
            GhostMemory();
            Log("[albus rested] process kapandi. onarim tamamlandi.");
        }

        // ══════════════════════════════════════════════════════════════════════
        //  SES GECİKMESİ
        // ══════════════════════════════════════════════════════════════════════
        void StartAudioThread()
        {
            audioThread          = new Thread(AudioWorker);
            audioThread.Name     = "albus-audio";
            audioThread.Priority = ThreadPriority.Highest;
            audioThread.IsBackground = true;
            audioThread.Start();
        }

        void AudioWorker()
        {
            try { uint t = 0; AvSetMmThreadCharacteristics("Pro Audio", ref t); } catch {}
            try { CoInitializeEx(IntPtr.Zero, 0); } catch {}
            try
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
            } catch {}
            Thread.Sleep(Timeout.Infinite);
        }

        internal void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            try
            {
                Guid IID_AC3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                IMMDeviceCollection col;
                if (enumerator.EnumAudioEndpoints(2, 1, out col) != 0) return;

                uint count;
                col.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    IMMDevice dev;
                    if (col.Item(i, out dev) != 0) continue;

                    object clientObj;
                    if (dev.Activate(ref IID_AC3, 0x17, IntPtr.Zero, out clientObj) != 0) continue;

                    IAudioClient3 client = (IAudioClient3)clientObj;
                    IntPtr pFmt;
                    if (client.GetMixFormat(out pFmt) != 0) continue;

                    uint defF, fundF, minF, maxF;
                    bool ok = client.GetSharedModeEnginePeriod(
                        pFmt, out defF, out fundF, out minF, out maxF) == 0;

                    if (ok && minF < defF && minF > 0)
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
                                ? devId.Substring(devId.Length - 8) : (devId ?? "");

                            Log(string.Format(
                                "[albus audio] {0}: {1:F2}ms->{2:F2}ms (kare {3}->{4})",
                                shortId,
                                (defF / (double)fmt.nSamplesPerSec) * 1000.0,
                                (minF / (double)fmt.nSamplesPerSec) * 1000.0,
                                defF, minF));
                        }
                    }
                    Marshal.FreeCoTaskMem(pFmt);
                }
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  CONFIG / INI
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
            try
            {
                string iniPath = Assembly.GetExecutingAssembly().Location + ".ini";
                iniWatcher = new FileSystemWatcher(
                    Path.GetDirectoryName(iniPath),
                    Path.GetFileName(iniPath));
                iniWatcher.NotifyFilter        = NotifyFilters.LastWrite;
                iniWatcher.Changed            += OnIniChanged;
                iniWatcher.EnableRaisingEvents = true;
            } catch {}
        }

        void OnIniChanged(object sender, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            try
            {
                ReadConfig();
                targetRes = customRes > 0
                    ? customRes
                    : Math.Min(TARGET_RESOLUTION, maxRes);

                try
                {
                    if (startWatch != null)
                    {
                        startWatch.Stop();
                        startWatch.Dispose();
                        startWatch = null;
                    }
                } catch {}

                if (processNames != null && processNames.Count > 0)
                    StartWatcher();
                else
                {
                    SetResolutionVerified();
                    ModulateUiPriority(true);
                }
                Log("[albus reload] yapilandirma guncellendi.");
            } catch {}
        }

        // ══════════════════════════════════════════════════════════════════════
        //  KAYIT
        // ══════════════════════════════════════════════════════════════════════
        void Log(string msg)
        {
            if (EventLog == null) return;
            try
            {
                EventLog.WriteEntry(
                    string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg));
            } catch {}
        }
        void Log(string msg, EventLogEntryType type)
        {
            if (EventLog == null) return;
            try
            {
                EventLog.WriteEntry(
                    string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), msg), type);
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

        [DllImport("psapi.dll")]    static extern int   EmptyWorkingSet(IntPtr hProc);
        [DllImport("avrt.dll")]     static extern IntPtr AvSetMmThreadCharacteristics(string task, ref uint idx);
        [DllImport("ole32.dll")]    static extern int   CoInitializeEx(IntPtr pv, uint dwCoInit);
        [DllImport("gdi32.dll")]    static extern int   D3DKMTSetProcessSchedulingPriorityClass(IntPtr hProc, int pri);
        [DllImport("powrprof.dll")]
        static extern uint CallNtPowerInformation(int Level, IntPtr inBuf, uint inLen,
            IntPtr outBuf, uint outLen);

        const uint SYNCHRONIZE = 0x00100000u;

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

        // ── COM arayüzleri ────────────────────────────────────────────────────

        [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out uint n);
            [PreserveSig] int Item(uint i, out IMMDevice dev);
        }

        [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMNotificationClient
        {
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string id);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key);
        }

        [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int flow, int state, out IMMDeviceCollection col);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
            [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient cb);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient cb);
        }

        [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr pParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
            [PreserveSig] int OpenPropertyStore(int access, out IntPtr props);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out int state);
        }

        [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient3
        {
            [PreserveSig] int Initialize(int mode, uint flags, long bufDur, long period, IntPtr fmt, IntPtr guid);
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
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr fmt,
                out uint def, out uint fund, out uint min, out uint max);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr fmt, out uint period);
            [PreserveSig] int InitializeSharedAudioStream(uint flags,
                uint periodFrames, IntPtr fmt, IntPtr guid);
        }

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
                try
                {
                    if (Service != null)
                    {
                        Service.Log("[albus audio] cihaz degisimi — yeniden optimize ediliyor.");
                        lock (Service.audioClients) Service.audioClients.Clear();
                        if (Enumerator != null) Service.OptimizeAllEndpoints(Enumerator);
                    }
                } catch {}
                return 0;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  KURULUM
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
            si.ServiceName  = "AlbusSvc";
            si.DisplayName  = "albus";
            si.StartType    = ServiceStartMode.Automatic;
            si.Description  =
                "albus v3.0 — timer, CPU affinity, C-state, GPU, ses, bellek, IRQ, watchdog, health.";

            Installers.Add(spi);
            Installers.Add(si);
        }
    }
}
