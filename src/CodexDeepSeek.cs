// CodexDeepSeek: launch the real Codex CLI against an isolated DeepSeek home.
//
// The launcher starts the real codex.exe with CODEX_HOME rewritten to
// %USERPROFILE%\.codex-deepseek (or CODEX_DEEPSEEK_HOME), so the DeepSeek
// provider config, the pinned model catalog, the credentials and the session
// store all live apart from %USERPROFILE%\.codex - which stays dedicated to
// ChatGPT Desktop and the plain `codex` command.
//
// Arguments are forwarded with the parent's standard handles, so pipes and
// interactive TUIs behave exactly as they would with codex itself. The child is
// placed in a kill-on-close Job Object so killing this wrapper cannot leave an
// orphaned Codex process behind on Windows.

// The POSIX counterpart of this file is src/codex-deepseek.sh. Keep the two in
// step: same environment variables, same resolution order, same exit codes.

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class CodexDeepSeek
{
    private const int STD_INPUT_HANDLE = -10;
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;

    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint INFINITE = 0xFFFFFFFF;

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    private const string TargetEnvVar = "CODEX_DEEPSEEK_TARGET";
    private const string HomeEnvVar = "CODEX_DEEPSEEK_HOME";
    private const string DeepSeekHomeDirName = ".codex-deepseek";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob,
        int jobObjectInformationClass,
        IntPtr lpJobObjectInformation,
        uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    private static int Main(string[] args)
    {
        string target = ResolveCodexPath();
        if (target == null)
        {
            Console.Error.WriteLine(
                "codex-deepseek: cannot find the real codex executable. " +
                "Set " + TargetEnvVar + " to its full path.");
            return 127;
        }

        return Forward(target, args);
    }

    private static string ResolveCodexPath()
    {
        string explicitTarget = Environment.GetEnvironmentVariable(TargetEnvVar);
        if (!string.IsNullOrEmpty(explicitTarget) && File.Exists(explicitTarget))
        {
            return explicitTarget;
        }

        string newestStandalone = FindNewestStandaloneCodex();
        if (newestStandalone != null)
        {
            return newestStandalone;
        }

        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string bundled = Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
        if (File.Exists(bundled))
        {
            return bundled;
        }

        return FindOnPath("codex.exe");
    }

    private static string FindNewestStandaloneCodex()
    {
        try
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string releases = Path.Combine(home, ".codex", "packages", "standalone", "releases");
            if (!Directory.Exists(releases))
            {
                return null;
            }

            string bestPath = null;
            int[] bestVersion = null;
            foreach (string dir in Directory.GetDirectories(releases))
            {
                string candidate = Path.Combine(dir, "bin", "codex.exe");
                if (!File.Exists(candidate))
                {
                    continue;
                }

                int[] version = ParseVersion(Path.GetFileName(dir));
                if (bestPath == null || CompareVersions(version, bestVersion) > 0)
                {
                    bestPath = candidate;
                    bestVersion = version;
                }
            }
            return bestPath;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static int[] ParseVersion(string directoryName)
    {
        List<int> numbers = new List<int>();
        StringBuilder current = new StringBuilder();
        foreach (char c in directoryName)
        {
            if (char.IsDigit(c))
            {
                current.Append(c);
            }
            else
            {
                if (current.Length > 0)
                {
                    numbers.Add(SafeParse(current.ToString()));
                    current.Length = 0;
                }
                if (numbers.Count >= 3)
                {
                    break;
                }
            }
        }
        if (current.Length > 0 && numbers.Count < 3)
        {
            numbers.Add(SafeParse(current.ToString()));
        }
        while (numbers.Count < 3)
        {
            numbers.Add(0);
        }
        return numbers.ToArray();
    }

    private static int SafeParse(string value)
    {
        int parsed;
        return int.TryParse(value, out parsed) ? parsed : 0;
    }

    private static int CompareVersions(int[] left, int[] right)
    {
        for (int i = 0; i < 3; i++)
        {
            int a = left != null && i < left.Length ? left[i] : 0;
            int b = right != null && i < right.Length ? right[i] : 0;
            if (a != b)
            {
                return a < b ? -1 : 1;
            }
        }
        return 0;
    }

    private static string FindOnPath(string executable)
    {
        string path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path))
        {
            return null;
        }
        string[] parts = path.Split(';');
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0)
            {
                continue;
            }
            try
            {
                string candidate = Path.Combine(parts[i].Trim('"'), executable);
                if (File.Exists(candidate) &&
                    !string.Equals(candidate, Environment.GetCommandLineArgs()[0], StringComparison.OrdinalIgnoreCase))
                {
                    return candidate;
                }
            }
            catch (Exception)
            {
                // Malformed PATH entry; skip it.
            }
        }
        return null;
    }

    private static int Forward(string target, string[] args)
    {
        STARTUPINFO startupInfo = new STARTUPINFO();
        startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        startupInfo.dwFlags = unchecked((int)STARTF_USESTDHANDLES);
        startupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startupInfo.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);

        string deepSeekHome = ResolveDeepSeekHome();
        string deepSeekConfig = Path.Combine(deepSeekHome, "config.toml");
        if (!File.Exists(deepSeekConfig))
        {
            Console.Error.WriteLine(
                "codex-deepseek: missing DeepSeek config at " + deepSeekConfig);
            return 127;
        }

        PROCESS_INFORMATION processInfo;
        StringBuilder commandLine = new StringBuilder(BuildCommandLine(target, args));
        IntPtr environmentBlock = BuildChildEnvironment(deepSeekHome);
        bool started;
        try
        {
            started = CreateProcess(
                null,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                CREATE_UNICODE_ENVIRONMENT,
                environmentBlock,
                null,
                ref startupInfo,
                out processInfo);
        }
        finally
        {
            Marshal.FreeHGlobal(environmentBlock);
        }

        if (!started)
        {
            int error = Marshal.GetLastWin32Error();
            Console.Error.WriteLine(
                "codex-deepseek: failed to launch " + target + " (Win32 error " + error + ")");
            return 127;
        }

        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job != IntPtr.Zero)
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, buffer, false);
                SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            AssignProcessToJobObject(job, processInfo.hProcess);
        }

        try
        {
            WaitForSingleObject(processInfo.hProcess, INFINITE);

            uint exitCode;
            if (!GetExitCodeProcess(processInfo.hProcess, out exitCode))
            {
                return 1;
            }
            return unchecked((int)exitCode);
        }
        finally
        {
            CloseHandle(processInfo.hThread);
            CloseHandle(processInfo.hProcess);
            if (job != IntPtr.Zero)
            {
                CloseHandle(job);
            }
        }
    }

    private static string ResolveDeepSeekHome()
    {
        string explicitHome = Environment.GetEnvironmentVariable(HomeEnvVar);
        if (!string.IsNullOrEmpty(explicitHome))
        {
            return explicitHome;
        }

        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, DeepSeekHomeDirName);
    }

    private static IntPtr BuildChildEnvironment(string codexHome)
    {
        SortedDictionary<string, string> environment =
            new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            string key = entry.Key as string;
            if (string.IsNullOrEmpty(key) || key.IndexOf('=') >= 0)
            {
                continue;
            }
            environment[key] = entry.Value == null ? string.Empty : entry.Value.ToString();
        }
        environment["CODEX_HOME"] = codexHome;

        StringBuilder block = new StringBuilder();
        foreach (KeyValuePair<string, string> pair in environment)
        {
            block.Append(pair.Key);
            block.Append('=');
            block.Append(pair.Value);
            block.Append('\0');
        }
        block.Append('\0');
        return Marshal.StringToHGlobalUni(block.ToString());
    }
    private static string BuildCommandLine(string target, string[] args)
    {
        StringBuilder builder = new StringBuilder();
        builder.Append(QuoteArgument(target));
        for (int i = 0; i < args.Length; i++)
        {
            builder.Append(' ');
            builder.Append(QuoteArgument(args[i]));
        }
        return builder.ToString();
    }

    // Standard Windows command-line quoting (the algorithm the C runtime's
    // argv parser reverses).
    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 &&
            value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');
        int backslashes = 0;

        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            if (c == '"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                backslashes = 0;
                builder.Append('"');
                continue;
            }
            if (backslashes > 0)
            {
                builder.Append('\\', backslashes);
                backslashes = 0;
            }
            builder.Append(c);
        }

        if (backslashes > 0)
        {
            builder.Append('\\', backslashes * 2);
        }
        builder.Append('"');
        return builder.ToString();
    }
}
