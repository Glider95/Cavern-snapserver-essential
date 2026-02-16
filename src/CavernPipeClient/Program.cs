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
        // Parse arguments to determine mode
        // File-based mode: -f <file_path> [channels] [bitDepth]
        // Streaming mode: [channels] [sampleRate] [bitDepth]
        var parsedArgs = ParseArguments(args);
        
        if (parsedArgs.FilePath != null)
        {
            await RunFileBasedMode(parsedArgs);
        }
        else
        {
            await RunStreamingMode(parsedArgs);
        }
    }

    class ParsedArguments
    {
        public string? FilePath { get; set; }
        public int Channels { get; set; } = DefaultChannels;
        public int SampleRate { get; set; } = 48000;
        public byte BitDepth { get; set; } = DefaultBitDepth;
    }

    static ParsedArguments ParseArguments(string[] args)
    {
        var result = new ParsedArguments();
        int i = 0;
        int positionalIndex = 0;  // Track position within remaining arguments
        
        while (i < args.Length)
        {
            switch (args[i])
            {
                case "-f":
                case "--file":
                    if (i + 1 < args.Length)
                    {
                        result.FilePath = args[i + 1];
                        i += 2;
                        positionalIndex = 0;  // Reset for args after -f
                    }
                    else
                    {
                        i++;
                    }
                    break;
                case "-c":
                case "--channels":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int ch))
                    {
                        result.Channels = ch;
                        i += 2;
                    }
                    else
                    {
                        i++;
                    }
                    break;
                case "-r":
                case "--rate":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int sr))
                    {
                        result.SampleRate = sr;
                        i += 2;
                    }
                    else
                    {
                        i++;
                    }
                    break;
                case "-b":
                case "--bits":
                    if (i + 1 < args.Length && byte.TryParse(args[i + 1], out byte bd))
                    {
                        result.BitDepth = bd;
                        i += 2;
                    }
                    else
                    {
                        i++;
                    }
                    break;
                default:
                    // Positional arguments
                    if (result.FilePath == null && File.Exists(args[i]))
                    {
                        result.FilePath = args[i];
                        // Don't increment positionalIndex - next arg is still first positional
                    }
                    else if (positionalIndex == 0)
                    {
                        // First positional: channels
                        if (int.TryParse(args[i], out int posCh))
                            result.Channels = posCh;
                        positionalIndex++;
                    }
                    else if (positionalIndex == 1)
                    {
                        // Second positional: bitDepth (file mode) or sampleRate (streaming)
                        if (int.TryParse(args[i], out int posVal))
                        {
                            if (result.FilePath != null)
                                result.BitDepth = (byte)posVal;
                            else
                                result.SampleRate = posVal;
                        }
                        positionalIndex++;
                    }
                    else if (positionalIndex == 2 && result.FilePath == null)
                    {
                        // Third positional: bitDepth (streaming mode only)
                        if (byte.TryParse(args[i], out byte posBd))
                            result.BitDepth = posBd;
                        positionalIndex++;
                    }
                    i++;
                    break;
            }
        }
        
        return result;
    }

    /// <summary>
    /// File-based mode: Send file path to server for direct file opening.
    /// This avoids all streaming issues with container formats.
    /// Args: -f <file_path> [channels] [bitDepth]
    /// </summary>
    static async Task RunFileBasedMode(ParsedArguments args)
    {
        string audioFile = args.FilePath!;
        int outputChannels = args.Channels;
        byte bitDepth = args.BitDepth;

        Console.Error.WriteLine($"[CavernPipeClient] File-based mode");
        Console.Error.WriteLine($"[CavernPipeClient] File: {audioFile}");
        Console.Error.WriteLine($"[CavernPipeClient] Output: {outputChannels}ch, {bitDepth}-bit, UpdateRate={DefaultUpdateRate}");

        var stream = await ConnectToServer();

        // Send handshake - NEGATIVE UpdateRate indicates file-based mode
        byte[] handshake = CreateHandshake(bitDepth, outputChannels, -DefaultUpdateRate);
        await stream.WriteAsync(handshake, 0, handshake.Length);
        Console.Error.WriteLine($"[CavernPipeClient] Handshake sent (file mode)");

        // Send file path (length-prefixed)
        string fullPath = Path.GetFullPath(audioFile);
        if (!File.Exists(fullPath))
        {
            Console.Error.WriteLine($"[CavernPipeClient] ERROR: File not found: {fullPath}");
            Environment.Exit(1);
        }
        byte[] pathBytes = System.Text.Encoding.UTF8.GetBytes(fullPath);
        byte[] pathLength = BitConverter.GetBytes(pathBytes.Length);
        await stream.WriteAsync(pathLength, 0, 4);
        await stream.WriteAsync(pathBytes, 0, pathBytes.Length);
        await stream.FlushAsync();
        Console.Error.WriteLine($"[CavernPipeClient] Sent file path ({pathBytes.Length} bytes): {fullPath}");

        // Receive PCM output and write to stdout
        await ReceivePcmOutput(stream);
    }

    /// <summary>
    /// Streaming mode: Read audio from stdin and stream to server.
    /// Args: [channels] [sampleRate] [bitDepth]
    /// </summary>
    static async Task RunStreamingMode(ParsedArguments args)
    {
        int outputChannels = args.Channels;
        byte bitDepth = args.BitDepth;
        // SampleRate is for logging only in streaming mode
        Console.Error.WriteLine($"[CavernPipeClient] Sample rate: {args.SampleRate}Hz");

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
        // Cavern BitDepth enum uses raw bit depth values: Int8=8, Int16=16, Int24=24, Float32=32
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
