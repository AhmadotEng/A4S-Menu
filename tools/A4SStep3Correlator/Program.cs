using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;
using Newtonsoft.Json;

namespace A4SStep3Correlator
{
    internal static class Program
    {
        private static readonly Guid A4SProvider =
            new Guid("74a9f986-c7ab-429a-9571-df0fb7f4a33c");

        private sealed class RuntimeEvent
        {
            public long Qpc;
            public long Sequence;
            public int Event;
            public int Stage;
            public long Operation;
            public int ActivationSource;
            public int ProcessId;
            public int ThreadId;
        }

        private sealed class Interval
        {
            public int Cycle;
            public long StartQpc;
            public long EndQpc;
            public long Operation;
            public int ActivationSource;
        }

        private sealed class Cycle
        {
            public int Number;
            public RuntimeEvent OpenActivation;
            public RuntimeEvent OpenBegin;
            public RuntimeEvent FirstPaint;
            public RuntimeEvent Visible;
            public RuntimeEvent OpenEnd;
            public RuntimeEvent CloseActivation;
            public RuntimeEvent CloseBegin;
            public RuntimeEvent Hidden;
            public RuntimeEvent CloseEnd;
        }

        private sealed class CountBytes
        {
            public long Count;
            public long Bytes;
        }

        private sealed class ImageRange
        {
            public ulong Base;
            public ulong Size;
            public string FileName;
        }

        private sealed class CpuSample
        {
            public long Qpc;
            public ulong InstructionPointer;
            public bool InOpen;
            public int Cycle;
        }

        private sealed class IoRecord
        {
            public ulong FileKey;
            public string FileName;
        }

        private sealed class RelevantEvent
        {
            public long Qpc;
            public int Cycle;
            public int ThreadId;
            public string Category;
            public string Name;
        }

        private sealed class EtlIdentity
        {
            public string Path;
            public long Length;
            public string Sha256;
        }

        private sealed class CustomCapture
        {
            public readonly List<RuntimeEvent> Events = new List<RuntimeEvent>();
            public int EventsLost;
            public DateTime SessionStart;
            public DateTime SessionEnd;
            public double SessionDurationMs;
            public long FirstQpc = long.MaxValue;
            public long LastQpc = long.MinValue;
            public double FirstRelativeMs;
            public double LastRelativeMs;
            public long Sequence;
        }

        private sealed class SystemCapture
        {
            public int EventsLost;
            public DateTime SessionStart;
            public DateTime SessionEnd;
            public double SessionDurationMs;
            public long FirstObservedQpc = long.MaxValue;
            public long LastObservedQpc = long.MinValue;
            public long ExplicitLostEventNotifications;
            public readonly SortedDictionary<string, long> ExplicitLostEventNames =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> ExplicitLostNotificationsBySession =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, CountBytes> FileIo =
                new SortedDictionary<string, CountBytes>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> FilePaths =
                new SortedDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            public readonly SortedDictionary<string, long> Registry =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> RegistryPaths =
                new SortedDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            public readonly SortedDictionary<string, CountBytes> DiskIoCandidates =
                new SortedDictionary<string, CountBytes>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> HardFaultPaths =
                new SortedDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            public readonly SortedDictionary<string, long> Presentation =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> RpcCom =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<string, long> TargetRpcCom =
                new SortedDictionary<string, long>(StringComparer.Ordinal);
            public readonly SortedDictionary<int, long> FileIoPerCycle =
                new SortedDictionary<int, long>();
            public readonly SortedDictionary<int, long> RegistryPerCycle =
                new SortedDictionary<int, long>();
            public readonly SortedDictionary<int, long> DiskIoPerCycle =
                new SortedDictionary<int, long>();
            public readonly SortedDictionary<int, long> PresentationPerCycle =
                new SortedDictionary<int, long>();
            public readonly List<ImageRange> A4SImages = new List<ImageRange>();
            public readonly List<CpuSample> CpuSamples = new List<CpuSample>();
            public readonly Dictionary<ulong, string> FileNamesByKey = new Dictionary<ulong, string>();
            public readonly List<IoRecord> LogicalIoRecords = new List<IoRecord>();
            public readonly List<IoRecord> HardFaultRecords = new List<IoRecord>();
            public readonly List<RelevantEvent> RelevantEvents = new List<RelevantEvent>();
            public readonly Dictionary<long, List<ulong>> DirectStacks = new Dictionary<long, List<ulong>>();
            public readonly Dictionary<long, List<ulong>> StackKeysByEventQpc = new Dictionary<long, List<ulong>>();
            public readonly Dictionary<ulong, List<ulong>> StackDefinitions = new Dictionary<ulong, List<ulong>>();
            public readonly HashSet<long> StackTargetQpcs = new HashSet<long>();
            public readonly HashSet<ulong> ReferencedStackKeys = new HashSet<ulong>();
            public long TargetHardFaultCount;
            public long TargetHardFaultBytes;
        }

