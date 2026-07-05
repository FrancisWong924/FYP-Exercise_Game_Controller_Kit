#nullable enable

using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace BleServer;

/// <summary>
/// Copies or captures a screenshot, writes GPS EXIF, and saves to a game-provided export path.
/// </summary>
internal static class GeotaggedImageExporter
{
    private static readonly string[] ScreenshotExtensions = [".png", ".jpg", ".jpeg", ".webp"];

    public static async Task<(bool Success, string? Error, string? OutputPath)> ExportAsync(
        string? sourceImagePath,
        double latitude,
        double longitude,
        string exportPath)
    {
        if (string.IsNullOrWhiteSpace(exportPath))
            return (false, "Export path is required.", null);

        if (latitude is < -90 or > 90)
            return (false, "Latitude must be between -90 and 90.", null);
        if (longitude is < -180 or > 180)
            return (false, "Longitude must be between -180 and 180.", null);

        try
        {
            var fullExport = Path.GetFullPath(exportPath.Trim());
            var exportDir = Path.GetDirectoryName(fullExport);
            if (!string.IsNullOrEmpty(exportDir))
                Directory.CreateDirectory(exportDir);

            string workingSource;
            if (!string.IsNullOrWhiteSpace(sourceImagePath))
            {
                workingSource = Path.GetFullPath(sourceImagePath.Trim());
                if (!File.Exists(workingSource))
                    return (false, $"Source image not found: {workingSource}", null);
            }
            else
            {
                var captured = await CaptureLatestScreenshotAsync().ConfigureAwait(false);
                if (captured == null)
                    return (false, "Screenshot capture failed (no new image in Pictures/Screenshots).", null);
                workingSource = captured;
            }

            if (string.IsNullOrEmpty(Path.GetExtension(fullExport)))
            {
                var ext = Path.GetExtension(workingSource);
                if (string.IsNullOrEmpty(ext))
                    ext = ".png";
                fullExport += ext;
            }

            File.Copy(workingSource, fullExport, overwrite: true);

            DateTime capturedUtc;
            try
            {
                capturedUtc = File.GetLastWriteTimeUtc(workingSource);
            }
            catch
            {
                capturedUtc = DateTime.UtcNow;
            }

            if (!GpxRecordingPhotoProcessor.TryWriteGpsExif(fullExport, latitude, longitude, capturedUtc))
                return (false, "Failed to write GPS EXIF metadata to the exported image.", null);

            Console.WriteLine($"[GEOTAG] Saved {fullExport} ({latitude}, {longitude})");
            return (true, null, fullExport);
        }
        catch (Exception ex)
        {
            return (false, ex.Message, null);
        }
    }

    /// <summary>Triggers Win+PrintScreen and returns the newest PNG in Pictures/Screenshots.</summary>
    public static async Task<string?> CaptureLatestScreenshotAsync()
    {
        var t0 = DateTime.UtcNow;
        await Task.Delay(30).ConfigureAwait(false);
        NativeInput.TriggerWinPrintScreen();
        await Task.Delay(2500).ConfigureAwait(false);

        var shotDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            "Screenshots");
        if (!Directory.Exists(shotDir))
            return null;

        var candidates = ScreenshotExtensions
            .SelectMany(ext => Directory.GetFiles(shotDir, $"*{ext}", SearchOption.TopDirectoryOnly))
            .Select(path =>
            {
                try
                {
                    return (path, t: File.GetLastWriteTimeUtc(path));
                }
                catch
                {
                    return (path: (string?)null, t: DateTime.MinValue);
                }
            })
            .Where(x => x.path != null && x.t >= t0.AddSeconds(-8))
            .OrderByDescending(x => x.t)
            .Select(x => x.path!)
            .FirstOrDefault();

        return candidates;
    }
}
