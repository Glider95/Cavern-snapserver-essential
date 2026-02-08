using System.IO.Pipes;
using System.Net.Sockets;

namespace CavernPipeClient;

/// <summary>
/// CavernPipe client that can operate in two modes:
/// 1. File-based mode: Sends a file path to CavernPipeServer for direct file opening
/// 2. Streaming mode: Reads audio from stdin and sends it to CavernPipeServer
/// 
/// CavernPipe Protocol:
/// - Handshake: 8 bytes [BitDepth(1), MandatoryFrames(1), Channels(2), UpdateRate(4)]
/// - UpdateRate=1024 for general files (~21ms at 48kHz)
/// - UpdateRate=64 for E-AC-3 (1536 samples = 1 E-AC-3 frame with 24 mandatory frames)
/// </summary>
class Program
{
    // For general audio files: UpdateRate=1024 samples per block
    // This gives ~21ms latency at 48kHz with good performance
    const int DefaultUpdateRate = 1024;
    const byte DefaultMandatoryFrames = 6;  // 6*1024 = 6144 samples buffer
    const int DefaultChannels = 6;          // 5.1 surround output
    const byte DefaultBitDepth = 16;        // BitDepth enum: Int16=16
    const int ChunkSize = 4096;

    static async Task Main(string[] args)
    {
        // Check if first argument is a file path (file-based mode)
        if (args.Length >= 1 && File.Exists(args[0]))
        {
            await RunFileBasedMode(args);
        }
        else
        {
            await RunStreamingMode(args);
        }
    }

    /// <summary>
    /// File-based mode: Send file path to server for direct file opening.
    /// This avoids all streaming issues with container formats.
    /// Args: <file_path> [channels] [bitDepth]
    /// </summary>
    static async Task RunFileBasedMode(string[] args)
    {
        string audioFile = args[0];
        int outputChannels = args.Length > 1 && int.TryParse(args[1], out int ch) ? ch : DefaultChannels;
        byte bitDepth = args.Length > 2 && byte.TryParse(args[2], out byte bd) ? bd : DefaultBitDepth;

        Console.Error.WriteLine($"[CavernPipeClient] File-based mode");
        Console.Error.WriteLine($"[CavernPipeClient] File: {audioFile}");
        Console.Error.WriteLine($"[CavernPipeClient] Output: {outputChannels}ch, {bitDepth}-bit, UpdateRate={DefaultUpdateRate}");

        var stream = await ConnectToServer();

        // Send handshake - NEGATIVE UpdateRate indicates file-based mode
        byte[] handshake = CreateHandshake(bitDepth, outputChannels, -DefaultUpdateRate);
        await stream.WriteAsync(handshake, 0, handshake.Length);
        Console.Error.WriteLine($"[CavernPipeClient] Handshake sent (file mode)");

        // Send file path (length-prefixed)
        byte[] pathBytes = System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(audioFile));
        byte[] pathLength = BitConverter.GetBytes(pathBytes.Length);
        await stream.WriteAsync(pathLength, 0, 4);
        await stream.WriteAsync(pathBytes, 0, pathBytes.Length);
        await stream.FlushAsync();
        Console.Error.WriteLine($"[CavernPipeClient] Sent file path ({pathBytes.Length} bytes)");