        private static int Main(string[] args)
        {
            if (args.Length < 4 || args.Length > 6)
            {
                Console.Error.WriteLine(
                    "Usage: A4SStep3Correlator <custom.etl> <system.etl> <output.json> <explorer-pid> [idle.etl] [expected-cycles]");
                return 2;
            }

            string customPath = FullExistingFile(args[0], "custom ETL");
            string systemPath = FullExistingFile(args[1], "system ETL");
            string outputPath = Path.GetFullPath(args[2]);
            int targetPid;
            if (!int.TryParse(args[3], NumberStyles.None, CultureInfo.InvariantCulture, out targetPid) || targetPid <= 0)
                throw new ArgumentException("Explorer PID must be a positive decimal integer.");
            string idlePath = args.Length >= 5 && !string.IsNullOrWhiteSpace(args[4])
                ? FullExistingFile(args[4], "idle ETL")
                : null;
            int expectedCycles = 30;
            if (args.Length == 6 &&
                (!int.TryParse(args[5], NumberStyles.None, CultureInfo.InvariantCulture, out expectedCycles) || expectedCycles <= 0))
                throw new ArgumentException("Expected cycle count must be a positive decimal integer.");
            if (File.Exists(outputPath))
                throw new IOException("Refusing to overwrite existing output: " + outputPath);

            CustomCapture custom = ReadCustom(customPath, targetPid);
            double qpcFrequency = EstimateQpcFrequency(custom);
            List<string> diagnostics;
            List<Cycle> cycles = BuildCycles(custom.Events, expectedCycles, out diagnostics);
            List<Interval> openIntervals = cycles.Select(c => new Interval
            {
                Cycle = c.Number,
                StartQpc = c.OpenActivation.Qpc,
                EndQpc = c.Visible.Qpc,
                Operation = c.OpenBegin.Operation,
                ActivationSource = c.OpenActivation.ActivationSource
            }).ToList();

            SystemCapture system = ReadSystem(systemPath, targetPid, openIntervals, false);
            SystemCapture idle = idlePath == null
                ? null
                : ReadSystem(idlePath, targetPid, new List<Interval>(), true);

            bool qpcDomainOverlaps = openIntervals.Count != 0 &&
                system.FirstObservedQpc <= openIntervals.Min(i => i.StartQpc) &&
                system.LastObservedQpc >= openIntervals.Max(i => i.EndQpc);
            if (!qpcDomainOverlaps)
                diagnostics.Add("Custom and system raw-QPC domains do not fully overlap all activation-to-visible intervals.");

            var cycleReports = cycles.Select(c => new
            {
                cycle = c.Number,
                operation = c.OpenBegin.Operation,
                activationSource = c.OpenActivation.ActivationSource,
                openActivationQpc = c.OpenActivation.Qpc,
                openBeginQpc = c.OpenBegin.Qpc,
                firstPaintQpc = c.FirstPaint == null ? (long?)null : c.FirstPaint.Qpc,
                visibleQpc = c.Visible.Qpc,
                openEndQpc = c.OpenEnd == null ? (long?)null : c.OpenEnd.Qpc,
                activationToVisibleMs = Milliseconds(c.Visible.Qpc - c.OpenActivation.Qpc, qpcFrequency),
                openPathMs = Milliseconds((c.OpenEnd ?? c.Visible).Qpc - c.OpenBegin.Qpc, qpcFrequency),
                closeActivationQpc = c.CloseActivation == null ? (long?)null : c.CloseActivation.Qpc,
                closeBeginQpc = c.CloseBegin == null ? (long?)null : c.CloseBegin.Qpc,
                hiddenQpc = c.Hidden == null ? (long?)null : c.Hidden.Qpc,
                closeEndQpc = c.CloseEnd == null ? (long?)null : c.CloseEnd.Qpc,
                closeActivationToHiddenMs = c.CloseActivation == null || c.Hidden == null
                    ? (double?)null
                    : Milliseconds(c.Hidden.Qpc - c.CloseActivation.Qpc, qpcFrequency),
                closePathMs = c.CloseBegin == null || c.CloseEnd == null
                    ? (double?)null
                    : Milliseconds(c.CloseEnd.Qpc - c.CloseBegin.Qpc, qpcFrequency),
                correlatedSystem = new
                {
                    logicalFileIoEvents = ValueOrZero(system.FileIoPerCycle, c.Number),
                    registryEvents = ValueOrZero(system.RegistryPerCycle, c.Number),
                    targetPidDiskIoCandidates = ValueOrZero(system.DiskIoPerCycle, c.Number),
                    presentationInventoryEvents = ValueOrZero(system.PresentationPerCycle, c.Number)
                }
            }).ToArray();

            var report = new
            {
                schemaVersion = 1,
                method = new
                {
                    clock = "Raw TimeStampQPC from concurrent, same-boot ETLs",
                    qpcFrequencyHzEstimated = Math.Round(qpcFrequency, 3),
                    qpcDomainOverlapValidated = qpcDomainOverlaps,
                    interval = "Each warm-open interval is ActivationRequested(Event=1) through WindowVisible(Event=6) for the matching OpenPath(Event=2) operation.",
                    outputPublication = "Create-new only; the tool refuses to replace an existing output."
                },
                sources = new
                {
                    custom = Identity(customPath),
                    system = Identity(systemPath),
                    idle = idlePath == null ? null : Identity(idlePath)
                },
                target = new { explorerProcessId = targetPid, expectedCycles = expectedCycles },
                customTrace = new
                {
                    eventsLost = custom.EventsLost,
                    runtimeEventCount = custom.Events.Count,
                    sessionDurationMs = Round(custom.SessionDurationMs),
                    completeCycleCount = cycles.Count,
                    openPathThreadIds = CountThreads(cycles.Select(c => c.OpenBegin.ThreadId)),
                    activationToVisible = Distribution(cycles.Select(c =>
                        Milliseconds(c.Visible.Qpc - c.OpenActivation.Qpc, qpcFrequency))),
                    closeActivationToHidden = Distribution(cycles.Where(c => c.CloseActivation != null && c.Hidden != null).Select(c =>
                        Milliseconds(c.Hidden.Qpc - c.CloseActivation.Qpc, qpcFrequency))),
                    cycles = cycleReports
                },
                systemTrace = BuildSystemReport(system, openIntervals, false),
                idleCpuTrace = idle == null ? null : BuildSystemReport(idle, new List<Interval>(), true),
                diagnostics = diagnostics.ToArray(),
                limitations = new[]
                {
                    "TraceEventSource.EventsLost is a reader/session field; zero does not negate explicit Microsoft-Windows-Kernel-EventTracing lost-event notifications.",
                    "The explicit lost-event rows are grouped by their payload SessionName. In this capture they name DefenderApiLogger, not an A4S-prefixed session; that distinction avoids mislabeling them as proven WPR loss.",
                    "Logical FileIO and Registry counts are target-PID kernel events inside the raw-QPC open intervals; they do not by themselves prove physical storage access.",
                    "DiskIO rows are conservative target-PID candidates only. Kernel completion attribution and asynchronous I/O can fall outside an interval or carry a different PID.",
                    "Hard-fault rows are separate physical-read candidates; zero target hard faults is not proof that no device access occurred.",
                    "CPU attribution counts sampled instruction pointers directly inside the A4SMenu.dll image range. It undercounts work whose sampled IP is in a callee or kernel while A4SMenu.dll is only elsewhere on the stack.",
                    "Stack attribution joins raw StackWalk EventTimeStampQPC values (including stack-key definitions) to target events. Events without a joined stack remain unattributed; a missing A4S frame is not proof that A4S was absent.",
                    "DWM, DirectComposition, DxgKrnl, DXGI, and Win32k rows are an interval inventory only. No event is labeled the exact physically displayed A4S frame.",
                    "RPC/COM rows are provider/name inventory only; they do not prove an individual in-process COM shell call."
                }
            };

            PublishCreateNewJson(outputPath, report);
            Console.WriteLine(outputPath);
            Console.WriteLine("cycles=" + cycles.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("systemEventsLost=" + system.EventsLost.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("explicitLostNotifications=" + system.ExplicitLostEventNotifications.ToString(CultureInfo.InvariantCulture));
            return diagnostics.Count == 0 ? 0 : 5;
        }

        private static CustomCapture ReadCustom(string path, int targetPid)
        {
            var capture = new CustomCapture();
            using (var source = new ETWTraceEventSource(path))
            {
                source.Dynamic.All += delegate(TraceEvent data)
                {
                    if (data.ProviderGuid != A4SProvider || data.ProcessID != targetPid)
                        return;
                    int eventId = PayloadInt(data, "Event");
                    int stage = PayloadInt(data, "Stage");
                    long operation = PayloadLong(data, "Operation");
                    int activation = PayloadInt(data, "ActivationSource");
                    capture.Events.Add(new RuntimeEvent
                    {
                        Qpc = data.TimeStampQPC,
                        Sequence = capture.Sequence++,
                        Event = eventId,
                        Stage = stage,
                        Operation = operation,
                        ActivationSource = activation,
                        ProcessId = PayloadInt(data, "ProcessId"),
                        ThreadId = PayloadInt(data, "ThreadId")
                    });
                    if (capture.FirstQpc == long.MaxValue)
                    {
                        capture.FirstQpc = data.TimeStampQPC;
                        capture.FirstRelativeMs = data.TimeStampRelativeMSec;
                    }
                    capture.LastQpc = data.TimeStampQPC;
                    capture.LastRelativeMs = data.TimeStampRelativeMSec;
                };
                source.Process();
                capture.EventsLost = source.EventsLost;
                capture.SessionStart = source.SessionStartTime;
                capture.SessionEnd = source.SessionEndTime;
                capture.SessionDurationMs = source.SessionDuration.TotalMilliseconds;
            }
            capture.Events.Sort((left, right) =>
            {
                int qpc = left.Qpc.CompareTo(right.Qpc);
                return qpc != 0 ? qpc : left.Sequence.CompareTo(right.Sequence);
            });
            if (capture.Events.Count == 0)
                throw new InvalidDataException("No target-PID A4SMenu.Runtime events were found in custom ETL.");
            return capture;
        }

        private static List<Cycle> BuildCycles(List<RuntimeEvent> events, int expected, out List<string> diagnostics)
        {
            diagnostics = new List<string>();
            var cycles = new List<Cycle>();
            List<RuntimeEvent> opens = events.Where(e => e.Event == 2 && e.Stage == 1).ToList();
            long previousBoundary = long.MinValue;
            for (int index = 0; index < opens.Count; index++)
            {
                RuntimeEvent open = opens[index];
                RuntimeEvent nextOpen = index + 1 < opens.Count ? opens[index + 1] : null;
                long upper = nextOpen == null ? long.MaxValue : nextOpen.Qpc;
                RuntimeEvent activation = events.LastOrDefault(e =>
                    e.Event == 1 && e.Stage == 0 && e.Qpc >= previousBoundary && e.Qpc <= open.Qpc);
                RuntimeEvent visible = events.FirstOrDefault(e =>
                    e.Event == 6 && e.Stage == 0 && e.Operation == open.Operation && e.Qpc >= open.Qpc && e.Qpc < upper);
                if (activation == null || visible == null)
                {
                    diagnostics.Add("Incomplete open cycle for operation " + open.Operation.ToString(CultureInfo.InvariantCulture) + ".");
                    continue;
                }
                RuntimeEvent hidden = events.FirstOrDefault(e =>
                    e.Event == 11 && e.Stage == 0 && e.Operation == open.Operation && e.Qpc >= visible.Qpc && e.Qpc < upper);
                RuntimeEvent closeBegin = hidden == null ? null : events.LastOrDefault(e =>
                    e.Event == 10 && e.Stage == 1 && e.Qpc >= visible.Qpc && e.Qpc <= hidden.Qpc);
                RuntimeEvent closeActivation = closeBegin == null ? null : events.LastOrDefault(e =>
                    e.Event == 1 && e.Stage == 0 && e.Qpc >= visible.Qpc && e.Qpc <= closeBegin.Qpc);
                RuntimeEvent closeEnd = closeBegin == null ? null : events.FirstOrDefault(e =>
                    e.Event == 10 && e.Stage == 2 && e.Operation == closeBegin.Operation && e.Qpc >= closeBegin.Qpc && e.Qpc < upper);
                cycles.Add(new Cycle
                {
                    Number = cycles.Count + 1,
                    OpenActivation = activation,
                    OpenBegin = open,
                    FirstPaint = events.FirstOrDefault(e => e.Event == 7 && e.Stage == 0 && e.Operation == open.Operation && e.Qpc >= open.Qpc && e.Qpc <= visible.Qpc),
                    Visible = visible,
                    OpenEnd = events.FirstOrDefault(e => e.Event == 2 && e.Stage == 2 && e.Operation == open.Operation && e.Qpc >= open.Qpc && e.Qpc < upper),
                    CloseActivation = closeActivation,
                    CloseBegin = closeBegin,
                    Hidden = hidden,
                    CloseEnd = closeEnd
                });
                if (hidden == null || closeBegin == null || closeActivation == null || closeEnd == null)
                    diagnostics.Add("Incomplete close cycle for open operation " + open.Operation.ToString(CultureInfo.InvariantCulture) + ".");
                previousBoundary = hidden == null ? visible.Qpc : hidden.Qpc;
            }
            if (cycles.Count != expected)
                diagnostics.Add(string.Format(CultureInfo.InvariantCulture,
                    "Expected {0} complete open cycles but derived {1}.", expected, cycles.Count));
            return cycles;
        }

        private static SystemCapture ReadSystem(string path, int targetPid, List<Interval> opens, bool idle)
        {
            var capture = new SystemCapture();
            using (var source = new ETWTraceEventSource(path))
            {
                Action<TraceEvent> observe = data =>
                {
                    capture.FirstObservedQpc = Math.Min(capture.FirstObservedQpc, data.TimeStampQPC);
                    capture.LastObservedQpc = Math.Max(capture.LastObservedQpc, data.TimeStampQPC);
                };

                Action<TraceEvent> file = data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    string key = data.EventName ?? data.OpcodeName ?? "unknown";
                    Count(capture.FileIo, key, 0);
                    if (interval != null) Increment(capture.FileIoPerCycle, interval.Cycle);
                    RecordRelevant(capture, data, interval, "logicalFileIo", key);
                    AddPath(capture.FilePaths, PayloadText(data, "FileName"));
                    AddPath(capture.FilePaths, PayloadText(data, "DirectoryName"));
                };
                Action<FileIOReadWriteTraceData> readWrite = data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    Count(capture.FileIo, data.EventName ?? "FileIO", Math.Max(0, data.IoSize));
                    if (interval != null) Increment(capture.FileIoPerCycle, interval.Cycle);
                    RecordRelevant(capture, data, interval, "logicalFileIo", data.EventName ?? "FileIO");
                    capture.LogicalIoRecords.Add(new IoRecord { FileKey = data.FileKey, FileName = data.FileName });
                };

                Action<FileIONameTraceData> fileName = data =>
                {
                    observe(data);
                    if (data.FileKey != 0 && !string.IsNullOrWhiteSpace(data.FileName))
                        capture.FileNamesByKey[data.FileKey] = data.FileName;
                };
                source.Kernel.FileIOName += data => fileName(data);
                source.Kernel.FileIOFileCreate += data => fileName(data);
                source.Kernel.FileIOFileDelete += data => fileName(data);
                source.Kernel.FileIOFileRundown += data => fileName(data);

                source.Kernel.FileIOCreate += data => file(data);
                source.Kernel.FileIOCleanup += data => file(data);
                source.Kernel.FileIOClose += data => file(data);
                source.Kernel.FileIOFlush += data => file(data);
                source.Kernel.FileIORead += data => readWrite(data);
                source.Kernel.FileIOWrite += data => readWrite(data);
                source.Kernel.FileIOSetInfo += data => file(data);
                source.Kernel.FileIODelete += data => file(data);
                source.Kernel.FileIORename += data => file(data);
                source.Kernel.FileIOQueryInfo += data => file(data);
                source.Kernel.FileIOFSControl += data => file(data);
                source.Kernel.FileIODirEnum += data => file(data);
                source.Kernel.FileIODirNotify += data => file(data);
                source.Kernel.FileIOMapFile += data => file(data);
                source.Kernel.FileIOUnmapFile += data => file(data);

                Action<RegistryTraceData> registry = data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    Count(capture.Registry, data.EventName ?? data.OpcodeName ?? "Registry");
                    if (interval != null) Increment(capture.RegistryPerCycle, interval.Cycle);
                    RecordRelevant(capture, data, interval, "registry", data.EventName ?? data.OpcodeName ?? "Registry");
                    AddPath(capture.RegistryPaths, data.KeyName);
                    AddPath(capture.RegistryPaths, data.ValueName);
                };
                source.Kernel.RegistryCreate += data => registry(data);
                source.Kernel.RegistryOpen += data => registry(data);
                source.Kernel.RegistryDelete += data => registry(data);
                source.Kernel.RegistryQuery += data => registry(data);
                source.Kernel.RegistrySetValue += data => registry(data);
                source.Kernel.RegistryDeleteValue += data => registry(data);
                source.Kernel.RegistryQueryValue += data => registry(data);
                source.Kernel.RegistryEnumerateKey += data => registry(data);
                source.Kernel.RegistryEnumerateValueKey += data => registry(data);
                source.Kernel.RegistryQueryMultipleValue += data => registry(data);
                source.Kernel.RegistrySetInformation += data => registry(data);
                source.Kernel.RegistryFlush += data => registry(data);
                source.Kernel.RegistryVirtualize += data => registry(data);
                source.Kernel.RegistryClose += data => registry(data);

                Action<DiskIOTraceData> disk = data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    Count(capture.DiskIoCandidates, data.EventName ?? "DiskIO", Math.Max(0, data.TransferSize));
                    if (interval != null) Increment(capture.DiskIoPerCycle, interval.Cycle);
                    RecordRelevant(capture, data, interval, "diskIoCandidate", data.EventName ?? "DiskIO");
                };
                source.Kernel.DiskIORead += data => disk(data);
                source.Kernel.DiskIOWrite += data => disk(data);

