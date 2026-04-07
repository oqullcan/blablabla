# albus - set timer resolution
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath PowerShell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$Host.UI.RawUI.WindowTitle = "AlbusX"
$ErrorActionPreference     = "SilentlyContinue"
[Console]::OutputEncoding   = [System.Text.Encoding]::UTF8

$AppName     = "AlbusX"
$ServiceName = "AlbusXSvc"
$ServiceDisp = "AlbusX"
$ServiceExe  = "$env:SystemRoot\AlbusX.exe"
$SourceFile  = "$env:SystemRoot\AlbusX.cs"
$Compiler    = "$env:Windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$RegPath     = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"

try {
    $TimerCheckCode = @'
    using System;
    using System.Runtime.InteropServices;
    public class AlbusStatus {
        [DllImport("ntdll.dll", SetLastError=true)]
        static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint ActualResolution);
        
        public static string GetCurrentMs() {
            uint min, max, actual;
            NtQueryTimerResolution(out min, out max, out actual);
            return (actual / 10000.0).ToString("0.000") + " ms";
        }
        public static string GetMaxMs() {
            uint min, max, actual;
            NtQueryTimerResolution(out min, out max, out actual);
            return (max / 10000.0).ToString("0.000") + " ms";
        }
    }
'@
    Add-Type -TypeDefinition $TimerCheckCode -ErrorAction Stop
} catch {}

$CSharpCode = @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.ComponentModel;
using System.Configuration.Install;
using System.Collections.Generic;
using System.Reflection;
using System.IO;
using System.Management;
using System.Threading;
using System.Diagnostics;
using System.Runtime;

[assembly: AssemblyVersion("8.0")]
[assembly: AssemblyProduct("albus x")]

namespace AlbusCore
{
    class AlbusService : ServiceBase
    {
        public AlbusService()
        {
            this.ServiceName = "AlbusXSvc";
            this.EventLog.Log = "Application";
            this.CanStop = true;
            this.CanHandlePowerEvent = true;
            this.CanHandleSessionChangeEvent = false;
            this.CanPauseAndContinue = false;
            this.CanShutdown = true;
        }

        static void Main()
        {
            ServiceBase.Run(new AlbusService());
        }

        protected override void OnStart(string[] args)
        {
            try {
                Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High;
                Process.GetCurrentProcess().PriorityBoostEnabled = false;
            } catch {}

            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch {}

            try { GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency; } catch {}

            try { Process.GetCurrentProcess().ProcessorAffinity = (IntPtr)1; } catch {}

            try {
                uint taskIndex = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref taskIndex);
            } catch {}

