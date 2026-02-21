using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net.Sockets;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace StreamingAdapter;

/// <summary>
/// Streaming Adapter for CavernPipe - Auto-detects input stream parameters
/// and bridges audio from applications (VLC, Stremio, browsers) to CavernPipe.
/// </summary>
class Program
{
    // Defaults (will be overridden by detected values)
    const int DefaultUpdateRate = 1024;
    const byte DefaultMandatoryFrames = 6;
    int OutputChannels = 6;
    byte BitDepth = 16;
    int SampleRate = 48000;
    const int ChunkSize = 4096;

    // Audio format info
    class AudioFormat
    {
        public int Channels { get; set; } = 2;
        public int SampleRate { get; set; } = 48000;
        public int BitDepth { get; set; } = 16;
        public string Codec { get; set; } = "unknown";
        public double Duration { get; set; } = 0;
    }

    static async Task Main(string[] args)
    {
        var program = new Program();
        await program.RunAsync(args);
    }

    async Task RunAsync(string[] args)
    {
        // Parse arguments
        ParseArguments(args);

        Console.Error.WriteLine($"[StreamingAdapter] Starting...");
        Console.Error.WriteLine($"[StreamingAdapter] Target: {OutputChannels}ch @ {SampleRate}Hz, {BitDepth}-bit");

        // Try to detect format from stdin if it's seekable (file redirect)
        var detectedFormat = await DetectAudioFormatAsync();
        if (detectedFormat != null)
        {
            Console.Error.WriteLine($"[StreamingAdapter] Detected: {detectedFormat.Channels}ch @ {detectedFormat.SampleRate}Hz, {detectedFormat.BitDepth}-bit ({detectedFormat.Codec})");
            
            // Use detected sample rate if not explicitly set
            if (!args.Contains("-r") && !args.Contains("--rate"))
            {
                SampleRate = detectedFormat.SampleRate;
            }
        }

        // Connect to CavernPipeServer
        var stream = await ConnectToServerAsync();

        // Send handshake
        byte[] handshake = CreateHandshake(BitDepth, OutputChannels, DefaultUpdateRate);
        await stream.WriteAsync(handshake);
        Console.Error.WriteLine($"[StreamingAdapter] Handshake sent: {BitDepth}-bit, {OutputChannels}ch, UpdateRate={DefaultUpdateRate}");

        // Stream audio data from stdin with format conversion if needed
        await StreamAudioDataAsync(stream, detectedFormat);
    }