                source.Kernel.MemoryHardFault += data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    capture.TargetHardFaultCount++;
                    capture.TargetHardFaultBytes += Math.Max(0, data.ByteCount);
                    capture.HardFaultRecords.Add(new IoRecord { FileKey = data.FileKey, FileName = data.FileName });
                    RecordRelevant(capture, data, interval, "hardFault", data.EventName ?? "HardFault");
                };

                Action<ImageLoadTraceData> image = data =>
                {
                    observe(data);
                    if (data.ProcessID == targetPid &&
                        string.Equals(Path.GetFileName(data.FileName), "A4SMenu.dll", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!capture.A4SImages.Any(i => i.Base == data.ImageBase && i.Size == (ulong)Math.Max(0, data.ImageSize)))
                            capture.A4SImages.Add(new ImageRange { Base = data.ImageBase, Size = (ulong)Math.Max(0, data.ImageSize), FileName = data.FileName });
                    }
                };
                source.Kernel.ImageLoad += data => image(data);
                source.Kernel.ImageDCStart += data => image(data);
                source.Kernel.ImageDCStop += data => image(data);

                source.Kernel.PerfInfoSample += data =>
                {
                    observe(data);
                    if (data.ProcessID != targetPid) return;
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (!idle && interval == null) return;
                    capture.CpuSamples.Add(new CpuSample
                    {
                        Qpc = data.TimeStampQPC,
                        InstructionPointer = data.InstructionPointer,
                        InOpen = interval != null,
                        Cycle = interval == null ? 0 : interval.Cycle
                    });
                    capture.StackTargetQpcs.Add(data.TimeStampQPC);
                };

