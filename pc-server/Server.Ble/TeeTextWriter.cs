#nullable enable

using System.IO;
using System.Text;

namespace BleServer;

/// <summary>Forwards writes to an inner writer and raises a callback once per completed line (for UI logs).</summary>
internal sealed class TeeTextWriter : TextWriter
{
    private readonly TextWriter _inner;
    private readonly Action<string> _onLine;
    private readonly StringBuilder _buffer = new();
    private readonly object _lock = new();

    public TeeTextWriter(TextWriter inner, Action<string> onLine)
    {
        _inner = inner;
        _onLine = onLine;
    }

    public override Encoding Encoding => _inner.Encoding;

    public override void Write(char value)
    {
        _inner.Write(value);
        lock (_lock)
        {
            if (value == '\n')
            {
                var line = _buffer.ToString();
                _buffer.Clear();
                _onLine(line);
            }
            else if (value != '\r')
            {
                _buffer.Append(value);
            }
        }
    }

    public override void Write(string? value)
    {
        if (string.IsNullOrEmpty(value)) return;
        foreach (var c in value)
            Write(c);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            lock (_lock)
            {
                if (_buffer.Length > 0)
                {
                    _onLine(_buffer.ToString());
                    _buffer.Clear();
                }
            }
        }
        base.Dispose(disposing);
    }
}