            try {
                PROCESS_POWER_THROTTLING_STATE throttle;
                throttle.Version = 1;
                throttle.ControlMask = 0x4;
                throttle.StateMask = 0;
                SetProcessInformation(
                    Process.GetCurrentProcess().Handle, 4,
                    ref throttle, Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE))
                );
            } catch {}

            try { SetThreadExecutionState(0x80000003); } catch {}

            base.OnStart(args);
            ReadProcessList();
            NtQueryTimerResolution(out this.MinimumResolution, out this.MaximumResolution, out this.DefaultResolution);

            if(this.CustomResolution > 0)
                this.TargetResolution = this.CustomResolution;
            else
                this.TargetResolution = this.MaximumResolution;

            Log(String.Format("[albus init] min={0}; max={1}; default={2}; target={3}; mode={4}",
                this.MinimumResolution, this.MaximumResolution, this.DefaultResolution,
                this.TargetResolution,
                null != this.ProcessesNames ? String.Join(",", this.ProcessesNames) : "global"
            ));

            try { this.hResTimer = CreateWaitableTimerExW(IntPtr.Zero, null, 0x00000002, 0x1F0003); } catch {}

            try { VirtualLock(Process.GetCurrentProcess().Handle, (UIntPtr)4096); } catch {}

            if(null == this.ProcessesNames || 0 == this.ProcessesNames.Count)
            {
                SetMaximumResolutionVerified();
                PurgeStandbyList();
                GhostMemory();
                InvokePriorityBoost(true);
            }
            else
            {
                StartWatcher();
            }

            StartPeriodicPurge();
            StartResolutionGuard();
            StartIniWatcher();
            StartLowAudioLatency();
            GhostMemory();
        }

        protected override void OnStop()
        {
            try { SetThreadExecutionState(0x80000000); } catch {}
            if(null != this.startWatch) { try { this.startWatch.Stop(); this.startWatch.Dispose(); } catch {} }
            if(null != this.purgeTimer) { try { this.purgeTimer.Dispose(); } catch {} }
            if(null != this.guardTimer) { try { this.guardTimer.Dispose(); } catch {} }
            if(null != this.iniWatcher) { try { this.iniWatcher.EnableRaisingEvents = false; this.iniWatcher.Dispose(); } catch {} }
            if(this.hResTimer != IntPtr.Zero) { try { CloseHandle(this.hResTimer); } catch {} }

            try {
                uint actual = 0;
                NtSetTimerResolution(this.DefaultResolution, true, out actual);
                Log(String.Format("[albus stop] resolution reverted to {0}", actual));
            } catch {}

            InvokePriorityBoost(false);

            base.OnStop();
        }

        protected override void OnShutdown() { OnStop(); }

        protected override bool OnPowerEvent(PowerBroadcastStatus powerStatus)
        {
            if(powerStatus == PowerBroadcastStatus.ResumeSuspend ||
               powerStatus == PowerBroadcastStatus.ResumeAutomatic)
            {
                Thread.Sleep(2000);
                SetMaximumResolutionVerified();
                PurgeStandbyList();
                Log("[albus resume] re-applied after sleep.");
            }
            return true;
        }


        ManagementEventWatcher startWatch;
        delegate void OnProcessStart(UInt32 processId);
        OnProcessStart ProcessStartDelegate = null;
        int wmiRetryCount = 0;

        void StartWatcher()
        {
            this.ProcessStartDelegate = new OnProcessStart(this.ProcessStarted);
            try
            {
                String query = String.Format(
                    "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE (TargetInstance isa \"Win32_Process\") AND (TargetInstance.Name=\"{0}\")",
                    String.Join("\" OR TargetInstance.Name=\"", this.ProcessesNames)
                );
                this.startWatch = new ManagementEventWatcher(query);
                this.startWatch.EventArrived += this.startWatch_EventArrived;
                this.startWatch.Stopped += this.startWatch_Stopped;
                this.startWatch.Start();
                this.wmiRetryCount = 0;
            }
            catch(Exception ee) { Log(ee.ToString(), EventLogEntryType.Error); }
        }

        void startWatch_Stopped(object sender, StoppedEventArgs e)
        {
            if(this.wmiRetryCount < 5)
            {
                this.wmiRetryCount++;
                Thread.Sleep(3000);
                try {
                    if(null != this.startWatch) { try { this.startWatch.Dispose(); } catch {} }
                    StartWatcher();
                    Log("[albus wmi] reconnected after drop.");
                } catch {}
            }
        }

        void startWatch_EventArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject process = (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                UInt32 processId = (UInt32)process.Properties["ProcessId"].Value;
                this.ProcessStartDelegate.BeginInvoke(processId, null, null);
            }
            catch {}
        }

        void ProcessStarted(UInt32 processId)
        {
            try {
                uint pTaskIndex = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref pTaskIndex);
            } catch {}
            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch {}

            SetMaximumResolutionVerified();
            PurgeStandbyList();
            GhostMemory();
            InvokePriorityBoost(true);

            IntPtr processHandle = IntPtr.Zero;
            try
            {
                processHandle = OpenProcess(SYNCHRONIZE, 0, processId);
                if(processHandle != IntPtr.Zero)
                    WaitForSingleObject(processHandle, -1);
            }
            catch {}
            finally
            {
                if(processHandle != IntPtr.Zero) CloseHandle(processHandle);
            }

            InvokePriorityBoost(false);
            SetDefaultResolution();
            PurgeStandbyList();
            GhostMemory();
            Log("[albus rested] process exited. post-game priority and purge complete.");
        }

        void InvokePriorityBoost(bool activate)
        {
            try {
                if(activate) {
                    foreach(var p in Process.GetProcessesByName("dwm")) { try { p.PriorityClass = ProcessPriorityClass.High; } catch {} }
                    foreach(var p in Process.GetProcessesByName("explorer")) { try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch {} }
                    Log("[albus core] ui rendering priority modulated: dwm=high, explorer=belownormal.");
                } else {
                    foreach(var p in Process.GetProcessesByName("dwm")) { try { p.PriorityClass = ProcessPriorityClass.High; } catch {} }
                    foreach(var p in Process.GetProcessesByName("explorer")) { try { p.PriorityClass = ProcessPriorityClass.Normal; } catch {} }
                }
            } catch {}
        }


        uint DefaultResolution = 0;
        uint MinimumResolution = 0;
        uint MaximumResolution = 0;
        uint TargetResolution = 0;
        uint CustomResolution = 0;
        long processCounter = 0;

        void SetMaximumResolutionVerified()
        {
            long counter = Interlocked.Increment(ref this.processCounter);
            if(counter <= 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.TargetResolution, true, out actual);

                for(int retry = 0; retry < 50; retry++)
                {
                    uint qMin, qMax, qActual;
                    NtQueryTimerResolution(out qMin, out qMax, out qActual);
                    if(qActual <= this.TargetResolution + 100) break;
                    Thread.SpinWait(10000);
                    NtSetTimerResolution(this.TargetResolution, true, out actual);
                }

                Log(String.Format("[albus armed] verified resolution = {0}", actual));
            }
        }

        void SetDefaultResolution()
        {
            long counter = Interlocked.Decrement(ref this.processCounter);
            if(counter < 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.DefaultResolution, true, out actual);
            }
        }


        System.Threading.Timer guardTimer;

        void StartResolutionGuard()
        {
            guardTimer = new System.Threading.Timer(GuardCallback, null,
                TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
        }

        void GuardCallback(object state)
        {
            try
            {
                uint qMin, qMax, qActual;
                NtQueryTimerResolution(out qMin, out qMax, out qActual);
                if(qActual > this.TargetResolution + 100)
                {
                    uint actual = 0;
                    NtSetTimerResolution(this.TargetResolution, true, out actual);
                    Log(String.Format("[albus guard] drifted to {0}, forced back to {1}", qActual, actual));
                }
            }
            catch {}
        }


        System.Threading.Timer purgeTimer;

        void StartPeriodicPurge()
        {
            purgeTimer = new System.Threading.Timer(PeriodicPurgeCallback, null,
                TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5));
        }

        void PeriodicPurgeCallback(object state)
        {
            try
            {
                var pc = new PerformanceCounter("Memory", "Available MBytes");
                float availableMB = pc.NextValue();
                pc.Dispose();
                if(availableMB < 1024)
                {
                    PurgeStandbyList();
                    Log(String.Format("[albus islc] purge triggered. available ram = {0:F0} mb.", availableMB));
                }
            }
            catch {}
            GhostMemory();
        }

        void PurgeStandbyList()
        {
            try { SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0); } catch {}
            try {
                int command = 4;
                NtSetSystemInformation(80, ref command, sizeof(int));
            } catch {}
        }

        void GhostMemory()
        {
            try { EmptyWorkingSet(Process.GetCurrentProcess().Handle); } catch {}
        }


        List<String> ProcessesNames = null;

        void ReadProcessList()
        {
            this.ProcessesNames = null;
            this.CustomResolution = 0;
            String iniFilePath = Assembly.GetExecutingAssembly().Location + ".ini";
            if(File.Exists(iniFilePath))
            {
                this.ProcessesNames = new List<String>();
                String[] iniFileLines = File.ReadAllLines(iniFilePath);
                foreach(var line in iniFileLines)
                {
                    String trimmed = line.Trim();
                    if(trimmed.StartsWith("#")) continue;
                    if(trimmed.ToLower().StartsWith("resolution="))
                    {
                        uint val;
                        if(uint.TryParse(trimmed.Substring(11).Trim(), out val))
                            this.CustomResolution = val;
                        continue;
                    }
                    String[] names = trimmed.Split(new char[] {',', ' ', ';'}, StringSplitOptions.RemoveEmptyEntries);
                    foreach(var name in names)
                    {
                        String lwr_name = name.ToLower().Trim();
                        if(lwr_name.Length == 0) continue;
                        if(!lwr_name.EndsWith(".exe")) lwr_name += ".exe";
                        if(!this.ProcessesNames.Contains(lwr_name)) this.ProcessesNames.Add(lwr_name);
                    }
                }
            }
        }


        FileSystemWatcher iniWatcher;

        void StartIniWatcher()
        {
            try
            {
                String iniFilePath = Assembly.GetExecutingAssembly().Location + ".ini";
                String dir = Path.GetDirectoryName(iniFilePath);
                String file = Path.GetFileName(iniFilePath);
                iniWatcher = new FileSystemWatcher(dir, file);
                iniWatcher.NotifyFilter = NotifyFilters.LastWrite;
                iniWatcher.Changed += OnIniChanged;
                iniWatcher.EnableRaisingEvents = true;
            }
            catch {}
        }

        void OnIniChanged(object sender, FileSystemEventArgs e)
        {
            Thread.Sleep(500);
            try
            {
                ReadProcessList();
                if(this.CustomResolution > 0)
                    this.TargetResolution = this.CustomResolution;
                else
                    this.TargetResolution = this.MaximumResolution;

                if(null != this.startWatch) {
                    try { this.startWatch.Stop(); this.startWatch.Dispose(); } catch {}
                    this.startWatch = null;
                }
                if(null != this.ProcessesNames && this.ProcessesNames.Count > 0)
                    StartWatcher();

                Log("[albus reload] ini changed. process list updated.");
            }
            catch {}
        }


        void Log(string message)
        {
            if(null != this.EventLog) { try { this.EventLog.WriteEntry(message); } catch {} }
        }
        void Log(string message, EventLogEntryType type)
        {
            if(null != this.EventLog) { try { this.EventLog.WriteEntry(message, type); } catch {} }
        }


        Thread audioThread;
        List<object> activeAudioClients = new List<object>();

        void StartLowAudioLatency()
        {
            this.audioThread = new Thread(new ThreadStart(AudioLatencyWorker));
            this.audioThread.IsBackground = true;
            this.audioThread.Start();
        }

        class AudioNotifier : IMMNotificationClient
        {
            public Action OnReOptimize;
            public int OnDeviceStateChanged(string id, int state) { return 0; }
            public int OnDeviceAdded(string id) { return 0; }
            public int OnDeviceRemoved(string id) { return 0; }
            public int OnDefaultDeviceChanged(int flow, int role, string id) {
                try { if(OnReOptimize != null) OnReOptimize(); } catch {}
                return 0;
            }
            public int OnPropertyValueChanged(string id, IntPtr key) { return 0; }
        }

        AudioNotifier _notifier;

        void AudioLatencyWorker()
        {
            try { 
                Thread.CurrentThread.Priority = ThreadPriority.Highest;
                uint tsk = 0;
                AvSetMmThreadCharacteristics("Pro Audio", ref tsk);
            } catch {}

            try { CoInitializeEx(IntPtr.Zero, 0); } catch {}
            
            try
            {
                Type mmdeType = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(mmdeType);
                
                _notifier = new AudioNotifier();
                _notifier.OnReOptimize = () => { 
                    Log("[albus audio] device hot-swap detected. re-optimizing buffers.");
                    OptimizeAllEndpoints(enumerator); 
                };
                enumerator.RegisterEndpointNotificationCallback(_notifier);
                
                OptimizeAllEndpoints(enumerator);
            }
            catch {}
            
            Thread.Sleep(Timeout.Infinite);
        }

        void OptimizeAllEndpoints(IMMDeviceEnumerator enumerator)
        {
            try
            {
                Guid IID_IAudioClient3 = new Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE");
                
                IMMDeviceCollection collection;
                if (enumerator.EnumAudioEndpoints(2, 1, out collection) == 0) // eAll, ACTIVE
                {
                    uint count;
                    collection.GetCount(out count);
                    for (uint i = 0; i < count; i++)
                    {
                        IMMDevice device;
                        if (collection.Item(i, out device) == 0)
                        {
                            object clientObj;
                            if (device.Activate(ref IID_IAudioClient3, 0x17, IntPtr.Zero, out clientObj) == 0)
                            {
                                IAudioClient3 client = (IAudioClient3)clientObj;
                                IntPtr pFormat;
                                if (client.GetMixFormat(out pFormat) == 0)
                                {
                                    WAVEFORMATEX fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pFormat, typeof(WAVEFORMATEX));
                                    uint def, fund, min, max;
                                    if (client.GetSharedModeEnginePeriod(pFormat, out def, out fund, out min, out max) == 0)
                                    {
                                        if (min < def && min > 0)
                                        {
                                            if (client.InitializeSharedAudioStream(0, min, pFormat, IntPtr.Zero) == 0)
                                            {
                                                if (client.Start() == 0)
                                                {
                                                    activeAudioClients.Add(clientObj);
                                                    string devId;
                                                    device.GetId(out devId);
                                                    double minMs = (min / (double)fmt.nSamplesPerSec) * 1000.0;
                                                    double defMs = (def / (double)fmt.nSamplesPerSec) * 1000.0;
                                                    string shortId = devId != null && devId.Length > 8 ? devId.Substring(devId.Length - 8) : "";
                                                    Log(String.Format("[albus audio] miniaturized: frames {0}->{1} ({2:F2}ms -> {3:F2}ms). id:{4}", def, min, defMs, minMs, shortId));
                                                }
                                            }
                                        }
                                    }
                                    Marshal.FreeCoTaskMem(pFormat);
                                }
                            }
                        }
                    }
                }
            }
            catch {}
        }


        IntPtr hResTimer = IntPtr.Zero;

        [DllImport("ntdll.dll", SetLastError=true)]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
        [DllImport("ntdll.dll", SetLastError=true)]
        static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint ActualResolution);
        [DllImport("ntdll.dll")]
        static extern int NtSetSystemInformation(int SystemInformationClass, ref int SystemInformation, int SystemInformationLength);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern Int32 WaitForSingleObject(IntPtr Handle, Int32 Milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(UInt32 DesiredAccess, Int32 InheritHandle, UInt32 ProcessId);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern Int32 CloseHandle(IntPtr Handle);
        [DllImport("kernel32.dll")]
        static extern bool SetSystemFileCacheSize(IntPtr MinimumFileCacheSize, IntPtr MaximumFileCacheSize, int Flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
        static extern IntPtr CreateWaitableTimerExW(IntPtr lpTimerAttributes, string lpTimerName, uint dwFlags, uint dwDesiredAccess);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetProcessInformation(IntPtr hProcess, int ProcessInformationClass, ref PROCESS_POWER_THROTTLING_STATE ProcessInformation, int ProcessInformationSize);
        [DllImport("kernel32.dll")]
        static extern uint SetThreadExecutionState(uint esFlags);
        [DllImport("kernel32.dll")]
        static extern bool VirtualLock(IntPtr lpAddress, UIntPtr dwSize);
        [DllImport("psapi.dll")]
        static extern int EmptyWorkingSet(IntPtr hwProc);
        [DllImport("avrt.dll", SetLastError=true)]
        static extern IntPtr AvSetMmThreadCharacteristics(string TaskName, ref uint TaskIndex);
        [DllImport("ole32.dll")]
        static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);

        [ComImport][Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection {
            [PreserveSig] int GetCount(out uint pcDevices);
            [PreserveSig] int Item(uint nDevice, out IMMDevice ppDevice);
        }
        [ComImport][Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMNotificationClient {
            [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int newState);
            [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
            [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
            [PreserveSig] int OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string defaultDeviceId);
            [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr key);
        }
        [ComImport][Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection ppDevices);
            [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
            [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
            [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient pClient);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient pClient);
        }
        [ComImport][Guid("D666063F-1587-4E43-81F1-B948E807363F")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice {
            [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
            [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
            [PreserveSig] int GetState(out int pdwState);
        }
        [ComImport][Guid("7ED4EE07-8E67-464A-ACE2-EE41ED53CDFE")][InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient3 {
            [PreserveSig] int Initialize(int ShareMode, uint StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
            [PreserveSig] int GetBufferSize(out uint pNumBufferFrames);
            [PreserveSig] int GetStreamLatency(out long phnsLatency);
            [PreserveSig] int GetCurrentPadding(out uint pNumPaddingFrames);
            [PreserveSig] int IsFormatSupported(int ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
            [PreserveSig] int GetMixFormat(out IntPtr ppDeviceFormat);
            [PreserveSig] int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr eventHandle);
            [PreserveSig] int GetService(ref Guid riid, out IntPtr ppv);
            [PreserveSig] int IsOffloadCapable(int Category, out int pbOffloadCapable);
            [PreserveSig] int SetClientProperties(IntPtr pProperties);
            [PreserveSig] int GetSharedModeEnginePeriod(IntPtr pFormat, out uint pDefaultPeriodInFrames, out uint pFundamentalPeriodInFrames, out uint pMinPeriodInFrames, out uint pMaxPeriodInFrames);
            [PreserveSig] int GetCurrentSharedModeEnginePeriod(out IntPtr ppFormat, out uint pCurrentPeriodInFrames);
            [PreserveSig] int InitializeSharedAudioStream(uint StreamFlags, uint PeriodInFrames, IntPtr pFormat, IntPtr AudioSessionGuid);
        }

        [StructLayout(LayoutKind.Sequential, Pack=1)]
        struct WAVEFORMATEX {
            public ushort wFormatTag;
            public ushort nChannels;
            public uint nSamplesPerSec;
            public uint nAvgBytesPerSec;
            public ushort nBlockAlign;
            public ushort wBitsPerSample;
            public ushort cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_POWER_THROTTLING_STATE {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
        }

        const UInt32 SYNCHRONIZE = 0x00100000;
    }

    [RunInstaller(true)]
    public class AlbusInstaller : Installer
    {
        public AlbusInstaller()
        {
            ServiceProcessInstaller spi = new ServiceProcessInstaller();
            ServiceInstaller si = new ServiceInstaller();
            spi.Account = ServiceAccount.LocalSystem;
            spi.Username = null;
            spi.Password = null;
            si.DisplayName = "AlbusX";
            si.StartType = ServiceStartMode.Automatic;
            si.ServiceName = "AlbusXSvc";
            this.Installers.Add(spi);
            this.Installers.Add(si);
        }
    }
}
'@

function Write-MenuHeader {
    Clear-Host
    Write-Host ""
    Write-Host "  albus x" -ForegroundColor White
    Write-Host ""
    Write-Host "  -----------------------------------" -ForegroundColor DarkGray
    
    $currentRes = "n/a"
    $maxRes     = "n/a"
    if ([System.Management.Automation.PSTypeName]'AlbusStatus') {
        $currentRes = [AlbusStatus]::GetCurrentMs()
        $maxRes     = [AlbusStatus]::GetMaxMs()
    }
    
    $svcStatus = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue 
    if ($svcStatus -and $svcStatus.Status -eq "Running") {
        Write-Host "  status       " -NoNewline -ForegroundColor DarkGray
        Write-Host "active" -ForegroundColor Green
    } else {
        Write-Host "  status       " -NoNewline -ForegroundColor DarkGray
        Write-Host "inactive" -ForegroundColor Red
    }

    Write-Host "  resolution   " -NoNewline -ForegroundColor DarkGray
    Write-Host $currentRes -ForegroundColor White
    Write-Host "  target       " -NoNewline -ForegroundColor DarkGray
    Write-Host $maxRes -ForegroundColor White
    
    Write-Host "  -----------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-Optimize {
    Write-MenuHeader
    
    Write-Host "  compiling engine..." -ForegroundColor DarkGray
    Set-Content -Path $SourceFile -Value $CSharpCode -Force

    $refs = @(
        "-r:System.ServiceProcess.dll",
        "-r:System.Configuration.Install.dll",
        "-r:System.Management.dll"
    ) -join " "
    $compilerArgs = "$refs -out:`"$ServiceExe`" `"$SourceFile`""

    Start-Process -FilePath $Compiler -ArgumentList $compilerArgs -WindowStyle Hidden -Wait
    Remove-Item -Path $SourceFile -Force

    if (-not (Test-Path $ServiceExe)) {
        Write-Host "  compilation failed." -ForegroundColor Red
        Start-Sleep -Seconds 3
        return
    }
    Write-Host "  compiled." -ForegroundColor Green

    Write-Host "  deploying service..." -ForegroundColor DarkGray
    if (Get-Service -Name $ServiceName) {
        Stop-Service -Name $ServiceName -Force
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
    }

    New-Service -Name $ServiceName -DisplayName $ServiceDisp -BinaryPathName $ServiceExe -StartupType Automatic | Out-Null
    sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Start-Service -Name $ServiceName | Out-Null

    Write-Host "  applying native tweaks..." -ForegroundColor DarkGray
    New-ItemProperty -Path $RegPath -Name "GlobalTimerResolutionRequests" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "EnableDynamicTick"            -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "TscSyncPolicy"               -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name "TimerCoalescing"             -Value 0 -PropertyType DWord -Force | Out-Null

    Write-Host ""
    Write-Host "  done. reboot recommended." -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Invoke-Restore {
    Write-MenuHeader
    Write-Host "  stopping service..." -ForegroundColor DarkGray
    
    if (Get-Service -Name $ServiceName) {
        Set-Service -Name $ServiceName -StartupType Disabled
        Stop-Service -Name $ServiceName -Force
        sc.exe delete $ServiceName | Out-Null
    }
    Start-Sleep -Seconds 1
    Remove-Item -Path $ServiceExe -Force

    Write-Host "  reverting registry..." -ForegroundColor DarkGray
    Remove-ItemProperty -Path $RegPath -Name "GlobalTimerResolutionRequests" -Force
    Remove-ItemProperty -Path $RegPath -Name "EnableDynamicTick"            -Force
    Remove-ItemProperty -Path $RegPath -Name "TscSyncPolicy"               -Force
    Remove-ItemProperty -Path $RegPath -Name "TimerCoalescing"             -Force

    Write-Host ""
    Write-Host "  defaults restored. reboot recommended." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

function Invoke-Diagnostics {
    Write-MenuHeader
    Write-Host "  reading event logs..." -ForegroundColor DarkGray
    Write-Host ""

    try {
        $events = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName=$ServiceName} -MaxEvents 20 -ErrorAction Stop
        
        foreach ($evt in $events) {
            $time = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            $msg  = $evt.Message.Trim() -replace "`r`n"," " -replace "`n"," "
            Write-Host "  $time  " -NoNewline -ForegroundColor DarkGray
            Write-Host $msg -ForegroundColor Gray
        }
    } catch {
        Write-Host "  no logs found." -ForegroundColor DarkGray
    }

    Write-Host ""
    Read-Host "  press enter to return" | Out-Null
}

while ($true) {
    Write-MenuHeader
    Write-Host "  1 - optimize"
    Write-Host "  2 - restore"
    Write-Host "  3 - logs"
    Write-Host "  q - exit"
    Write-Host ""

    $choice = Read-Host "  >"
    switch ($choice) {
        '1' { Invoke-Optimize }
        '2' { Invoke-Restore }
        '3' { Invoke-Diagnostics }
        'Q' { exit }
        'q' { exit }
    }
}
