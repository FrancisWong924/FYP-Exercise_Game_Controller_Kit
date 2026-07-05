#nullable enable

using System.IO;
using System.Text.Json;

namespace BleServer;

static class LayoutCreatorUserSettings
{
    static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ExerSyncKitServer");
    static readonly string SettingsPath = Path.Combine(SettingsDirectory, "layout-creator.json");

    sealed class SettingsData
    {
        public bool TutorialAutoShown { get; set; }
        public string? TutorialShownForVersion { get; set; }
    }

    /// <summary>Returns true once per app version; persists immediately so later opens on the same version skip auto-start.</summary>
    public static bool TryConsumeFirstRunTutorial()
    {
        var currentVersion = AppVersion.Current;
        var data = Load();
        var shownVersion = data.TutorialShownForVersion;

        // Migrate the old once-ever flag to version 1.0.0.
        if (string.IsNullOrEmpty(shownVersion) && data.TutorialAutoShown)
            shownVersion = "1.0.0";

        if (shownVersion == currentVersion)
            return false;

        data.TutorialShownForVersion = currentVersion;
        data.TutorialAutoShown = false;
        Save(data);
        return true;
    }

    static SettingsData Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
                return new SettingsData();

            var json = File.ReadAllText(SettingsPath);
            return JsonSerializer.Deserialize<SettingsData>(json) ?? new SettingsData();
        }
        catch
        {
            return new SettingsData();
        }
    }

    static void Save(SettingsData data)
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            var json = JsonSerializer.Serialize(data);
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // ignore persistence failures; tutorial may auto-run again next time
        }
    }
}