                source.Kernel.StackWalkStack += data =>
                {
                    observe(data);
                    if (capture.StackTargetQpcs.Contains(data.EventTimeStampQPC))
                        AddFrames(capture.DirectStacks, data.EventTimeStampQPC,
                            Enumerable.Range(0, data.FrameCount).Select(data.InstructionPointer));
                };
                Action<StackWalkRefTraceData> stackReference = data =>
                {
                    observe(data);
                    if (capture.StackTargetQpcs.Contains(data.EventTimeStampQPC))
                    {
                        AddStackKey(capture.StackKeysByEventQpc, data.EventTimeStampQPC, data.StackKey);
                        capture.ReferencedStackKeys.Add(data.StackKey);
                    }
                };
                source.Kernel.StackWalkStackKeyUser += data => stackReference(data);
                source.Kernel.StackWalkStackKeyKernel += data => stackReference(data);
                Action<StackWalkDefTraceData> stackDefinition = data =>
                {
                    observe(data);
                    if (capture.ReferencedStackKeys.Contains(data.StackKey))
                        capture.StackDefinitions[data.StackKey] = Enumerable.Range(0, data.FrameCount)
                            .Select(data.InstructionPointer).ToList();
                };
                source.Kernel.StackWalkKeyRundown += data => stackDefinition(data);
                source.Kernel.StackWalkKeyDelete += data => stackDefinition(data);

