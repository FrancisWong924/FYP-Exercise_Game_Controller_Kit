#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using Microsoft.Win32;

namespace BleServer;

/// <summary>
/// After GPX + geotagged photos are prepared, prompts for an export folder and copies the bundle there.
/// </summary>
internal static class GpxExportDestinationPicker
{
    public static string? TryPickFolder()
    {
        var app = Application.Current;
        if (app == null)
            return null;

        return app.Dispatcher.Invoke(() =>
        {
            var dlg = new OpenFolderDialog
            {
                Title = "Choose folder to export exercise GPX and photos",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            };

            var owner = app.MainWindow;
            if (owner != null && dlg.ShowDialog(owner) == true)
                return dlg.FolderName;

            if (dlg.ShowDialog() == true)
                return dlg.FolderName;

            return null;
        });
    }

    public static string CopyBundle(string gpxPath, string destFolder)
    {
        var destDir = Path.GetFullPath(destFolder.Trim());
        Directory.CreateDirectory(destDir);

        var files = CollectBundleFiles(gpxPath);
        string? finalGpxPath = null;

        foreach (var src in files)
        {
            var dest = Path.Combine(destDir, Path.GetFileName(src));
            File.Copy(src, dest, overwrite: true);
            if (string.Equals(src, gpxPath, StringComparison.OrdinalIgnoreCase))
                finalGpxPath = dest;
        }

        return finalGpxPath ?? Path.Combine(destDir, Path.GetFileName(gpxPath));
    }

    static List<string> CollectBundleFiles(string gpxPath)
    {
        var dir = Path.GetDirectoryName(gpxPath);
        var baseName = Path.GetFileNameWithoutExtension(gpxPath);
        if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(baseName))
            return [gpxPath];

        var files = new List<string> { gpxPath };
        files.AddRange(
            Directory.GetFiles(dir, $"{baseName}_photo*")
                .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase));
        return files;
    }
}