    void ParseArguments(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "-c":
                case "--channels":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int ch))
                    {
                        OutputChannels = ch;
                        i++;
                    }
                    break;
                case "-r":
                case "--rate":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int sr))
                    {
                        SampleRate = sr;
                        i++;
                    }
                    break;
                case "-b":
                case "--bits":
                    if (i + 1 < args.Length && byte.TryParse(args[i + 1], out byte bd))
                    {
                        BitDepth = bd;
                        i++;
                    }
                    break;
                case "-u":
                case "--update-rate":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int ur))
                    {
                        i++;
                    }
                    break;
                default:
                    // Positional argument: channels
                    if (i == 0 && int.TryParse(args[i], out int posCh))
                    {
                        OutputChannels = posCh;
                    }
                    // Positional argument: sample rate
                    else if (i == 1 && int.TryParse(args[i], out int posSr))
                    {
                        SampleRate = posSr;
                    }
                    // Positional argument: bit depth
                    else if (i == 2 && byte.TryParse(args[i], out byte posBd))
                    {
                        BitDepth = posBd;
                    }
                    break;
            }
        }
    }

    async Task<AudioFormat?> DetectAudioFormatAsync()
    {
        try
        {
            // Check if stdin is a file (seekable)
            var stdin = Console.OpenStandardInput();
            if (!stdin.CanSeek)
            {
                // Streaming input - can't detect beforehand
                return null;
            }

            // Read first 64KB for analysis
            byte[] header = new byte[65536];
            int read = await stdin.ReadAsync(header);
            
            // Reset position for later reading
            stdin.Seek(0, SeekOrigin.Begin);

            if (read < 16)
                return null;

            var format = new AudioFormat();

            // Detect codec by magic bytes
            if (header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46)
            {
                format.Codec = "wav";
                // Parse WAV header
                format.Channels = BitConverter.ToUInt16(header, 22);
                format.SampleRate = BitConverter.ToInt32(header, 24);
                format.BitDepth = BitConverter.ToUInt16(header, 34);
            }
            else if (header[0] == 0xFF && (header[1] & 0xF0) == 0xF0)
            {
                format.Codec = "aac";
            }
            else if (header[0] == 0x0B && header[1] == 0x77)
            {
                format.Codec = "ac3";
            }
            else if (header[0] == 0xF8 && header[1] == 0x72 && header[2] == 0x6F && header[3] == 0xBA)
            {
                format.Codec = "truehd";
            }
            else
            {
                // Try ffprobe for more complex formats
                return await DetectWithFfprobeAsync();
            }

            return format;
        }
        catch
        {
            return null;
        }
    }

    async Task<AudioFormat?> DetectWithFfprobeAsync()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "ffprobe",
                Arguments = "-v error -select_streams a:0 -show_entries stream=codec_name,channels,sample_rate -of json -",
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };

            using var process = Process.Start(psi);
            if (process == null) return null;

            // Copy stdin to ffprobe
            await Console.OpenStandardInput().CopyToAsync(process.StandardInput.BaseStream);
            process.StandardInput.Close();

            string output = await process.StandardOutput.ReadToEndAsync();
            await process.WaitForExitAsync();

            if (process.ExitCode != 0)
                return null;

            try
            {
                using var doc = JsonDocument.Parse(output);
                if (doc.RootElement.TryGetProperty("streams", out var streams) && streams.GetArrayLength() > 0)
                {
                    var stream = streams[0];
                    var format = new AudioFormat();
                    
                    if (stream.TryGetProperty("codec_name", out var codec))
                        format.Codec = codec.GetString() ?? "unknown";
                    
                    if (stream.TryGetProperty("channels", out var channels))
                        format.Channels = channels.GetInt32();
                    
                    if (stream.TryGetProperty("sample_rate", out var sr))
                    {
                        if (sr.ValueKind == JsonValueKind.Number)
                            format.SampleRate = sr.GetInt32();
                        else
                            format.SampleRate = int.Parse(sr.GetString() ?? "48000");
                    }

                    return format;
                }
            }
            catch (JsonException ex)
            {
                Console.Error.WriteLine($"[StreamingAdapter] JSON parse error: {ex.Message}");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[StreamingAdapter] ffprobe detection failed: {ex.Message}");
        }

        return null;
    }

    async Task<NetworkStream> ConnectToServerAsync()
    {
        string pipePath = FindCavernPipe() ?? throw new Exception("CavernPipe socket not found. Is CavernPipeServer running?");
        Console.Error.WriteLine($"[StreamingAdapter] Found pipe at: {pipePath}");

        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        var endpoint = new UnixDomainSocketEndPoint(pipePath);
        
        var cts = new CancellationTokenSource(5000);
        await socket.ConnectAsync(endpoint, cts.Token);
        Console.Error.WriteLine("[StreamingAdapter] Connected to CavernPipe.");

        return new NetworkStream(socket, ownsSocket: true);
    }

    byte[] CreateHandshake(byte bitDepth, int channels, int updateRate)
    {
        byte[] handshake = new byte[8];
        // Cavern BitDepth enum uses raw bit depth values: Int8=8, Int16=16, Int24=24, Float32=32
        handshake[0] = bitDepth;
        handshake[1] = DefaultMandatoryFrames;
        BitConverter.GetBytes((ushort)channels).CopyTo(handshake, 2);
        BitConverter.GetBytes(updateRate).CopyTo(handshake, 4);
        return handshake;
    }

    async Task StreamAudioDataAsync(Stream stream, AudioFormat? inputFormat)
    {
        using var stdin = Console.OpenStandardInput();
        using var stdout = Console.OpenStandardOutput();
        
        byte[] inputBuffer = new byte[ChunkSize];
        int chunkCount = 0;
        int pcmChunkCount = 0;
        const int InitialBurst = 20;
        const int MaxWaitChunks = 200;
        int waitChunks = 0;
        
        // Check if we need resampling
        bool needsResampling = inputFormat != null && 
                               (inputFormat.SampleRate != SampleRate || 
                                inputFormat.Channels != OutputChannels);

        if (needsResampling)
        {
            Console.Error.WriteLine($"[StreamingAdapter] Format conversion needed: {inputFormat!.Channels}->{OutputChannels}ch, {inputFormat.SampleRate}->{SampleRate}Hz");
        }

        while (true)
        {
            int bytesRead = await stdin.ReadAsync(inputBuffer, 0, inputBuffer.Length);
            if (bytesRead <= 0)
            {
                Console.Error.WriteLine("[StreamingAdapter] stdin closed.");
                break;
            }

            if (chunkCount == 0)
            {
                Console.Error.WriteLine($"[StreamingAdapter] First input chunk: {bytesRead} bytes");
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
                Console.Error.WriteLine("[StreamingAdapter] Server closed connection.");
                break;
            }

            int pcmLength = BitConverter.ToInt32(pcmLengthBytes, 0);
            
            if (pcmLength == 0)
            {
                waitChunks++;
                if (waitChunks > MaxWaitChunks)
                {
                    Console.Error.WriteLine($"[StreamingAdapter] Gave up after {MaxWaitChunks} chunks with no PCM");
                    break;
                }
                continue;
            }
            
            if (pcmLength < 0 || pcmLength > 10_000_000)
            {
                Console.Error.WriteLine($"[StreamingAdapter] Invalid PCM length: {pcmLength}");
                break;
            }

            byte[] pcmData = new byte[pcmLength];
            read = await ReadExactlyAsync(stream, pcmData, pcmLength);
            if (read < pcmLength)
            {
                Console.Error.WriteLine($"[StreamingAdapter] Short read: {read}/{pcmLength}");
                break;
            }

            if (pcmChunkCount == 0)
            {
                Console.Error.WriteLine($"[StreamingAdapter] First PCM chunk after {chunkCount} input chunks");
                waitChunks = 0;
            }

            await stdout.WriteAsync(pcmData, 0, pcmLength);
            await stdout.FlushAsync();
            pcmChunkCount++;
        }
        
        Console.Error.WriteLine($"[StreamingAdapter] Processed {chunkCount} input chunks, {pcmChunkCount} PCM chunks.");
    }

    string? FindCavernPipe()
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

    async Task<int> ReadExactlyAsync(Stream stream, byte[] buffer, int count)
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