                source.Dynamic.All += data =>
                {
                    observe(data);
                    string provider = data.ProviderName ?? data.ProviderGuid.ToString("D");
                    string eventName = data.EventName ?? data.OpcodeName ?? "unknown";
                    if (provider.IndexOf("Kernel-EventTracing", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        eventName.IndexOf("LOST_EVENT", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        capture.ExplicitLostEventNotifications++;
                        Count(capture.ExplicitLostEventNames, provider + "/" + eventName);
                        string session = PayloadText(data, "SessionName") ?? "<missing-session-name>";
                        string lostProvider = PayloadText(data, "ProviderId") ?? "<missing-provider-id>";
                        string status = PayloadText(data, "StatusCode") ?? "<missing-status-code>";
                        Count(capture.ExplicitLostNotificationsBySession,
                            session + " | provider=" + lostProvider + " | status=" + status);
                    }
                    Interval interval = FindInterval(opens, data.TimeStampQPC);
                    if (idle || interval == null) return;
                    if (IsPresentationProvider(provider))
                    {
                        Count(capture.Presentation, provider + "/" + eventName);
                        Increment(capture.PresentationPerCycle, interval.Cycle);
                    }
                    if (IsRpcComProvider(provider, eventName))
                    {
                        Count(capture.RpcCom, provider + "/" + eventName);
                        if (data.ProcessID == targetPid)
                            Count(capture.TargetRpcCom, provider + "/" + eventName);
                    }
                };

                source.Process();
                capture.EventsLost = source.EventsLost;
                capture.SessionStart = source.SessionStartTime;
                capture.SessionEnd = source.SessionEndTime;
                capture.SessionDurationMs = source.SessionDuration.TotalMilliseconds;
            }
            foreach (IoRecord record in capture.LogicalIoRecords)
                AddPath(capture.FilePaths, ResolveFileName(capture, record));
            foreach (IoRecord record in capture.HardFaultRecords)
                AddPath(capture.HardFaultPaths, ResolveFileName(capture, record));
            capture.A4SImages.Sort((a, b) => a.Base.CompareTo(b.Base));
            return capture;
        }

