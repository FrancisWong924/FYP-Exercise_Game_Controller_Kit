#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Metadata.Profiles.Exif;

namespace BleServer;

/// <summary>
/// After an exercise GPX is saved, finds screenshots under Pictures/Screenshots whose file time
/// falls in the recording window, copies them next to the GPX, writes GPS + capture time into EXIF,
/// and adds GPX waypoints (lat/lon/time) so Strava can match photos to the track.
/// </summary>
internal static class GpxRecordingPhotoProcessor
{
    private static readonly Regex RecordingWindowRegex = new(
        @"<!--\s*fyp-recording-window\s+start=(?<start>\S+)\s+end=(?<end>\S+)\s*-->",
        RegexOptions.CultureInvariant);

    private static readonly string[] ScreenshotExtensions = [".png", ".jpg", ".jpeg", ".webp"];

    /// <returns>Number of photos geotagged and linked via GPX waypoints.</returns>
    public static int TryGeotagScreenshotsAndAugmentGpx(string gpxFullPath, string gpxXml)
    {
        XDocument doc;
        try
        {
            doc = XDocument.Parse(gpxXml, LoadOptions.PreserveWhitespace);
        }
        catch (XmlException)
        {
            return 0;
        }

        var root = doc.Root;
        if (root is null || root.Name.LocalName != "gpx")
            return 0;

        var ns = root.GetDefaultNamespace();
        if (string.IsNullOrEmpty(ns.NamespaceName))
            ns = XNamespace.None;

        var trackPoints = ReadTrackPoints(root, ns);
        if (trackPoints.Count == 0)
            return 0;

        DateTime startUtc;
        DateTime endUtc;
        if (TryParseRecordingWindow(gpxXml, out var ws, out var we))
        {
            startUtc = ws;
            endUtc = we;
        }
        else
        {
            startUtc = trackPoints[0].t;
            endUtc = trackPoints[^1].t;
        }

        if (endUtc < startUtc)
            return 0;

        var gpxDir = Path.GetDirectoryName(gpxFullPath);
        var baseName = Path.GetFileNameWithoutExtension(gpxFullPath);
        if (string.IsNullOrEmpty(gpxDir) || string.IsNullOrEmpty(baseName))
            return 0;

        var shotDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            "Screenshots");
        if (!Directory.Exists(shotDir))
            return 0;

        var inWindow = new List<(string path, DateTime capturedUtc)>();
        foreach (var ext in ScreenshotExtensions)
        {
            foreach (var path in Directory.GetFiles(shotDir, $"*{ext}", SearchOption.TopDirectoryOnly))
            {
                DateTime t;
                try
                {
                    t = File.GetLastWriteTimeUtc(path);
                }
                catch
                {
                    continue;
                }

                if (t < startUtc || t > endUtc)
                    continue;
                inWindow.Add((path, t));
            }
        }

        inWindow = inWindow
            .GroupBy(x => x.path, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.OrderByDescending(x => x.capturedUtc).First())
            .OrderBy(x => x.capturedUtc)
            .ToList();

        if (inWindow.Count == 0)
            return 0;

        var meta = root.Element(ns + "metadata");
        XNode? insertAfter = meta ?? root.Nodes().FirstOrDefault();
        var idx = 0;
        var attached = 0;

        foreach (var shot in inWindow)
        {
            if (!File.Exists(shot.path))
                continue;

            var (lat, lon) = InterpolateLatLon(trackPoints, shot.capturedUtc);
            var ext = Path.GetExtension(shot.path);
            if (string.IsNullOrEmpty(ext))
                ext = ".png";

            var destName = $"{baseName}_photo{idx + 1}{ext}";
            var destPath = Path.Combine(gpxDir, destName);
            try
            {
                File.Copy(shot.path, destPath, overwrite: true);
            }
            catch
            {
                continue;
            }

            if (!TryWriteGpsExif(destPath, lat, lon, shot.capturedUtc))
            {
                try
                {
                    File.Delete(destPath);
                }
                catch
                {
                    // ignore
                }

                continue;
            }

            var timeStr = shot.capturedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            var wpt = new XElement(
                ns + "wpt",
                new XAttribute("lat", lat.ToString(CultureInfo.InvariantCulture)),
                new XAttribute("lon", lon.ToString(CultureInfo.InvariantCulture)),
                new XElement(ns + "time", timeStr),
                new XElement(ns + "name", "Photo"),
                new XElement(ns + "desc", destName),
                new XElement(ns + "type", "image"));

            if (insertAfter is null)
                root.AddFirst(wpt);
            else
                insertAfter.AddAfterSelf(wpt);

            insertAfter = wpt;
            idx++;
            attached++;
        }

        if (attached == 0)
            return 0;

