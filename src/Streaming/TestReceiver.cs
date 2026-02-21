using System.Net;
using System.Net.Sockets;

namespace CavernSnapcastStreaming;

/// <summary>
/// Simple test receiver that mimics Snapserver for testing purposes.
/// Receives TCP audio streams and can either play them or save to file.
/// </summary>
public class TestReceiver : IDisposable
{
    private TcpListener? _listener;
    private readonly CancellationTokenSource _cts = new();
    private Task? _listenTask;

    public int Port { get; set; } = 1704;
    public string? OutputFile { get; set; }
    public bool PlayAudio { get; set; } = false;
    public bool Verbose { get; set; } = true;

    private FileStream? _outputStream;
    private long _totalBytesReceived;
    private int _chunkCount;

    public async Task StartAsync()
    {
        _listener = new TcpListener(IPAddress.Any, Port);
        _listener.Start();
        
        Console.WriteLine($"[TestReceiver] Listening on port {Port}");
        Console.WriteLine($"[TestReceiver] Output: {(OutputFile != null ? OutputFile : "Playback mode")}");
        
        if (OutputFile != null)
        {
            _outputStream = File.OpenWrite(OutputFile);
            Console.WriteLine($"[TestReceiver] Writing to: {OutputFile}");
        }

        _listenTask = Task.Run(async () =>
        {
            while (!_cts.Token.IsCancellationRequested)
            {
                try
                {
                    var client = await _listener.AcceptTcpClientAsync();
                    _ = HandleClientAsync(client);
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[TestReceiver] Accept error: {ex.Message}");
                }
            }
        });

        await Task.CompletedTask;
    }

    private async Task HandleClientAsync(TcpClient client)
    {
        var endpoint = client.Client.RemoteEndPoint?.ToString() ?? "unknown";
        Console.WriteLine($"[TestReceiver] Client connected: {endpoint}");

        using var stream = client.GetStream();
        
        try
        {
            // Read Snapcast header first
            await ReadSnapcastHeaderAsync(stream);
            
            // Read audio chunks
            await ReadAudioChunksAsync(stream);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[TestReceiver] Client error: {ex.Message}");
        }

        Console.WriteLine($"[TestReceiver] Client disconnected: {endpoint}");
        Console.WriteLine($"[TestReceiver] Total received: {_totalBytesReceived} bytes in {_chunkCount} chunks");
    }

    private async Task ReadSnapcastHeaderAsync(NetworkStream stream)
    {
        // Snapcast wire header: type(2) + size(4) + timestamp(8) + data
        byte[] header = new byte[26];
        await ReadExactlyAsync(stream, header, 26);

        ushort msgType = BitConverter.ToUInt16(header, 0);
        uint msgSize = BitConverter.ToUInt32(header, 2);

        if (Verbose)
        {
            Console.WriteLine($"[TestReceiver] Header: type={msgType}, size={msgSize}");
        }

        if (msgType == 0) // Codec header
        {
            // Read codec name length and codec name
            byte[] codecLenBytes = new byte[4];
            await ReadExactlyAsync(stream, codecLenBytes, 4);
            uint codecLen = BitConverter.ToUInt32(codecLenBytes, 0);

            byte[] codecBytes = new byte[codecLen];
            await ReadExactlyAsync(stream, codecBytes, (int)codecLen);
            string codec = System.Text.Encoding.UTF8.GetString(codecBytes);

            // Read PCM header (12 bytes)
            byte[] pcmHeader = new byte[12];
            await ReadExactlyAsync(stream, pcmHeader, 12);

            uint sampleRate = BitConverter.ToUInt32(pcmHeader, 0);
            ushort bitsPerSample = BitConverter.ToUInt16(pcmHeader, 4);
            ushort channels = BitConverter.ToUInt16(pcmHeader, 6);

            Console.WriteLine($"[TestReceiver] Stream info: {codec}, {sampleRate}Hz, {channels}ch, {bitsPerSample}-bit");
        }
    }

    private async Task ReadAudioChunksAsync(NetworkStream stream)
    {
        byte[] headerBuffer = new byte[16]; // type(2) + size(4) + timestamp(8) + reserved(2)

        while (!_cts.Token.IsCancellationRequested)
        {
            try
            {
                // Read chunk header
                int read = await ReadExactlyAsync(stream, headerBuffer, 16);
                if (read < 16) break;

                ushort chunkType = BitConverter.ToUInt16(headerBuffer, 0);
                uint chunkSize = BitConverter.ToUInt32(headerBuffer, 2);
                uint timestampSecs = BitConverter.ToUInt32(headerBuffer, 6);
                uint timestampUSecs = BitConverter.ToUInt32(headerBuffer, 10);

                if (chunkType != 1) // Not a wire chunk
                {
                    Console.WriteLine($"[TestReceiver] Unknown chunk type: {chunkType}");
                    // Skip this message
                    byte[] skipBuffer = new byte[chunkSize];
                    await ReadExactlyAsync(stream, skipBuffer, (int)chunkSize);
                    continue;
                }

                // Read audio data
                byte[] audioData = new byte[chunkSize];
                read = await ReadExactlyAsync(stream, audioData, (int)chunkSize);
                if (read < chunkSize) break;

                _totalBytesReceived += chunkSize;
                _chunkCount++;

                if (Verbose && _chunkCount % 100 == 0)
                {
                    Console.WriteLine($"[TestReceiver] Chunk {_chunkCount}: {chunkSize} bytes (total: {_totalBytesReceived})");
                }

                // Write to output file if configured
                if (_outputStream != null)
                {
                    await _outputStream.WriteAsync(audioData, 0, (int)chunkSize);
                }

                // Play audio if configured (would need NAudio or similar)
                if (PlayAudio)
                {
                    // Audio playback would go here
                    // Requires NAudio or similar library
                }
            }
            catch (IOException)
            {
                break; // Client disconnected
            }
        }
    }

    private async Task<int> ReadExactlyAsync(Stream stream, byte[] buffer, int count)
    {
        int totalRead = 0;
        while (totalRead < count)
        {
            int read = await stream.ReadAsync(buffer, totalRead, count - totalRead);
            if (read <= 0) break;
            totalRead += read;
        }
        return totalRead;
    }

    public void Stop()
    {
        _cts.Cancel();
        _listener?.Stop();
        _outputStream?.Close();
    }

    public void Dispose()
    {
        Stop();
        _cts.Dispose();
        _outputStream?.Dispose();
        _listener?.Dispose();
    }
}