        private static object BuildSystemReport(SystemCapture capture, List<Interval> opens, bool idle)
        {
            long directSamples = capture.CpuSamples.LongCount(sample =>
                capture.A4SImages.Any(image => sample.InstructionPointer >= image.Base && sample.InstructionPointer < image.Base + image.Size));
            var directRvas = new SortedDictionary<string, long>(StringComparer.Ordinal);
            var cpuPerCycle = new SortedDictionary<int, long>();
            var directCpuPerCycle = new SortedDictionary<int, long>();
            foreach (CpuSample sample in capture.CpuSamples)
            {
                if (sample.Cycle != 0) Increment(cpuPerCycle, sample.Cycle);
                ImageRange image = capture.A4SImages.FirstOrDefault(candidate =>
                    sample.InstructionPointer >= candidate.Base && sample.InstructionPointer < candidate.Base + candidate.Size);
                if (image == null) continue;
                Count(directRvas, "0x" + (sample.InstructionPointer - image.Base).ToString("X", CultureInfo.InvariantCulture));
                if (sample.Cycle != 0) Increment(directCpuPerCycle, sample.Cycle);
            }
            return new
            {
                mode = idle ? "passive-idle" : "warm-open-correlation",
                eventsLost = capture.EventsLost,
                explicitLostEventNotifications = capture.ExplicitLostEventNotifications,
                explicitLostEventNames = capture.ExplicitLostEventNames,
                explicitLostNotificationsBySession = capture.ExplicitLostNotificationsBySession,
                explicitLostNotificationRelevance = capture.ExplicitLostNotificationsBySession.Keys.All(key =>
                    key.StartsWith("DefenderApiLogger |", StringComparison.Ordinal))
                    ? "Every explicit lost-event payload names DefenderApiLogger; none names an A4S-prefixed session."
                    : "At least one explicit lost-event payload does not name DefenderApiLogger; inspect the grouped rows.",
                sessionDurationMs = Round(capture.SessionDurationMs),
                observedQpcRange = new
                {
                    first = capture.FirstObservedQpc == long.MaxValue ? (long?)null : capture.FirstObservedQpc,
                    last = capture.LastObservedQpc == long.MinValue ? (long?)null : capture.LastObservedQpc
                },
                logicalFileIo = new
                {
                    totalEvents = capture.FileIo.Values.Sum(value => value.Count),
                    readWriteBytesRequested = capture.FileIo.Values.Sum(value => value.Bytes),
                    byEvent = Simplify(capture.FileIo),
                    threadIds = CountThreads(capture.RelevantEvents.Where(value => value.Category == "logicalFileIo").Select(value => value.ThreadId)),
                    topPaths = TopPaths(capture.FilePaths, 50)
                },
                registry = new
                {
                    totalEvents = capture.Registry.Values.Sum(),
                    byEvent = capture.Registry,
                    threadIds = CountThreads(capture.RelevantEvents.Where(value => value.Category == "registry").Select(value => value.ThreadId)),
                    topKeysAndValues = TopPaths(capture.RegistryPaths, 50)
                },
                physicalIoCandidates = new
                {
                    targetPidDiskIoEventCount = capture.DiskIoCandidates.Values.Sum(value => value.Count),
                    targetPidDiskIoBytes = capture.DiskIoCandidates.Values.Sum(value => value.Bytes),
                    targetPidDiskIoByEvent = Simplify(capture.DiskIoCandidates),
                    targetPidHardFaultCount = capture.TargetHardFaultCount,
                    targetPidHardFaultBytes = capture.TargetHardFaultBytes,
                    hardFaultFiles = TopPaths(capture.HardFaultPaths, 50),
                    conclusion = capture.DiskIoCandidates.Values.Sum(value => value.Count) == 0 && capture.TargetHardFaultCount == 0
                        ? "No target-PID DiskIO completions or hard faults were observed in scope; this is supporting evidence, not proof, of no physical I/O."
                        : "Target-PID physical-I/O candidates were observed; inspect the event/path aggregates before making a warm-toggle claim."
                },
                cpuSampling = new
                {
                    targetPidSampleCount = capture.CpuSamples.Count,
                    directInstructionPointerInA4SMenuDllCount = directSamples,
                    directInstructionPointerRvas = directRvas.OrderByDescending(pair => pair.Value)
                        .ThenBy(pair => pair.Key, StringComparer.Ordinal)
                        .Select(pair => new { rva = pair.Key, count = pair.Value }).ToArray(),
                    perOpenCycle = cpuPerCycle.Keys.Union(directCpuPerCycle.Keys).OrderBy(value => value)
                        .Select(cycle => new
                        {
                            cycle = cycle,
                            targetPidSamples = ValueOrZero(cpuPerCycle, cycle),
                            directA4SMenuDllSamples = ValueOrZero(directCpuPerCycle, cycle)
                        }).ToArray(),
                    a4sImageRanges = capture.A4SImages.Select(image => new
                    {
                        imageBase = "0x" + image.Base.ToString("X16", CultureInfo.InvariantCulture),
                        imageSize = image.Size,
                        fileName = image.FileName
                    }).ToArray(),
                    attribution = "Direct sampled instruction pointer count; see stackAttribution for joined inclusive stacks."
                },
                stackAttribution = BuildStackAttribution(capture),
                presentationInventory = new
                {
                    totalEvents = capture.Presentation.Values.Sum(),
                    byProviderEvent = capture.Presentation,
                    exactDisplayedFrameMeasured = false
                },
                rpcComInventory = new
                {
                    globalIntervalEventCount = capture.RpcCom.Values.Sum(),
                    targetPidIntervalEventCount = capture.TargetRpcCom.Values.Sum(),
                    globalByProviderEvent = capture.RpcCom,
                    targetPidByProviderEvent = capture.TargetRpcCom,
                    comProviderCaptured = capture.RpcCom.Keys.Any(key => key.IndexOf("COMRuntime", StringComparison.OrdinalIgnoreCase) >= 0 || key.IndexOf("-COM/", StringComparison.OrdinalIgnoreCase) >= 0)
                }
            };
        }

