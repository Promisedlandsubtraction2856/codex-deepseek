// A stand-in for codex.exe, used by tests/windows-launcher-test.ps1.
//
// It records the environment the launcher handed it and the argument vector it
// received, then exits with $STUB_EXIT_CODE (0 when unset).

using System;

internal static class WindowsStub
{
    private static int Main(string[] args)
    {
        Console.WriteLine("CODEX_HOME=" + (Environment.GetEnvironmentVariable("CODEX_HOME") ?? string.Empty));
        Console.WriteLine("ARGS=" + string.Join(" ", args));

        int exitCode;
        string raw = Environment.GetEnvironmentVariable("STUB_EXIT_CODE");
        return int.TryParse(raw, out exitCode) ? exitCode : 0;
    }
}
