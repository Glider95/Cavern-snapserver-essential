using System.Net;
using System.Net.Sockets;
using System.IO.Pipes;

namespace CavernSnapcastStreaming;

/// <summary>
/// Bridges audio from CavernPipe (via NamedPipe) to Snapserver via TCP.
/// Implements the Snapcast streaming protocol.
/// </summary>
public class SnapcastBridge : IDisposable
{
    private TcpClient? _snapClient;
    private NetworkStream? _snapStream;
    private NamedPipeClientStream? _cavernPipe;
    private readonly CancellationTokenSource _cts = new();
    
    // Configuration
    public string SnapserverHost { get; set; } = "localhost";
    public int SnapserverPort { get; set; } = 1704;
    public string PipeName { get; set; } = "CavernPipe";
    public int SampleRate { get; set; } = 48000;
    public int Channels { get; set; } = 6;
    public int BitDepth { get; set; } = 16;

    // Chunk timing
    private readonly int _chunkMs = 20;
    private int ChunkSamples => SampleRate * _chunkMs / 1000;
    private int ChunkBytes => ChunkSamples * Channels * (BitDepth / 8);

    public bool IsConnected => _snapClient?.Connected == true;

    /// <summary>
    /// Start the bridge: connect to Snapserver and begin streaming.
    /// </summary>
    public async Task StartAsync()
    {
        // Connect to Snapserver
        await ConnectToSnapserverAsync();
        
        // Start the streaming loop
        await StreamToSnapserverAsync();
    }

    /// <summary>
    /// Connect to Snapserver and send initial header.
    /// </summary>
    private async Task ConnectToSnapserverAsync()
    {
        Console.Error.WriteLine($"[SnapcastBridge] Connecting to Snapserver at {SnapserverHost}:{SnapserverPort}...");
        
        _snapClient = new TcpClient();
        await _snapClient.ConnectAsync(SnapserverHost, SnapserverPort);
        _snapStream = _snapClient.GetStream();

        Console.Error.WriteLine("[SnapcastBridge] Connected to Snapserver");

        // Send Snapcast base header (44 bytes)
        await SendSnapcastHeaderAsync();
    }

    /// <summary>
    /// Send Snapcast wire protocol header.
    /// </summary>
    private async Task SendSnapcastHeaderAsync()
    {
        // Snapcast wire protocol base message header
        // See: https://github.com/badaix/snapcast/blob/master/doc/binary_protocol.md
        
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        // Base message header (26 bytes for codec header)
        uint messageSize = 26 + 12; // base header + codec header
        
        writer.Write((ushort)0);           // type: 0 = codec header
        writer.Write(messageSize);         // size of following data
        writer.Write((uint)0);             // received secs (unused for header)
        writer.Write((uint)0);             // received usecs
        writer.Write((uint)0);             // remote timestamp
        
        // Codec header (12 bytes)
        string codec = "pcm";  // or "flac" for compressed
        byte[] codecBytes = System.Text.Encoding.UTF8.GetBytes(codec);
        
        writer.Write((uint)codecBytes.Length);
        writer.Write(codecBytes);
        
        // PCM payload header (8 bytes)
        writer.Write((uint)SampleRate);
        writer.Write((ushort)BitsPerSample);
        writer.Write((ushort)Channels);

        byte[] header = ms.ToArray();
        await _snapStream!.WriteAsync(header, 0, header.Length);
        await _snapStream.FlushAsync();

        Console.Error.WriteLine($"[SnapcastBridge] Sent header: {codec}, {SampleRate}Hz, {Channels}ch, {BitDepth}-bit");
    }

    private int BitsPerSample => BitDepth switch
    {
        16 => 16,
        24 => 24,
        32 => 32,
        _ => 16
    };

    /// <summary>
    /// Main streaming loop: receive from CavernPipe, send to Snapserver.
    /// </summary>
    private async Task StreamToSnapserverAsync()
    {
        Console.Error.WriteLine("[SnapcastBridge] Starting streaming loop...");
        Console.Error.WriteLine($"[SnapcastBridge] Chunk size: {ChunkBytes} bytes ({_chunkMs}ms @ {SampleRate}Hz)");

        // Connect to CavernPipe (the client connects to our pipe)
        // In this architecture, we wait for CavernPipeClient to connect
        await ConnectToCavernPipeAsync();

        byte[] audioBuffer = new byte[ChunkBytes];
        long totalBytes = 0;
        int chunkCount = 0;

        try
        {
            while (!_cts.Token.IsCancellationRequested && _snapClient!.Connected)
            {
                // Read from CavernPipe
                int bytesRead = await ReadFromCavernPipeAsync(audioBuffer);
                
                if (bytesRead <= 0)
                {
                    // End of stream
                    Console.Error.WriteLine("[SnapcastBridge] End of audio stream");
                    break;
                }

                // Send to Snapserver
                await SendAudioChunkAsync(audioBuffer, bytesRead);
                
                totalBytes += bytesRead;
                chunkCount++;

                if (chunkCount % 100 == 0)
                {
                    Console.Error.WriteLine($"[SnapcastBridge] Streamed {chunkCount} chunks ({totalBytes / 1024} KB)");
                }

                // Rate limiting to match real-time
                await Task.Delay(_chunkMs, _cts.Token);
            }
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("[SnapcastBridge] Streaming cancelled");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[SnapcastBridge] Streaming error: {ex.Message}");
        }

        Console.Error.WriteLine($"[SnapcastBridge] Total streamed: {chunkCount} chunks, {totalBytes} bytes");
    }

