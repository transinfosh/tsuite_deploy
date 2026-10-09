// Native Windows console transport. PowerShell 5.1 compiles this in memory.
// ConPTY lifecycle follows https://learn.microsoft.com/windows/console/creating-a-pseudoconsole-session.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace TSuiteSupport {
    public static class WindowsRelay {
        public static void ReplaceFile(string source, string destination) {
            File.Replace(source, destination, null);
        }

        public static void CreateSessionDirectory(string path) {
            // Directory.CreateDirectory is idempotent; native CreateDirectory refuses an existing identity.
            Check(CreateDirectory(path, IntPtr.Zero));
        }

        public static string Quote(string value) {
            // Windows CRT argument quoting, including empty arguments and trailing backslashes.
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value) {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') result.Append('\\', slashes * 2 + 1);
                else result.Append('\\', slashes);
                result.Append(character);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        public static string Arguments(string[] values) {
            return String.Join(" ", Array.ConvertAll(values, Quote));
        }

        static ProcessStartInfo StartInfo(string executable, string[] arguments) {
            return new ProcessStartInfo(executable, Arguments(arguments)) {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
        }

        public sealed class Result {
            public int ExitCode;
            public string Output;
            public string Error;
        }

        static string ReadLimited(Stream stream) {
            byte[] buffer = new byte[32769];
            int length = 0, count;
            while (length < buffer.Length && (count = stream.Read(buffer, length, buffer.Length - length)) > 0)
                length += count;
            if (length == buffer.Length) throw new IOException("SSH response too large.");
            return Encoding.UTF8.GetString(buffer, 0, length);
        }

        public static Result Capture(string executable, string[] arguments, int timeoutMilliseconds) {
            using (Process process = Process.Start(StartInfo(executable, arguments))) {
                process.StandardInput.Close();
                string output = null, error = null;
                Exception failure = null;
                Thread stdout = Worker(delegate {
                    try { output = ReadLimited(process.StandardOutput.BaseStream); }
                    catch (Exception e) { Interlocked.CompareExchange(ref failure, e, null); }
                });
                Thread stderr = Worker(delegate {
                    try { error = ReadLimited(process.StandardError.BaseStream); }
                    catch (Exception e) { Interlocked.CompareExchange(ref failure, e, null); }
                });
                Stopwatch elapsed = Stopwatch.StartNew();
                try {
                    while (!process.WaitForExit(50)) {
                        if (failure != null) throw failure;
                        if (elapsed.ElapsedMilliseconds >= timeoutMilliseconds) throw new TimeoutException("SSH request timed out.");
                    }
                    if (!stdout.Join(1000) || !stderr.Join(1000)) throw new IOException("SSH streams did not close.");
                    if (failure != null) throw failure;
                    return new Result { ExitCode = process.ExitCode, Output = output, Error = error };
                } finally {
                    if (!process.HasExited) { process.Kill(); process.WaitForExit(); }
                }
            }
        }

        static Thread Worker(ThreadStart action) {
            Thread thread = new Thread(action) { IsBackground = true };
            thread.Start();
            return thread;
        }

        sealed class Activity : IDisposable {
            readonly string executable;
            readonly string[] arguments;
            readonly ManualResetEvent stop = new ManualResetEvent(false);
            readonly Stopwatch clock = Stopwatch.StartNew();
            readonly Thread reporter;
            long lastInput = -60000;
            long version, reported;
            public Activity(string exe, string[] args, bool command) {
                executable = exe; arguments = args;
                if (command) Input();
                reporter = Worker(delegate {
                    do { Report(); } while (!stop.WaitOne(15000));
                });
            }
            public void Input() {
                Interlocked.Exchange(ref lastInput, clock.ElapsedMilliseconds);
                Interlocked.Increment(ref version);
            }
            void Report() {
                long observed = Interlocked.Read(ref version);
                if (observed <= reported || clock.ElapsedMilliseconds - Interlocked.Read(ref lastInput) > 30000) return;
                try {
                    if (Capture(executable, arguments, 20000).ExitCode == 0) reported = observed;
                } catch (IOException) { } catch (TimeoutException) { } catch (Win32Exception) { }
            }
            public void Dispose() {
                stop.Set();
                reporter.Join(); // Each report is bounded by Capture's timeout.
                Report(); // Flush fast commands and final real input, without manufacturing activity.
                stop.Dispose();
            }
        }

        sealed class InputPump : IDisposable {
            readonly Thread thread;
            volatile bool stopped;
            uint nativeThreadId;
            public InputPump(Stream input, Stream destination, Activity activity) {
                thread = Worker(delegate {
                    if (Environment.OSVersion.Platform == PlatformID.Win32NT) nativeThreadId = GetCurrentThreadId();
                    byte[] buffer = new byte[65536];
                    try {
                        int count;
                        while (!stopped && (count = input.Read(buffer, 0, buffer.Length)) > 0) {
                            if (stopped) break;
                            activity.Input();
                            destination.Write(buffer, 0, count);
                            destination.Flush();
                        }
                    } catch (IOException) { } catch (ObjectDisposedException) { }
                    finally { destination.Dispose(); }
                });
            }
            public void Dispose() {
                stopped = true;
                // A blocked stdin read must not steal input from the next PowerShell command.
                if (Environment.OSVersion.Platform == PlatformID.Win32NT && nativeThreadId != 0) {
                    IntPtr handle = OpenThread(0x0001, false, nativeThreadId);
                    if (handle != IntPtr.Zero) {
                        try { CancelSynchronousIo(handle); } finally { CloseHandle(handle); }
                    }
                }
                thread.Join(1000);
            }
        }

        public static int RunCommand(string executable, string[] arguments, string[] activityArguments,
                                     Stream input, Stream output, Stream error) {
            using (Process process = Process.Start(StartInfo(executable, arguments)))
            using (Activity activity = new Activity(executable, activityArguments, true))
            using (InputPump pump = new InputPump(input, process.StandardInput.BaseStream, activity)) {
                Exception failure = null;
                Thread stdout = Worker(delegate {
                    try { process.StandardOutput.BaseStream.CopyTo(output); output.Flush(); }
                    catch (Exception e) { Interlocked.CompareExchange(ref failure, e, null); }
                });
                Thread stderr = Worker(delegate {
                    try { process.StandardError.BaseStream.CopyTo(error); error.Flush(); }
                    catch (Exception e) { Interlocked.CompareExchange(ref failure, e, null); }
                });
                try {
                    while (!process.WaitForExit(100)) { if (failure != null) throw failure; }
                    stdout.Join(); stderr.Join();
                    if (failure != null) throw failure;
                    return process.ExitCode;
                } finally {
                    if (!process.HasExited) { process.Kill(); process.WaitForExit(); }
                }
            }
        }

        [StructLayout(LayoutKind.Sequential)] struct Coord {
            public short X, Y;
            public Coord(short x, short y) { X = x; Y = y; }
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo {
            public int cb;
            public string reserved, desktop, title;
            public int x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
            public short showWindow, reservedBytes;
            public IntPtr reservedPointer, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {
            public StartupInfo info;
            public IntPtr attributes;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInformation {
            public IntPtr process, thread;
            public int processId, threadId;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr attributes, int size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateDirectory(string path, IntPtr attributes);
        [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, int flags, out IntPtr console);
        [DllImport("kernel32.dll")] static extern int ResizePseudoConsole(IntPtr console, Coord size);
        [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr console);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle, uint mode);
        [DllImport("kernel32.dll")] static extern uint GetConsoleCP();
        [DllImport("kernel32.dll")] static extern uint GetConsoleOutputCP();
        [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint codePage);
        [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint codePage);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);
        [DllImport("kernel32.dll")] static extern bool CancelSynchronousIo(IntPtr thread);

        static void Check(bool result) { if (!result) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        static FileStream PipeStream(ref IntPtr handle, FileAccess access) {
            FileStream stream = new FileStream(new SafeFileHandle(handle, true), access);
            handle = IntPtr.Zero;
            return stream;
        }
        static Coord Size() { return new Coord((short)Math.Max(1, Console.WindowWidth), (short)Math.Max(1, Console.WindowHeight)); }

        public static int RunTerminal(string executable, string[] arguments, string[] activityArguments) {
            if (Console.IsInputRedirected || Console.IsOutputRedirected)
                throw new IOException("Interactive SSH requires a Windows console. Use -Command for AI or redirected input.");
            IntPtr inputRead = IntPtr.Zero, inputWrite = IntPtr.Zero, outputRead = IntPtr.Zero, outputWrite = IntPtr.Zero;
            IntPtr console = IntPtr.Zero, attributes = IntPtr.Zero;
            ProcessInformation process = new ProcessInformation();
            FileStream toConsole = null, fromConsole = null;
            Thread outputThread = null;
            Activity activity = null;
            InputPump pump = null;
            bool attributesInitialized = false;
            IntPtr stdin = GetStdHandle(-10), stdout = GetStdHandle(-11);
            uint inputMode, outputMode;
            Check(GetConsoleMode(stdin, out inputMode));
            Check(GetConsoleMode(stdout, out outputMode));
            uint inputCodePage = GetConsoleCP(), outputCodePage = GetConsoleOutputCP();
            try {
                Check(SetConsoleMode(stdin, (inputMode & ~0x0047u) | 0x0280u)); // raw input, VT, no QuickEdit
                Check(SetConsoleMode(stdout, outputMode | 0x0004u));
                Check(SetConsoleCP(65001)); Check(SetConsoleOutputCP(65001));
                Check(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0));
                Check(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0));
                Coord size = Size();
                Marshal.ThrowExceptionForHR(CreatePseudoConsole(size, inputRead, outputWrite, 0, out console));
                IntPtr bytes = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
                attributes = Marshal.AllocHGlobal(bytes);
                Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes));
                attributesInitialized = true;
                Check(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));
                StartupInfoEx startup = new StartupInfoEx();
                startup.info.cb = Marshal.SizeOf(typeof(StartupInfoEx));
                startup.attributes = attributes;
                Check(CreateProcess(executable, new StringBuilder(Quote(executable) + " " + Arguments(arguments)),
                                    IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, null, ref startup, out process));
                CloseHandle(inputRead); inputRead = IntPtr.Zero;
                CloseHandle(outputWrite); outputWrite = IntPtr.Zero;
                toConsole = PipeStream(ref inputWrite, FileAccess.Write);
                fromConsole = PipeStream(ref outputRead, FileAccess.Read);
                Exception outputFailure = null;
                outputThread = Worker(delegate {
                    try { fromConsole.CopyTo(Console.OpenStandardOutput()); }
                    catch (Exception e) { Interlocked.CompareExchange(ref outputFailure, e, null); }
                });
                activity = new Activity(executable, activityArguments, false);
                pump = new InputPump(Console.OpenStandardInput(), toConsole, activity);
                while (WaitForSingleObject(process.process, 200) == 258) {
                    if (outputFailure != null) throw outputFailure;
                    Coord current = Size();
                    if (current.X != size.X || current.Y != size.Y) {
                        Marshal.ThrowExceptionForHR(ResizePseudoConsole(console, current)); size = current;
                    }
                }
                uint exitCode;
                Check(GetExitCodeProcess(process.process, out exitCode));
                return (int)exitCode;
            } finally {
                if (process.process != IntPtr.Zero && WaitForSingleObject(process.process, 0) == 258)
                    TerminateProcess(process.process, 130);
                if (pump != null) pump.Dispose();
                if (activity != null) activity.Dispose();
                // Keep the output drain alive through ClosePseudoConsole's final frame.
                if (console != IntPtr.Zero) ClosePseudoConsole(console);
                if (outputThread != null) outputThread.Join(5000);
                if (toConsole != null) toConsole.Dispose();
                if (fromConsole != null) fromConsole.Dispose();
                foreach (IntPtr handle in new [] { inputRead, inputWrite, outputRead, outputWrite, process.process, process.thread })
                    if (handle != IntPtr.Zero) CloseHandle(handle);
                if (attributesInitialized) DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                SetConsoleMode(stdin, inputMode); SetConsoleMode(stdout, outputMode);
                SetConsoleCP(inputCodePage); SetConsoleOutputCP(outputCodePage);
            }
        }
    }
}