        private static object BuildStackAttribution(SystemCapture capture)
        {
            var eventCategories = capture.RelevantEvents
                .GroupBy(value => value.Category, StringComparer.Ordinal)
                .OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group =>
                {
                    RelevantEvent[] events = group.ToArray();
                    RelevantEvent[] withStack = events.Where(value => GetFrames(capture, value.Qpc).Count != 0).ToArray();
                    RelevantEvent[] withA4S = withStack.Where(value => ContainsA4SFrame(capture, GetFrames(capture, value.Qpc))).ToArray();
                    return new
                    {
                        category = group.Key,
                        eventCount = events.Length,
                        eventsWithJoinedStack = withStack.Length,
                        eventsWithA4SMenuDllFrame = withA4S.Length,
                        threadIds = CountThreads(events.Select(value => value.ThreadId)),
                        a4sAttributedThreadIds = CountThreads(withA4S.Select(value => value.ThreadId)),
                        byEventName = events.GroupBy(value => value.Name, StringComparer.Ordinal)
                            .OrderBy(value => value.Key, StringComparer.Ordinal)
                            .Select(value => new
                            {
                                name = value.Key,
                                count = value.Count(),
                                withJoinedStack = value.Count(item => GetFrames(capture, item.Qpc).Count != 0),
                                withA4SMenuDllFrame = value.Count(item => ContainsA4SFrame(capture, GetFrames(capture, item.Qpc)))
                            }).ToArray()
                    };
                }).ToArray();