    /// <summary>
    /// Connect to CavernPipe as a client (to receive audio from Cavern).
    /// </summary>
    private async Task ConnectToCavernPipeAsync()
    {
        Console.Error.WriteLine($"[SnapcastBridge] Connecting to CavernPipe: {PipeName}");
        
        // Try to connect to existing CavernPipeServer
        int attempts = 0;
        while (attempts < 30 && !_cts.Token.IsCancellationRequested)
        {
            try
            {
                _cavernPipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                await _cavernPipe.ConnectAsync(1000);
                
                Console.Error.WriteLine("[SnapcastBridge] Connected to CavernPipe");
                
                // Send handshake
                await SendCavernHandshakeAsync();
                return;
            }
            catch (TimeoutException)
            {
                attempts++;
                Console.Error.WriteLine($"[SnapcastBridge] Waiting for CavernPipe... ({attempts}/30)");
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"[SnapcastBridge] Pipe error: {ex.Message}");
                await Task.Delay(500, _cts.Token);
                attempts++;
            }
        }

        throw new TimeoutException("Could not connect to CavernPipe after 30 attempts");
    }

    /// <summary>
    /// Send CavernPipe handshake.
    /// </summary>
    private async Task SendCavernHandshakeAsync()
    {
        byte[] handshake = new byte[8];
        handshake[0] = (byte)BitDepth;
        handshake[1] = 6; // mandatory frames
        BitConverter.GetBytes((ushort)Channels).CopyTo(handshake, 2);
        BitConverter.GetBytes(UpdateRate).CopyTo(handshake, 4);

        await _cavernPipe!.WriteAsync(handshake, 0, 8);
        await _cavernPipe.FlushAsync();

        Console.Error.WriteLine($"[SnapcastBridge] Sent handshake: {BitDepth}-bit, {Channels}ch, rate={UpdateRate}");
    }

    private int UpdateRate => 1024;

    /// <summary>
    /// Read audio data from CavernPipe.
    /// </summary>
    private async Task<int> ReadFromCavernPipeAsync(byte[] buffer)
    {
        if (_cavernPipe == null || !_cavernPipe.IsConnected)
            return 0;

        try
        {
            // Read length prefix
            byte[] lengthBytes = new byte[4];
            int read = await ReadExactlyAsync(_cavernPipe, lengthBytes, 4);
            if (read < 4) return 0;

            int pcmLength = BitConverter.ToInt32(lengthBytes, 0);
            if (pcmLength < 0 || pcmLength > buffer.Length)
            {
                Console.Error.WriteLine($"[SnapcastBridge] Invalid PCM length: {pcmLength}");
                return 0;
            }

            if (pcmLength == 0) return 0; // EOF marker

            // Read PCM data
            read = await ReadExactlyAsync(_cavernPipe, buffer, pcmLength);
            return read;
        }
        catch (IOException)
        {
            return 0; // Pipe closed
        }
    }

    /// <summary>
    /// Send audio chunk to Snapserver.
    /// </summary>
    private async Task SendAudioChunkAsync(byte[] data, int length)
    {
        if (_snapStream == null) return;

        // Snapcast wire message format
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        // Calculate timestamp
        long timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        uint secs = (uint)(timestamp / 1000);
        uint usecs = (uint)((timestamp % 1000) * 1000);

        // Wire chunk header (16 bytes)
        writer.Write((ushort)1);           // type: 1 = wire chunk
        writer.Write((uint)length);        // size
        writer.Write(secs);                // timestamp seconds
        writer.Write(usecs);               // timestamp microseconds

        byte[] header = ms.ToArray();
        await _snapStream.WriteAsync(header, 0, header.Length);
        await _snapStream.WriteAsync(data, 0, length);
        await _snapStream.FlushAsync();
    }

    private async Task<int> ReadExactlyAsync(Stream stream, byte[] buffer, int count)
    {
        int totalRead = 0;
        while (totalRead < count)
        {
            int read = await stream.ReadAsync(buffer, totalRead, count - totalRead, _cts.Token);
            if (read <= 0) break;
            totalRead += read;
        }
        return totalRead;
    }

    public void Stop()
    {
        _cts.Cancel();
        _snapStream?.Close();
        _cavernPipe?.Close();
    }

    public void Dispose()
    {
        Stop();
        _cts.Dispose();
        _snapStream?.Dispose();
        _snapClient?.Dispose();
        _cavernPipe?.Dispose();
    }
}
