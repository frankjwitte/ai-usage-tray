// Tiny host for AiUsageTray.ps1. Running the script inside this .exe (instead of
// powershell.exe) gives the tray icon its own identity, so Windows lists it as
// "AI Usage Tray" and remembers its "always show" setting independently.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("AI Usage Tray")]
[assembly: AssemblyProduct("AI Usage Tray")]
[assembly: AssemblyDescription("Weekly Claude and Codex usage in the system tray")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "AiUsageTray.ps1");
        string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AiUsageTray");
        Environment.SetEnvironmentVariable("AIUSAGETRAY_EXE", Application.ExecutablePath);
        try
        {
            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    ps.Invoke();
                    if (ps.Streams.Error.Count > 0)
                    {
                        Directory.CreateDirectory(logDir);
                        foreach (var e in ps.Streams.Error)
                            File.AppendAllText(Path.Combine(logDir, "host.log"), DateTime.Now + "  " + e + Environment.NewLine);
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Directory.CreateDirectory(logDir);
            File.AppendAllText(Path.Combine(logDir, "host.log"), DateTime.Now + "  " + ex + Environment.NewLine);
            MessageBox.Show("AI Usage Tray stopped:\n\n" + ex.Message, "AI Usage Tray", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