            int cpuWithStack = capture.CpuSamples.Count(value => GetFrames(capture, value.Qpc).Count != 0);
            int cpuWithA4S = capture.CpuSamples.Count(value => ContainsA4SFrame(capture, GetFrames(capture, value.Qpc)));
            return new
            {
                joinKey = "StackWalk EventTimeStampQPC == target event TimeStampQPC",
                directStackRecordCount = capture.DirectStacks.Count,
                stackKeyReferenceEventCount = capture.StackKeysByEventQpc.Count,
                referencedStackDefinitionCount = capture.StackDefinitions.Count,
                eventCategories = eventCategories,
                cpuSamples = new
                {
                    count = capture.CpuSamples.Count,
                    withJoinedStack = cpuWithStack,
                    inclusiveStackContainsA4SMenuDll = cpuWithA4S
                },
                qualification = "Only events with a joined StackWalk record can receive inclusive A4SMenu.dll attribution."
            };
        }

        private static void RecordRelevant(SystemCapture capture, TraceEvent data, Interval interval, string category, string name)
        {
            capture.RelevantEvents.Add(new RelevantEvent
            {
                Qpc = data.TimeStampQPC,
                Cycle = interval == null ? 0 : interval.Cycle,
                ThreadId = data.ThreadID,
                Category = category,
                Name = name
            });
            capture.StackTargetQpcs.Add(data.TimeStampQPC);
        }

        private static void AddFrames(Dictionary<long, List<ulong>> values, long qpc, IEnumerable<ulong> frames)
        {
            List<ulong> current;
            if (!values.TryGetValue(qpc, out current))
            {
                current = new List<ulong>();
                values.Add(qpc, current);
            }
            current.AddRange(frames);
        }

        private static void AddStackKey(Dictionary<long, List<ulong>> values, long qpc, ulong stackKey)
        {
            List<ulong> current;
            if (!values.TryGetValue(qpc, out current))
            {
                current = new List<ulong>();
                values.Add(qpc, current);
            }
            current.Add(stackKey);
        }

        private static List<ulong> GetFrames(SystemCapture capture, long qpc)
        {
            var frames = new List<ulong>();
            List<ulong> direct;
            if (capture.DirectStacks.TryGetValue(qpc, out direct)) frames.AddRange(direct);
            List<ulong> keys;
            if (capture.StackKeysByEventQpc.TryGetValue(qpc, out keys))
            {
                foreach (ulong key in keys)
                {
                    List<ulong> definition;
                    if (capture.StackDefinitions.TryGetValue(key, out definition)) frames.AddRange(definition);
                }
            }
            return frames;
        }

        private static bool ContainsA4SFrame(SystemCapture capture, IEnumerable<ulong> frames)
        {
            return frames.Any(frame => capture.A4SImages.Any(image => frame >= image.Base && frame < image.Base + image.Size));
        }

        private static SortedDictionary<string, long> CountThreads(IEnumerable<int> threadIds)
        {
            var result = new SortedDictionary<string, long>(StringComparer.Ordinal);
            foreach (int threadId in threadIds)
                Count(result, threadId.ToString(CultureInfo.InvariantCulture));
            return result;
        }

        private static object Distribution(IEnumerable<double> input)
        {
            double[] values = input.OrderBy(value => value).ToArray();
            if (values.Length == 0) return new { count = 0, percentileMethod = "nearest-rank", p50Ms = (double?)null, p95Ms = (double?)null, maxMs = (double?)null };
            return new
            {
                count = values.Length,
                percentileMethod = "nearest-rank",
                p50Ms = (double?)values[Math.Max(0, (int)Math.Ceiling(values.Length * 0.50) - 1)],
                p95Ms = (double?)values[Math.Max(0, (int)Math.Ceiling(values.Length * 0.95) - 1)],
                maxMs = (double?)values[values.Length - 1]
            };
        }

        private static double EstimateQpcFrequency(CustomCapture custom)
        {
            double relativeSeconds = (custom.LastRelativeMs - custom.FirstRelativeMs) / 1000.0;
            if (relativeSeconds <= 0 || custom.LastQpc <= custom.FirstQpc)
                throw new InvalidDataException("Could not estimate QPC frequency from custom ETL events.");
            double frequency = (custom.LastQpc - custom.FirstQpc) / relativeSeconds;
            if (frequency < 1000000 || frequency > 100000000)
                throw new InvalidDataException("Implausible QPC frequency estimate: " + frequency.ToString("R", CultureInfo.InvariantCulture));
            return frequency;
        }

        private static Interval FindInterval(List<Interval> intervals, long qpc)
        {
            for (int index = 0; index < intervals.Count; index++)
                if (qpc >= intervals[index].StartQpc && qpc <= intervals[index].EndQpc)
                    return intervals[index];
            return null;
        }

        private static bool IsPresentationProvider(string provider)
        {
            return provider.IndexOf("Dwm", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.IndexOf("DirectComposition", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.IndexOf("DxgKrnl", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.IndexOf("DXGI", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.IndexOf("Win32k", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsRpcComProvider(string provider, string eventName)
        {
            return provider.IndexOf("RPC", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.IndexOf("COMRuntime", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   provider.EndsWith("-COM", StringComparison.OrdinalIgnoreCase);
        }

        private static string ResolveFileName(SystemCapture capture, IoRecord record)
        {
            if (!string.IsNullOrWhiteSpace(record.FileName)) return record.FileName;
            string resolved;
            return record.FileKey != 0 && capture.FileNamesByKey.TryGetValue(record.FileKey, out resolved)
                ? resolved
                : null;
        }

        private static int PayloadInt(TraceEvent data, string name)
        {
            return checked((int)PayloadLong(data, name));
        }

        private static long PayloadLong(TraceEvent data, string name)
        {
            object value = data.PayloadByName(name);
            return Convert.ToInt64(value, CultureInfo.InvariantCulture);
        }

        private static string PayloadText(TraceEvent data, string name)
        {
            try
            {
                object value = data.PayloadByName(name);
                return value == null ? null : Convert.ToString(value, CultureInfo.InvariantCulture);
            }
            catch
            {
                return null;
            }
        }

        private static void Count(SortedDictionary<string, CountBytes> values, string key, long bytes)
        {
            CountBytes value;
            if (!values.TryGetValue(key, out value))
            {
                value = new CountBytes();
                values.Add(key, value);
            }
            value.Count++;
            value.Bytes += bytes;
        }

        private static void Count(SortedDictionary<string, long> values, string key)
        {
            long value;
            values.TryGetValue(key, out value);
            values[key] = value + 1;
        }

        private static void Increment(SortedDictionary<int, long> values, int key)
        {
            long value;
            values.TryGetValue(key, out value);
            values[key] = value + 1;
        }

        private static long ValueOrZero(SortedDictionary<int, long> values, int key)
        {
            long value;
            return values.TryGetValue(key, out value) ? value : 0;
        }

        private static void AddPath(SortedDictionary<string, long> values, string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            Count(values, path);
        }

        private static object[] TopPaths(SortedDictionary<string, long> values, int limit)
        {
            return values.OrderByDescending(pair => pair.Value)
                .ThenBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
                .Take(limit)
                .Select(pair => (object)new { path = pair.Key, count = pair.Value })
                .ToArray();
        }

        private static SortedDictionary<string, object> Simplify(SortedDictionary<string, CountBytes> values)
        {
            var result = new SortedDictionary<string, object>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, CountBytes> pair in values)
                result.Add(pair.Key, new { count = pair.Value.Count, bytes = pair.Value.Bytes });
            return result;
        }

        private static double Milliseconds(long qpcDelta, double frequency)
        {
            return Math.Round(qpcDelta * 1000.0 / frequency, 6, MidpointRounding.AwayFromZero);
        }

        private static double Round(double value)
        {
            return Math.Round(value, 6, MidpointRounding.AwayFromZero);
        }

        private static EtlIdentity Identity(string path)
        {
            var file = new FileInfo(path);
            return new EtlIdentity { Path = path, Length = file.Length, Sha256 = Sha256(path) };
        }

        private static string Sha256(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", string.Empty);
        }

        private static string FullExistingFile(string path, string label)
        {
            string full = Path.GetFullPath(path);
            if (!File.Exists(full)) throw new FileNotFoundException("Missing " + label + ": " + full, full);
            return full;
        }

        private static void PublishCreateNewJson(string output, object report)
        {
            string parent = Path.GetDirectoryName(output);
            if (string.IsNullOrEmpty(parent)) throw new InvalidOperationException("Output has no parent directory.");
            Directory.CreateDirectory(parent);
            string temporary = output + ".partial-" + Guid.NewGuid().ToString("N");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)))
                using (var json = new JsonTextWriter(writer))
                {
                    json.Formatting = Formatting.Indented;
                    JsonSerializer.CreateDefault(new JsonSerializerSettings
                    {
                        Culture = CultureInfo.InvariantCulture,
                        DateFormatHandling = DateFormatHandling.IsoDateFormat,
                        DateTimeZoneHandling = DateTimeZoneHandling.Utc
                    }).Serialize(json, report);
                }
                File.Move(temporary, output);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
    }
}