        // Receive PCM output and write to stdout
        await ReceivePcmOutput(stream);
    }

    /// <summary>
    /// Streaming mode: Read audio from stdin and stream to server.
    /// Args: [channels] [bitDepth]
    /// </summary>
    static async Task RunStreamingMode(string[] args)
    {
        int outputChannels = DefaultChannels;
        byte bitDepth = DefaultBitDepth;

        // Parse optional arguments
        if (args.Length >= 1 && int.TryParse(args[0], out int ch) && ch > 0)
        {
            outputChannels = ch;
        }
        if (args.Length >= 2 && byte.TryParse(args[1], out byte bd) && (bd == 16 || bd == 24 || bd == 32))
        {
            bitDepth = bd;
        }

        Console.Error.WriteLine($"[CavernPipeClient] Streaming mode");
        Console.Error.WriteLine($"[CavernPipeClient] Output: {outputChannels}ch, {bitDepth}-bit, UpdateRate={DefaultUpdateRate}");

        var stream = await ConnectToServer();

        // Send handshake - POSITIVE UpdateRate indicates streaming mode
        byte[] handshake = CreateHandshake(bitDepth, outputChannels, DefaultUpdateRate);
        await stream.WriteAsync(handshake, 0, handshake.Length);
        Console.Error.WriteLine($"[CavernPipeClient] Handshake sent (streaming mode)");

        // Stream audio data from stdin
        await StreamAudioData(stream);
    }

    static byte[] CreateHandshake(byte bitDepth, int channels, int updateRate)
    {
        byte[] handshake = new byte[8];
        handshake[0] = bitDepth;
        handshake[1] = DefaultMandatoryFrames;
        BitConverter.GetBytes((ushort)channels).CopyTo(handshake, 2);
        // Negative updateRate indicates file-based mode
        BitConverter.GetBytes(updateRate).CopyTo(handshake, 4);
        return handshake;
    }

    static async Task<NetworkStream> ConnectToServer()
    {
        string pipePath = FindCavernPipe() ?? throw new Exception("CavernPipe socket not found. Is CavernPipeServer running?");
        Console.Error.WriteLine($"[CavernPipeClient] Found pipe at: {pipePath}");

        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        var endpoint = new UnixDomainSocketEndPoint(pipePath);
        
        var cts = new CancellationTokenSource(5000);
        await socket.ConnectAsync(endpoint, cts.Token);
        Console.Error.WriteLine("[CavernPipeClient] Connected to CavernPipe.");

        return new NetworkStream(socket, ownsSocket: true);
    }

    static async Task StreamAudioData(Stream stream)
    {
        using var stdin = Console.OpenStandardInput();
        using var stdout = Console.OpenStandardOutput();
        
        byte[] inputBuffer = new byte[ChunkSize];
        int chunkCount = 0;
        int pcmChunkCount = 0;
        const int InitialBurst = 20;
        const int MaxWaitChunks = 200;
        int waitChunks = 0;
        
        while (true)
        {
            int bytesRead = await stdin.ReadAsync(inputBuffer, 0, inputBuffer.Length);
            if (bytesRead <= 0)
            {
                Console.Error.WriteLine("[CavernPipeClient] stdin closed.");
                break;
            }

            if (chunkCount == 0)
            {
                Console.Error.WriteLine($"[CavernPipeClient] First input chunk: {bytesRead} bytes");
            }

            // Send to server
            byte[] lengthPrefix = BitConverter.GetBytes(bytesRead);
            await stream.WriteAsync(lengthPrefix, 0, 4);
            await stream.WriteAsync(inputBuffer, 0, bytesRead);
            await stream.FlushAsync();
            chunkCount++;

            if (chunkCount < InitialBurst)
            {
                continue;
            }

            // Read PCM response
            byte[] pcmLengthBytes = new byte[4];
            int read = await ReadExactlyAsync(stream, pcmLengthBytes, 4);
            if (read < 4)
            {
                Console.Error.WriteLine("[CavernPipeClient] Server closed connection.");
                break;
            }

            int pcmLength = BitConverter.ToInt32(pcmLengthBytes, 0);
            
            if (pcmLength == 0)
            {
                waitChunks++;
                if (waitChunks > MaxWaitChunks)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Gave up after {MaxWaitChunks} chunks with no PCM");
                    break;
                }
                continue;
            }
            
            if (pcmLength < 0 || pcmLength > 10_000_000)
            {
                Console.Error.WriteLine($"[CavernPipeClient] Invalid PCM length: {pcmLength}");
                break;
            }

            byte[] pcmData = new byte[pcmLength];
            read = await ReadExactlyAsync(stream, pcmData, pcmLength);
            if (read < pcmLength)
            {
                Console.Error.WriteLine($"[CavernPipeClient] Short read: {read}/{pcmLength}");
                break;
            }

            if (pcmChunkCount == 0)
            {
                Console.Error.WriteLine($"[CavernPipeClient] First PCM chunk after {chunkCount} input chunks");
                waitChunks = 0;
            }

            await stdout.WriteAsync(pcmData, 0, pcmLength);
            await stdout.FlushAsync();
            pcmChunkCount++;
        }
        
        Console.Error.WriteLine($"[CavernPipeClient] Processed {chunkCount} input chunks, {pcmChunkCount} PCM chunks.");
    }

    static async Task ReceivePcmOutput(Stream stream)
    {
        using var stdout = Console.OpenStandardOutput();
        byte[] pcmBuffer = new byte[8192];
        long totalBytes = 0;
        int chunkCount = 0;

        try
        {
            while (true)
            {
                byte[] lengthBytes = new byte[4];
                int read = await ReadExactlyAsync(stream, lengthBytes, 4);
                if (read < 4)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Server closed connection after {totalBytes} bytes.");
                    break;
                }

                int pcmLength = BitConverter.ToInt32(lengthBytes, 0);
                if (pcmLength < 0 || pcmLength > 10_000_000)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Invalid PCM length: {pcmLength} at chunk {chunkCount}, total {totalBytes} bytes");
                    break;
                }
                if (pcmLength == 0)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] End of stream after {totalBytes} bytes in {chunkCount} chunks.");
                    break;
                }

                if (pcmLength > pcmBuffer.Length)
                {
                    pcmBuffer = new byte[pcmLength];
                }
                
                read = await ReadExactlyAsync(stream, pcmBuffer, pcmLength);
                if (read < pcmLength)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Short read: {read}/{pcmLength} at chunk {chunkCount}");
                    break;
                }

                await stdout.WriteAsync(pcmBuffer, 0, pcmLength);
                await stdout.FlushAsync(); // Critical for pipe mode
                totalBytes += pcmLength;
                chunkCount++;

                if (chunkCount == 1)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] First PCM chunk: {pcmLength} bytes, firstByte={pcmBuffer[0]:X2}");
                }
                else if (chunkCount % 100 == 0)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Chunk {chunkCount}: {pcmLength} bytes, firstByte={pcmBuffer[0]:X2}, total={totalBytes}");
                }
                else if (chunkCount % 100 == 0)
                {
                    Console.Error.WriteLine($"[CavernPipeClient] Progress: {chunkCount} chunks, {totalBytes} bytes");
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[CavernPipeClient] ERROR: {ex.Message}");
        }

        Console.Error.WriteLine($"[CavernPipeClient] Total: {totalBytes} bytes in {chunkCount} chunks");
    }

    static string? FindCavernPipe()
    {
        var searchPaths = new[]
        {
            "/tmp/CoreFxPipe_CavernPipe",
            "/var/tmp/CoreFxPipe_CavernPipe",
            Path.Combine(Path.GetTempPath(), "CoreFxPipe_CavernPipe")
        };

        foreach (var path in searchPaths)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        if (Directory.Exists("/var/folders"))
        {
            try
            {
                var found = Directory.GetFiles("/var/folders", "CoreFxPipe_CavernPipe", SearchOption.AllDirectories)
                    .FirstOrDefault();
                if (found != null)
                {
                    return found;
                }
            }
            catch
            {
                // Permission errors expected
            }
        }

        return null;
    }

    static async Task<int> ReadExactlyAsync(Stream stream, byte[] buffer, int count)
    {
        int totalRead = 0;
        while (totalRead < count)
        {
            int read = await stream.ReadAsync(buffer, totalRead, count - totalRead);
            if (read <= 0)
                break;
            totalRead += read;
        }
        return totalRead;
    }
}
