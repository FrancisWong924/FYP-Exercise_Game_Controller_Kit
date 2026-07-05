using System.Reflection;

namespace BleServer;

static class AppVersion
{
    public static string Current { get; } =
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";
}