        var settings = new XmlWriterSettings
        {
            Indent = true,
            Encoding = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            OmitXmlDeclaration = false,
        };
        using (var writer = XmlWriter.Create(gpxFullPath, settings))
            doc.Save(writer);

        return attached;
    }

    private static bool TryParseRecordingWindow(string gpxXml, out DateTime startUtc, out DateTime endUtc)
    {
        startUtc = default;
        endUtc = default;
        var m = RecordingWindowRegex.Match(gpxXml);
        if (!m.Success)
            return false;
        if (!DateTime.TryParse(m.Groups["start"].Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out startUtc))
            return false;
        if (!DateTime.TryParse(m.Groups["end"].Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out endUtc))
            return false;
        startUtc = startUtc.ToUniversalTime();
        endUtc = endUtc.ToUniversalTime();
        return endUtc >= startUtc;
    }

    private static List<(DateTime t, double lat, double lon)> ReadTrackPoints(XElement root, XNamespace ns)
    {
        return root
            .Descendants(ns + "trkpt")
            .Select(e =>
            {
                var timeEl = e.Element(ns + "time");
                if (timeEl is null || string.IsNullOrWhiteSpace(timeEl.Value))
                    return ((DateTime?)null, 0.0, 0.0);
                if (!double.TryParse(e.Attribute("lat")?.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var la))
                    return (null, 0, 0);
                if (!double.TryParse(e.Attribute("lon")?.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var lo))
                    return (null, 0, 0);
                if (!DateTime.TryParse(timeEl.Value.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var t))
                    return (null, 0, 0);
                return ((DateTime?)t.ToUniversalTime(), la, lo);
            })
            .Where(x => x.Item1.HasValue)
            .Select(x => (t: x.Item1!.Value, lat: x.Item2, lon: x.Item3))
            .OrderBy(x => x.t)
            .ToList();
    }

    private static (double lat, double lon) InterpolateLatLon(
        IReadOnlyList<(DateTime t, double lat, double lon)> pts,
        DateTime targetUtc)
    {
        if (pts.Count == 1)
            return (pts[0].lat, pts[0].lon);

        if (targetUtc <= pts[0].t)
            return (pts[0].lat, pts[0].lon);
        if (targetUtc >= pts[^1].t)
            return (pts[^1].lat, pts[^1].lon);

        var lo = 0;
        var hi = pts.Count - 1;
        while (hi - lo > 1)
        {
            var mid = (lo + hi) / 2;
            if (pts[mid].t <= targetUtc)
                lo = mid;
            else
                hi = mid;
        }

        var a = pts[lo];
        var b = pts[hi];
        var denom = (b.t - a.t).TotalSeconds;
        if (denom <= 1e-9)
            return (a.lat, a.lon);

        var u = (targetUtc - a.t).TotalSeconds / denom;
        return (a.lat + u * (b.lat - a.lat), a.lon + u * (b.lon - a.lon));
    }

    /// <summary>Writes GPS latitude/longitude and capture time into an image file (JPEG/PNG/WebP).</summary>
    public static bool TryWriteGpsExif(string imagePath, double lat, double lon, DateTime capturedUtc)
    {
        try
        {
            using var image = Image.Load(imagePath);
            image.Metadata.ExifProfile ??= new ExifProfile();

            var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(capturedUtc, DateTimeKind.Utc), TimeZoneInfo.Local);
            var exifDate = local.ToString("yyyy:MM:dd HH:mm:ss", CultureInfo.InvariantCulture);

            var exif = image.Metadata.ExifProfile;
            exif.SetValue(ExifTag.DateTimeOriginal, exifDate);
            exif.SetValue(ExifTag.DateTimeDigitized, exifDate);

            exif.SetValue(ExifTag.GPSVersionID, new byte[] { 2, 3, 0, 0 });
            exif.SetValue(ExifTag.GPSLatitudeRef, lat >= 0 ? "N" : "S");
            exif.SetValue(ExifTag.GPSLongitudeRef, lon >= 0 ? "E" : "W");
            exif.SetValue(ExifTag.GPSLatitude, ToExifDegrees(Math.Abs(lat)));
            exif.SetValue(ExifTag.GPSLongitude, ToExifDegrees(Math.Abs(lon)));

            image.Save(imagePath);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static Rational[] ToExifDegrees(double absoluteDecimalDegrees)
    {
        var deg = (uint)Math.Floor(absoluteDecimalDegrees);
        var minFloat = (absoluteDecimalDegrees - deg) * 60.0;
        var min = (uint)Math.Floor(minFloat);
        var sec = (minFloat - min) * 60.0;
        const uint secDen = 1_000_000;
        var secNum = (uint)Math.Round(sec * secDen, MidpointRounding.AwayFromZero);
        return
        [
            new Rational(deg, 1),
            new Rational(min, 1),
            new Rational(secNum, secDen)
        ];
    }
}
