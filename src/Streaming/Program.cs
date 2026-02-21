using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Sockets;

namespace CavernSnapcastStreaming;

/// <summary>
/// CavernSnapcastStreaming - Dolby Atmos streaming to Snapcast on Windows.
/// 
/// Usage:
///   CavernSnapcastStreaming.exe server    - Start pipe server and stream to snapserver
///   CavernSnapcastStreaming.exe play <file> - Play a media file to snapserver
///   CavernSnapcastStreaming.exe bridge    - Bridge mode (CavernPipe → Snapserver)
/// </summary>
class Program
{
    private static CancellationTokenSource _cts = new();

    static async Task Main(string[] args)
    {
        // Setup cancellation handling
        Console.CancelKeyPress += (s, e) =>
        {
            e.Cancel = true;
            _cts.Cancel();
            Console.Error.WriteLine("\n[Program] Shutdown requested...");
        };

        if (args.Length == 0)
        {
            PrintUsage();
            return;
        }

        string command = args[0].ToLower();

        try
        {
            switch (command)
            {
                case "server":
                case "s":
                    await RunServerModeAsync(args[1..]);
                    break;

                case "play":
                case "p":
                    if (args.Length < 2)
                    {
                        Console.Error.WriteLine("ERROR: Missing file path");
                        Console.Error.WriteLine("Usage: play <file> [options]");
                        return;
                    }
                    await RunPlayModeAsync(args[1], args[2..]);
                    break;

                case "bridge":
                case "b":
                    await RunBridgeModeAsync(args[1..]);
                    break;

                case "stream":
                    await RunStreamingModeAsync(args[1..]);
                    break;

                case "test":
                case "t":
                    await RunTestModeAsync(args[1..]);
                    break;

                case "wav":
                case "w":
                    if (args.Length < 2)
                    {
                        Console.Error.WriteLine("ERROR: Missing output file path");
                        Console.Error.WriteLine("Usage: wav <output.wav> [inputOptions]");
                        return;
                    }
                    await RunWavOutputModeAsync(args[1], args[2..]);
                    break;

                case "emulator":
                case "emu":
                case "e":
                    await RunEmulatorModeAsync(args[1..]);
                    break;

                case "help":
                case "-h":
                case "--help":
                    PrintUsage();
                    break;

                default:
                    Console.Error.WriteLine($"Unknown command: {command}");
                    PrintUsage();
                    break;
            }
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("[Program] Cancelled by user");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Program] ERROR: {ex.Message}");
            Console.Error.WriteLine($"[Program] Stack trace: {ex.StackTrace}");
            Environment.Exit(1);
        }
    }

    static void PrintUsage()
    {
        Console.WriteLine(@"
CavernSnapcastStreaming - Dolby Atmos to Snapcast on Windows

Usage:
  CavernSnapcastStreaming.exe <command> [options]

Commands:
  server              Start the named pipe server and stream to snapserver
  play <file>         Play a media file (TrueHD/E-AC-3/DTS) to snapserver
  bridge              Bridge mode: connect to CavernPipe and stream to snapserver
  stream              Streaming mode: read from stdin, process, stream to snapserver
  test                Test mode: start test receiver (no snapserver needed)
  wav <output>        Output to WAV file instead of snapserver
  emulator            Run Snapserver emulator (works with real snapclients!)

Options:
  -c, --channels N    Output channels (2, 6, 8) [default: 6]
  -r, --rate N        Sample rate in Hz [default: 48000]
  -b, --bits N        Bit depth (16, 24) [default: 16]
  -h, --host HOST     Snapserver host [default: localhost]
  -p, --port PORT     Snapserver port [default: 1704]
  --snapserver PATH   Path to snapserver.exe [default: auto-detect]

Examples:
  # Start server mode
  CavernSnapcastStreaming.exe server -c 6 -r 48000

  # Play a Dolby Atmos movie
  CavernSnapcastStreaming.exe play ""C:\Movies\movie.mkv"" -c 6

  # Stream with FFmpeg
  ffmpeg -i movie.mkv -acodec copy -f mka - | CavernSnapcastStreaming.exe stream -c 6
");
    }

    /// <summary>
    /// Server mode: Start NamedPipeServer, connect to Snapserver, bridge audio.
    /// </summary>
    static async Task RunServerModeAsync(string[] args)
    {
        var config = ParseConfig(args);
        
        Console.Error.WriteLine("╔═══════════════════════════════════════════════════════════╗");
        Console.Error.WriteLine("║     CavernSnapcastStreaming - Server Mode                 ║");
        Console.Error.WriteLine("╠═══════════════════════════════════════════════════════════╣");
        Console.Error.WriteLine($"║ Pipe:      \\.\\pipe\\{config.PipeName,-39} ║");
        Console.Error.WriteLine($"║ Snapcast:  {config.SnapserverHost}:{config.SnapserverPort,-38} ║");
        Console.Error.WriteLine($"║ Format:    {config.Channels}ch @ {config.SampleRate}Hz, {config.BitDepth}-bit{' ',24} ║");
        Console.Error.WriteLine("╚═══════════════════════════════════════════════════════════╝");
        Console.Error.WriteLine();

        // Start snapserver if not running
        await EnsureSnapserverRunningAsync(config);

        // Create and start the named pipe server
        using var pipeServer = new NamedPipeServer(config.PipeName)
        {
            OutputChannels = config.Channels,
            SampleRate = config.SampleRate,
            BitDepth = config.BitDepth
        };

        // Buffer for collecting audio before sending to Snapserver
        var audioBuffer = new List<byte>();
        int chunkBytes = config.SampleRate * 20 / 1000 * config.Channels * (config.BitDepth / 8);

        pipeServer.AudioDataReceived += (s, e) =>
        {
            // Accumulate audio data
            lock (audioBuffer)
            {
                audioBuffer.AddRange(e.AudioData);
            }
        };

        await pipeServer.StartAsync();
        Console.Error.WriteLine("[Server] Named pipe server started");

        // Connect to Snapserver and stream
        using var snapClient = new TcpClient();
        await snapClient.ConnectAsync(config.SnapserverHost, config.SnapserverPort);
        var snapStream = snapClient.GetStream();

        Console.Error.WriteLine("[Server] Connected to Snapserver");

        // Send Snapcast header
        await SendSnapcastHeaderAsync(snapStream, config);

        // Streaming loop
        var bufferArray = new byte[0];
        int chunkCount = 0;

        while (!_cts.Token.IsCancellationRequested)
        {
            byte[] chunk;
            lock (audioBuffer)
            {
                if (audioBuffer.Count >= chunkBytes)
                {
                    chunk = audioBuffer.Take(chunkBytes).ToArray();
                    audioBuffer.RemoveRange(0, chunkBytes);
                }
                else
                {
                    chunk = Array.Empty<byte>();
                }
            }

            if (chunk.Length > 0)
            {
                await SendSnapcastChunkAsync(snapStream, chunk);
                chunkCount++;

                if (chunkCount % 100 == 0)
                {
                    Console.Error.WriteLine($"[Server] Streamed {chunkCount} chunks");
                }
            }
            else
            {
                await Task.Delay(5, _cts.Token);
            }
        }
    }

    /// <summary>
    /// Play mode: Extract audio from file, send through Cavern processing, stream to Snapserver.
    /// </summary>
    static async Task RunPlayModeAsync(string filePath, string[] args)
    {
        var config = ParseConfig(args);
        
        if (!File.Exists(filePath))
        {
            Console.Error.WriteLine($"ERROR: File not found: {filePath}");
            Environment.Exit(1);
        }

        Console.Error.WriteLine($"[Play] File: {filePath}");
        Console.Error.WriteLine($"[Play] Output: {config.Channels}ch @ {config.SampleRate}Hz, {config.BitDepth}-bit");

        // Ensure snapserver is running
        await EnsureSnapserverRunningAsync(config);

        // Detect file type
        string ext = Path.GetExtension(filePath).ToLower();
        bool isDamf = ext == ".atmos";

        if (isDamf)
        {
            // DAMF file - can use file-based mode
            await PlayDamfFileAsync(filePath, config);
        }
        else
        {
            // Regular media file - extract and stream
            await PlayMediaFileAsync(filePath, config);
        }
    }

    /// <summary>
    /// Bridge mode: Connect to existing CavernPipe, bridge to Snapserver.
    /// </summary>
    static async Task RunBridgeModeAsync(string[] args)
    {
        var config = ParseConfig(args);
        
        Console.Error.WriteLine("[Bridge] Starting bridge mode...");

        await EnsureSnapserverRunningAsync(config);

        using var bridge = new SnapcastBridge
        {
            SnapserverHost = config.SnapserverHost,
            SnapserverPort = config.SnapserverPort,
            PipeName = config.PipeName,
            SampleRate = config.SampleRate,
            Channels = config.Channels,
            BitDepth = config.BitDepth
        };

        await bridge.StartAsync();
    }

    /// <summary>
    /// Streaming mode: Read from stdin, process through Cavern, stream to Snapserver.
    /// </summary>
    static async Task RunStreamingModeAsync(string[] args)
    {
        var config = ParseConfig(args);
        
        Console.Error.WriteLine("[Stream] Streaming mode - reading from stdin...");

        await EnsureSnapserverRunningAsync(config);

        // Connect to Snapserver
        using var snapClient = new TcpClient();
        await snapClient.ConnectAsync(config.SnapserverHost, config.SnapserverPort);
        var snapStream = snapClient.GetStream();

        await SendSnapcastHeaderAsync(snapStream, config);

        // Read from stdin and stream
        using var stdin = Console.OpenStandardInput();
        byte[] buffer = new byte[4096];
        int bytesRead;
        long totalBytes = 0;

        while ((bytesRead = await stdin.ReadAsync(buffer, 0, buffer.Length, _cts.Token)) > 0)
        {
            await SendSnapcastChunkAsync(snapStream, buffer.Take(bytesRead).ToArray());
            totalBytes += bytesRead;
        }

        Console.Error.WriteLine($"[Stream] Finished: {totalBytes} bytes streamed");
    }

    /// <summary>
    /// WAV output mode: Process audio and save to WAV file instead of streaming.
    /// </summary>
    static async Task RunWavOutputModeAsync(string outputFile, string[] args)
    {
        var config = ParseConfig(args);
        string? inputFile = null;
        
        // Parse input file
        for (int i = 0; i < args.Length; i++)
        {
            if ((args[i] == "-i" || args[i] == "--input") && i + 1 < args.Length)
            {
                inputFile = args[i + 1];
                i++;
            }
        }

        Console.Error.WriteLine("╔═══════════════════════════════════════════════════════════╗");
        Console.Error.WriteLine("║     CavernSnapcastStreaming - WAV OUTPUT MODE             ║");
        Console.Error.WriteLine("║     (No snapserver required - outputs to WAV)             ║");
        Console.Error.WriteLine("╠═══════════════════════════════════════════════════════════╣");
        Console.Error.WriteLine($"║ Output:    {outputFile,-48} ║");
        Console.Error.WriteLine($"║ Format:    {config.Channels}ch @ {config.SampleRate}Hz, {config.BitDepth}-bit{' ',24} ║");
        Console.Error.WriteLine("╚═══════════════════════════════════════════════════════════╝");
        Console.Error.WriteLine();

        using var wavWriter = new WavWriter
        {
            SampleRate = config.SampleRate,
            Channels = config.Channels,
            BitDepth = config.BitDepth
        };

        wavWriter.Open(outputFile);
        Console.Error.WriteLine($"[WAV] Created: {outputFile}");

        if (inputFile != null)
        {
            // Process input file and convert to WAV
            await ConvertToWavAsync(inputFile, wavWriter, config);
        }
        else
        {
            // Read from stdin
            await StreamToWavAsync(wavWriter, config);
        }

        Console.Error.WriteLine($"[WAV] Finished: {outputFile}");
    }

    /// <summary>
    /// Convert media file to WAV.
    /// </summary>
    static async Task ConvertToWavAsync(string inputFile, WavWriter wavWriter, AppConfig config)
    {
        if (!File.Exists(inputFile))
        {
            Console.Error.WriteLine($"[WAV] ERROR: File not found: {inputFile}");
            return;
        }

        Console.Error.WriteLine($"[WAV] Converting: {inputFile}");

        var ffmpeg = FindFFmpeg();
        string ffmpegArgs = $"-i \"{inputFile}\" -vn -acodec pcm_s{config.BitDepth}le -ar {config.SampleRate} -ac {config.Channels} -f s{config.BitDepth}le -";

        var psi = new ProcessStartInfo
        {
            FileName = ffmpeg,
            Arguments = ffmpegArgs,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi);
        if (process == null)
        {
            Console.Error.WriteLine("[WAV] ERROR: Failed to start FFmpeg");
            return;
        }

        byte[] buffer = new byte[4096];
        int bytesRead;
        long totalBytes = 0;

        while ((bytesRead = await process.StandardOutput.BaseStream.ReadAsync(buffer, 0, buffer.Length)) > 0)
        {
            wavWriter.WriteSamples(buffer, 0, bytesRead);
            totalBytes += bytesRead;

            if (totalBytes % (1024 * 1024) < 4096)
            {
                Console.Error.WriteLine($"[WAV] Processed: {totalBytes / 1024 / 1024} MB");
            }
        }

        await process.WaitForExitAsync();
        Console.Error.WriteLine($"[WAV] FFmpeg exited: {process.ExitCode}");
        Console.Error.WriteLine($"[WAV] Total: {totalBytes} bytes written");
    }

    /// <summary>
    /// Stream from stdin to WAV file.
    /// </summary>
    static async Task StreamToWavAsync(WavWriter wavWriter, AppConfig config)
    {
        Console.Error.WriteLine("[WAV] Reading from stdin (Ctrl+Z then Enter to finish)...");

        using var stdin = Console.OpenStandardInput();
        byte[] buffer = new byte[4096];
        int bytesRead;
        long totalBytes = 0;

        while ((bytesRead = await stdin.ReadAsync(buffer, 0, buffer.Length)) > 0)
        {
            wavWriter.WriteSamples(buffer, 0, bytesRead);
            totalBytes += bytesRead;

            if (totalBytes % (1024 * 1024) < 4096)
            {
                Console.Error.WriteLine($"[WAV] Received: {totalBytes / 1024 / 1024} MB");
            }
        }

        Console.Error.WriteLine($"[WAV] Total: {totalBytes} bytes written");
    }

    /// <summary>
    /// Test mode: Start a test receiver that mimics snapserver for testing.
    /// </summary>
    static async Task RunTestModeAsync(string[] args)
    {
        var config = ParseConfig(args);
        string? outputFile = null;
        
        // Parse additional test-specific args
        for (int i = 0; i < args.Length; i++)
        {
            if ((args[i] == "-o" || args[i] == "--output") && i + 1 < args.Length)
            {
                outputFile = args[i + 1];
                i++;
            }
        }

        Console.Error.WriteLine("╔═══════════════════════════════════════════════════════════╗");
        Console.Error.WriteLine("║     CavernSnapcastStreaming - TEST MODE                   ║");
        Console.Error.WriteLine("║     (No snapserver required - test receiver)              ║");
        Console.Error.WriteLine("╠═══════════════════════════════════════════════════════════╣");
        Console.Error.WriteLine($"║ Port:      {config.SnapserverPort,-48} ║");
        Console.Error.WriteLine($"║ Output:    {(outputFile ?? "Playback only"),-48} ║");
        Console.Error.WriteLine("╚═══════════════════════════════════════════════════════════╝");
        Console.Error.WriteLine();
        Console.Error.WriteLine("This mode starts a test receiver that mimics snapserver.");
        Console.Error.WriteLine("You can test the streaming pipeline without installing snapserver.");
        Console.Error.WriteLine();
        Console.Error.WriteLine("To test playback, run in another terminal:");
        Console.Error.WriteLine($"  .\\Play-AtmosMovie.ps1 -Path \"movie.mkv\" -SnapserverPort {config.SnapserverPort}");
        Console.Error.WriteLine();

        using var receiver = new TestReceiver
        {
            Port = config.SnapserverPort,
            OutputFile = outputFile,
            Verbose = true
        };

        await receiver.StartAsync();

        Console.Error.WriteLine("Press Ctrl+C to stop...");
        
        try
        {
            await Task.Delay(-1, _cts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("\n[Test] Stopping...");
        }
    }

    /// <summary>
    /// Play a DAMF file (file-based mode).
    /// </summary>
    static async Task PlayDamfFileAsync(string filePath, AppConfig config)
    {
        Console.Error.WriteLine("[Play] Using file-based mode for DAMF");

        // Connect to Snapserver
        using var snapClient = new TcpClient();
        await snapClient.ConnectAsync(config.SnapserverHost, config.SnapserverPort);
        var snapStream = snapClient.GetStream();

        await SendSnapcastHeaderAsync(snapStream, config);

        // Read DAMF file and stream
        // In real implementation, this would decode the DAMF format
        // For now, read raw and stream
        using var fileStream = File.OpenRead(filePath);
        byte[] buffer = new byte[4096];
        int bytesRead;
        int chunkCount = 0;

        while ((bytesRead = await fileStream.ReadAsync(buffer, 0, buffer.Length, _cts.Token)) > 0)
        {
            await SendSnapcastChunkAsync(snapStream, buffer.Take(bytesRead).ToArray());
            chunkCount++;

            // Rate limit to match real-time
            await Task.Delay(20, _cts.Token);
        }

        Console.Error.WriteLine($"[Play] Finished: {chunkCount} chunks");
    }

    /// <summary>
    /// Play a media file using FFmpeg for extraction.
    /// </summary>
    static async Task PlayMediaFileAsync(string filePath, AppConfig config)
    {
        Console.Error.WriteLine("[Play] Extracting audio with FFmpeg...");

        // Build FFmpeg arguments
        string ffmpegArgs = $"-i \"{filePath}\" -vn -acodec pcm_s16le -ar {config.SampleRate} -ac {config.Channels} -f s16le -";

        var psi = new ProcessStartInfo
        {
            FileName = FindFFmpeg(),
            Arguments = ffmpegArgs,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi);
        if (process == null)
        {
            throw new Exception("Failed to start FFmpeg");
        }

        // Connect to Snapserver
        using var snapClient = new TcpClient();
        await snapClient.ConnectAsync(config.SnapserverHost, config.SnapserverPort);
        var snapStream = snapClient.GetStream();

        await SendSnapcastHeaderAsync(snapStream, config);

        // Stream from FFmpeg to Snapserver
        byte[] buffer = new byte[4096];
        int bytesRead;
        long totalBytes = 0;

        while ((bytesRead = await process.StandardOutput.BaseStream.ReadAsync(buffer, 0, buffer.Length, _cts.Token)) > 0)
        {
            await SendSnapcastChunkAsync(snapStream, buffer.Take(bytesRead).ToArray());
            totalBytes += bytesRead;
        }

        await process.WaitForExitAsync();
        Console.Error.WriteLine($"[Play] FFmpeg exited with code: {process.ExitCode}");
        Console.Error.WriteLine($"[Play] Streamed: {totalBytes} bytes");
    }

    /// <summary>
    /// Send Snapcast wire protocol header.
    /// </summary>
    static async Task SendSnapcastHeaderAsync(NetworkStream stream, AppConfig config)
    {
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        string codec = "pcm";
        byte[] codecBytes = System.Text.Encoding.UTF8.GetBytes(codec);

        // Base message header
        uint messageSize = (uint)(26 + codecBytes.Length + 8);
        
        writer.Write((ushort)0);           // type: codec header
        writer.Write(messageSize);         // size
        writer.Write((uint)0);             // received secs
        writer.Write((uint)0);             // received usecs
        writer.Write((uint)0);             // remote timestamp

        // Codec header
        writer.Write((uint)codecBytes.Length);
        writer.Write(codecBytes);

        // PCM header
        writer.Write((uint)config.SampleRate);
        writer.Write((ushort)config.BitDepth);
        writer.Write((ushort)config.Channels);

        byte[] header = ms.ToArray();
        await stream.WriteAsync(header, 0, header.Length);
        await stream.FlushAsync();

        Console.Error.WriteLine($"[Snapcast] Sent header: {codec}, {config.SampleRate}Hz, {config.Channels}ch");
    }

    /// <summary>
    /// Send a Snapcast wire chunk.
    /// </summary>
    static async Task SendSnapcastChunkAsync(NetworkStream stream, byte[] data)
    {
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        long timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        
        writer.Write((ushort)1);           // type: wire chunk
        writer.Write((uint)data.Length);   // size
        writer.Write((uint)(timestamp / 1000));    // secs
        writer.Write((uint)((timestamp % 1000) * 1000)); // usecs

        byte[] header = ms.ToArray();
        await stream.WriteAsync(header, 0, header.Length);
        await stream.WriteAsync(data, 0, data.Length);
        await stream.FlushAsync();
    }

    /// <summary>
    /// Run Snapserver emulator mode - works with real snapclients!
    /// </summary>
    static async Task RunEmulatorModeAsync(string[] args)
    {
        var config = ParseConfig(args);
        
        Console.Error.WriteLine("╔═══════════════════════════════════════════════════════════╗");
        Console.Error.WriteLine("║     Snapserver Emulator Mode                              ║");
        Console.Error.WriteLine("║     (Works with real snapclients!)                        ║");
        Console.Error.WriteLine("╠═══════════════════════════════════════════════════════════╣");
        Console.Error.WriteLine($"║ TCP Port:  {config.SnapserverPort,-48} ║");
        Console.Error.WriteLine($"║ HTTP Port: {config.SnapserverPort + 76,-48} ║");
        Console.Error.WriteLine($"║ RPC Port:  {config.SnapserverPort + 1,-48} ║");
        Console.Error.WriteLine($"║ Format:    {config.Channels}ch @ {config.SampleRate}Hz, {config.BitDepth}-bit{' ',24} ║");
        Console.Error.WriteLine("╚═══════════════════════════════════════════════════════════╝");
        Console.Error.WriteLine();
        Console.Error.WriteLine("This is a lightweight Snapserver replacement for Windows.");
        Console.Error.WriteLine("It implements enough of the Snapcast protocol to work with");
        Console.Error.WriteLine("real snapclients (ESP32, Android, Linux, etc.).");
        Console.Error.WriteLine();

        using var emulator = new SnapserverEmulator
        {
            TcpPort = config.SnapserverPort,
            HttpPort = config.SnapserverPort + 76, // 1780
            RpcPort = config.SnapserverPort + 1,   // 1705
            SampleRate = config.SampleRate,
            Channels = config.Channels,
            BitDepth = config.BitDepth,
            Codec = config.Channels <= 8 ? "flac" : "pcm"
        };

        await emulator.StartAsync();

        Console.Error.WriteLine();
        Console.Error.WriteLine("Now you can connect snapclients:");
        Console.Error.WriteLine($"  snapclient -h {System.Net.Dns.GetHostName()} -p {config.SnapserverPort}");
        Console.Error.WriteLine();
        Console.Error.WriteLine("Or stream audio from another terminal:");
        Console.Error.WriteLine($"  .\\Play-AtmosMovie.ps1 -Path \"movie.mkv\" -SnapserverPort {config.SnapserverPort}");
        Console.Error.WriteLine();

        // Wait for cancellation
        try
        {
            await Task.Delay(-1, _cts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("\n[Emulator] Stopping...");
        }
    }

    /// <summary>
    /// Ensure snapserver is running, start it if needed.
    /// </summary>
    static async Task EnsureSnapserverRunningAsync(AppConfig config)
    {
        // Check if already running
        if (IsProcessRunning("snapserver"))
        {
            Console.Error.WriteLine("[Snapserver] Already running");
            return;
        }

        string snapserverPath = config.SnapserverPath ?? FindSnapserver();
        if (string.IsNullOrEmpty(snapserverPath) || !File.Exists(snapserverPath))
        {
            Console.Error.WriteLine("[Snapserver] WARNING: snapserver not found. Please ensure it's installed and in PATH.");
            Console.Error.WriteLine("[Snapserver] Continuing anyway - you can start it manually.");
            return;
        }

        Console.Error.WriteLine($"[Snapserver] Starting: {snapserverPath}");

        // Create temp config file
        string configPath = Path.Combine(Path.GetTempPath(), "snapserver-cavern.conf");
        string codec = config.Channels <= 8 ? "flac" : "pcm";
        string sampleFormat = $"{config.SampleRate}:{config.BitDepth}:{config.Channels}";
        
        File.WriteAllText(configPath, $@"
[stream]
source = tcp://0.0.0.0:{config.SnapserverPort + 100}?name=CavernTCP&codec={codec}&sampleformat={sampleFormat}

[http]
enabled = true
port = 1780

[tcp]
enabled = true
port = 1705

[server]
port = {config.SnapserverPort}
codec = {codec}
buffer = 2000
send_to_muted = false

[logging]
sink = stderr
");

        var psi = new ProcessStartInfo
        {
            FileName = snapserverPath,
            Arguments = $"-c \"{configPath}\"",
            UseShellExecute = !config.Debug,
            CreateNoWindow = !config.Debug
        };

        Process.Start(psi);

        // Wait for it to be ready
        for (int i = 0; i < 10; i++)
        {
            await Task.Delay(500);
            try
            {
                using var testClient = new TcpClient();
                await testClient.ConnectAsync("localhost", config.SnapserverPort);
                Console.Error.WriteLine("[Snapserver] Ready");
                return;
            }
            catch { }
        }

        Console.Error.WriteLine("[Snapserver] WARNING: Timeout waiting for snapserver to start");
    }

    static bool IsProcessRunning(string name)
    {
        return Process.GetProcessesByName(name).Length > 0;
    }

    static string? FindSnapserver()
    {
        // Try common locations
        string[] paths = new[]
        {
            @"C:\Program Files\Snapcast\snapserver.exe",
            @"C:\Program Files (x86)\Snapcast\snapserver.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Snapcast\snapserver.exe"),
        };

        foreach (var path in paths)
        {
            if (File.Exists(path))
                return path;
        }

        // Try PATH
        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (pathEnv != null)
        {
            foreach (var dir in pathEnv.Split(';'))
            {
                string fullPath = Path.Combine(dir, "snapserver.exe");
                if (File.Exists(fullPath))
                    return fullPath;
            }
        }

        return null;
    }

    static string FindFFmpeg()
    {
        // Check local ffmpeg folder (in parent directory of project root)
        // From bin\Release\net8.0\ go up 5 levels to reach outer folder
        string[] possiblePaths = new[]
        {
            // From DLL location: src\Streaming\bin\Release\net8.0\
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\..\..\..\ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe"),
            // From project root
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe"),
            // Relative to working directory
            @"..\ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe",
            @"..\..\ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe",
        };

        foreach (var path in possiblePaths)
        {
            string fullPath = Path.GetFullPath(path);
            if (File.Exists(fullPath))
                return fullPath;
        }

        // Try ffmpeg in PATH
        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (pathEnv != null)
        {
            foreach (var dir in pathEnv.Split(';'))
            {
                string fullPath = Path.Combine(dir, "ffmpeg.exe");
                if (File.Exists(fullPath))
                    return fullPath;
            }
        }

        return "ffmpeg";
    }

    static AppConfig ParseConfig(string[] args)
    {
        var config = new AppConfig();

        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "-c":
                case "--channels":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int ch))
                    {
                        config.Channels = ch;
                        i++;
                    }
                    break;

                case "-r":
                case "--rate":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int sr))
                    {
                        config.SampleRate = sr;
                        i++;
                    }
                    break;

                case "-b":
                case "--bits":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int bd))
                    {
                        config.BitDepth = bd;
                        i++;
                    }
                    break;

                case "-h":
                case "--host":
                    if (i + 1 < args.Length)
                    {
                        config.SnapserverHost = args[i + 1];
                        i++;
                    }
                    break;

                case "-p":
                case "--port":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out int port))
                    {
                        config.SnapserverPort = port;
                        i++;
                    }
                    break;

                case "--snapserver":
                    if (i + 1 < args.Length)
                    {
                        config.SnapserverPath = args[i + 1];
                        i++;
                    }
                    break;

                case "--debug":
                    config.Debug = true;
                    break;

                case "--pipe":
                    if (i + 1 < args.Length)
                    {
                        config.PipeName = args[i + 1];
                        i++;
                    }
                    break;
            }
        }

        return config;
    }
}

class AppConfig
{
    public int Channels { get; set; } = 6;
    public int SampleRate { get; set; } = 48000;
    public int BitDepth { get; set; } = 16;
    public string SnapserverHost { get; set; } = "localhost";
    public int SnapserverPort { get; set; } = 1704;
    public string PipeName { get; set; } = "CavernPipe";
    public string? SnapserverPath { get; set; }
    public bool Debug { get; set; } = false;
}
