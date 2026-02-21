namespace CavernSnapcastStreaming;

/// <summary>
/// Helper class to write audio data to a WAV file.
/// Can be used as an alternative to streaming to snapserver.
/// </summary>
public class WavWriter : IDisposable
{
    private FileStream? _fileStream;
    private BinaryWriter? _writer;
    private long _dataChunkSizePosition;
    private long _dataSize;
    private bool _headerWritten;

    public int SampleRate { get; set; } = 48000;
    public int Channels { get; set; } = 6;
    public int BitDepth { get; set; } = 16;

    /// <summary>
    /// Open a WAV file for writing.
    /// </summary>
    public void Open(string filePath)
    {
        _fileStream = File.OpenWrite(filePath);
        _writer = new BinaryWriter(_fileStream);
        _dataSize = 0;
        _headerWritten = false;

        // Write placeholder header (will be updated on close)
        WriteHeader();
    }

    /// <summary>
    /// Write audio samples to the WAV file.
    /// </summary>
    public void WriteSamples(byte[] data, int offset, int count)
    {
        if (_writer == null) throw new InvalidOperationException("WAV file not open");
        
        _writer.Write(data, offset, count);
        _dataSize += count;
    }

    /// <summary>
    /// Write audio samples to the WAV file.
    /// </summary>
    public void WriteSamples(byte[] data)
    {
        WriteSamples(data, 0, data.Length);
    }

    private void WriteHeader()
    {
        if (_writer == null) return;

        // RIFF chunk descriptor
        _writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        _writer.Write((uint)0); // Placeholder for file size
        _writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));

        // fmt sub-chunk
        _writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
        _writer.Write((uint)16); // Subchunk1Size (16 for PCM)
        _writer.Write((ushort)1); // AudioFormat (1 = PCM)
        _writer.Write((ushort)Channels);
        _writer.Write((uint)SampleRate);
        _writer.Write((uint)(SampleRate * Channels * BitDepth / 8)); // ByteRate
        _writer.Write((ushort)(Channels * BitDepth / 8)); // BlockAlign
        _writer.Write((ushort)BitDepth);

        // data sub-chunk
        _writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        _dataChunkSizePosition = _fileStream!.Position;
        _writer.Write((uint)0); // Placeholder for data size

        _headerWritten = true;
    }

    private void UpdateHeader()
    {
        if (_writer == null || !_headerWritten) return;

        // Update RIFF chunk size
        _fileStream!.Position = 4;
        _writer.Write((uint)(_dataSize + 36)); // File size - 8

        // Update data chunk size
        _fileStream.Position = _dataChunkSizePosition;
        _writer.Write((uint)_dataSize);
    }

    public void Close()
    {
        UpdateHeader();
        _writer?.Close();
        _fileStream?.Close();
    }

    public void Dispose()
    {
        Close();
        _writer?.Dispose();
        _fileStream?.Dispose();
    }
}
