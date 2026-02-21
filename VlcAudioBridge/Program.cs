using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VlcAudioBridge;

/// <summary>
/// Bridges audio from any media player (VLC, etc.) to Cavern pipeline
/// Uses WASAPI loopback capture to grab system audio output
/// </summary>
class Program
{
    private static WasapiLoopbackCapture? _capture;
    private static NamedPipeClientStream? _pipeClient;
    private static BinaryWriter? _pipeWriter;
    private static bool _isRunning = false;
    private static string _pipeName = "CavernAudioPipe";
    private static string _configPath = "speaker-config.json";

    static async Task Main(string[] args)
    {
        Console.WriteLine("╔══════════════════════════════════════════════════════════════╗");
        Console.WriteLine("║         Cavern VLC Audio Bridge v1.0                         ║");
        Console.WriteLine("║  Capture audio from VLC/Media Player → Cavern → Snapcast    ║");
        Console.WriteLine("╚══════════════════════════════════════════════════════════════╝");
        Console.WriteLine();

        // Parse arguments
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--pipe":
                case "-p":
                    if (i + 1 < args.Length) _pipeName = args[++i];
                    break;
                case "--config":
                case "-c":
                    if (i + 1 < args.Length) _configPath = args[++i];
                    break;
                case "--help":
                case "-h":
                    ShowHelp();
                    return;
            }
        }

        Console.WriteLine($"Target Pipe: {_pipeName}");
        Console.WriteLine($"Config File: {_configPath}");
        Console.WriteLine();

        // Show available audio devices
        ShowAudioDevices();
        Console.WriteLine();

        try
        {
            await StartAudioCaptureAsync();
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"Error: {ex.Message}");
            Console.ResetColor();
            Environment.Exit(1);
        }
    }

    static void ShowHelp()
    {
        Console.WriteLine("Usage: VlcAudioBridge [options]");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  -p, --pipe <name>      Named pipe to send audio to (default: CavernAudioPipe)");
        Console.WriteLine("  -c, --config <path>    Speaker configuration file (default: speaker-config.json)");
        Console.WriteLine("  -h, --help              Show this help message");
        Console.WriteLine();
        Console.WriteLine("Examples:");
        Console.WriteLine("  VlcAudioBridge                          # Use defaults");
        Console.WriteLine("  VlcAudioBridge -p MyPipe -c config.json # Custom pipe and config");
        Console.WriteLine();
        Console.WriteLine("Integration with VLC:");
        Console.WriteLine("  1. Start this bridge");
        Console.WriteLine("  2. Play any Dolby Atmos file in VLC");
        Console.WriteLine("  3. Audio is automatically captured and sent to Cavern");
        Console.WriteLine();
        Console.WriteLine("The bridge captures system audio using WASAPI loopback.");
    }

    static void ShowAudioDevices()
    {
        Console.WriteLine("Available Audio Output Devices:");
        Console.WriteLine("─────────────────────────────────");
        
        var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        
        int index = 0;
        foreach (var device in devices)
        {
            var isDefault = device.ID == enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
            Console.WriteLine($"  {(isDefault ? "*" : " ")} [{index}] {device.FriendlyName}");
            index++;
        }
        
        Console.WriteLine();
        Console.WriteLine("(*) Default device - audio will be captured from here");
    }

    static async Task StartAudioCaptureAsync()
    {
        Console.WriteLine("Connecting to Cavern pipe...");
        
        // Connect to the named pipe
        _pipeClient = new NamedPipeClientStream(".", _pipeName, 
            PipeDirection.Out, PipeOptions.Asynchronous);
        
        try
        {
            await _pipeClient.ConnectAsync(5000);
            _pipeWriter = new BinaryWriter(_pipeClient);
            Console.WriteLine("✓ Connected to Cavern pipeline");
        }
        catch (TimeoutException)
        {
            Console.WriteLine("⚠ Could not connect to Cavern pipe. Starting in test mode...");
            Console.WriteLine("  (Audio will be captured but not sent to Cavern)");
        }

        Console.WriteLine();
        Console.WriteLine("Starting audio capture...");
        Console.WriteLine("Press Ctrl+C to stop");
        Console.WriteLine();

        // Setup WASAPI loopback capture
        _capture = new WasapiLoopbackCapture();
        
        // Log audio format
        Console.WriteLine($"Capture Format: {_capture.WaveFormat}");
        Console.WriteLine($"  Sample Rate: {_capture.WaveFormat.SampleRate} Hz");
        Console.WriteLine($"  Channels: {_capture.WaveFormat.Channels}");
        Console.WriteLine($"  Bits: {_capture.WaveFormat.BitsPerSample}");
        Console.WriteLine();

        // Handle audio data
        _capture.DataAvailable += (sender, e) =>
        {
            if (e.BytesRecorded > 0)
            {
                // Send to pipe if connected
                if (_pipeClient?.IsConnected == true && _pipeWriter != null)
                {
                    try
                    {
                        _pipeWriter.Write(e.BytesRecorded);
                        _pipeWriter.Write(e.Buffer, 0, e.BytesRecorded);
                        _pipeWriter.Flush();
                    }
                    catch (IOException)
                    {
                        // Pipe disconnected
                        Console.WriteLine("⚠ Cavern pipe disconnected");
                    }
                }

                // Also write to debug file if DEBUG env var is set
                if (Environment.GetEnvironmentVariable("VAB_DEBUG") == "1")
                {
                    DebugWrite(e.Buffer, e.BytesRecorded);
                }
            }
        };

        _capture.RecordingStopped += (sender, e) =>
        {
            Console.WriteLine("Recording stopped");
            _isRunning = false;
        };

        // Start capturing
        _capture.StartRecording();
        _isRunning = true;

        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine("✓ Audio capture active - Play something in VLC!");
        Console.ResetColor();
        Console.WriteLine();

        // Wait for Ctrl+C
        var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (sender, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
        };

        try
        {
            await Task.Delay(-1, cts.Token);
        }
        catch (TaskCanceledException)
        {
            // Expected on Ctrl+C
        }

        // Cleanup
        Console.WriteLine();
        Console.WriteLine("Shutting down...");
        StopCapture();
    }

    static void StopCapture()
    {
        _capture?.StopRecording();
        _capture?.Dispose();
        _pipeWriter?.Close();
        _pipeClient?.Close();
        
        Console.WriteLine("✓ Audio bridge stopped");
    }

    private static FileStream? _debugStream;
    private static BinaryWriter? _debugWriter;
    private static readonly object _debugLock = new();

    static void DebugWrite(byte[] buffer, int bytesRecorded)
    {
        lock (_debugLock)
        {
            if (_debugStream == null)
            {
                _debugStream = new FileStream("audio-debug.raw", FileMode.Create);
                _debugWriter = new BinaryWriter(_debugStream);
            }
            
            _debugWriter?.Write(buffer, 0, bytesRecorded);
            _debugWriter?.Flush();
        }
    }
}
