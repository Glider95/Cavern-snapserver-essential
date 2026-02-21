using System.IO.Pipes;
using System.IO;

namespace CavernSnapcastStreaming;

/// <summary>
/// Windows Named Pipe server that emulates CavernPipeServer behavior.
/// Accepts audio from CavernPipeClient and outputs rendered PCM.
/// </summary>
public class NamedPipeServer : IDisposable
{
    private NamedPipeServerStream? _pipeServer;
    private readonly string _pipeName;
    private readonly CancellationTokenSource _cts = new();
    private Task? _listenerTask;

    // Audio format configuration
    public int OutputChannels { get; set; } = 6;
    public int SampleRate { get; set; } = 48000;
    public int BitDepth { get; set; } = 16;
    public int UpdateRate { get; set; } = 1024;

    // Events
    public event EventHandler<AudioDataEventArgs>? AudioDataReceived;
    public event EventHandler<HandshakeEventArgs>? HandshakeReceived;
    public event EventHandler? ClientConnected;
    public event EventHandler? ClientDisconnected;

    public NamedPipeServer(string pipeName = "CavernPipe")
    {
        _pipeName = pipeName;
    }

    /// <summary>
    /// Start listening for CavernPipeClient connections.
    /// </summary>
    public async Task StartAsync()
    {
        Console.Error.WriteLine($"[NamedPipeServer] Starting server on pipe: {_pipeName}");
        
        _listenerTask = Task.Run(async () =>
        {
            while (!_cts.Token.IsCancellationRequested)
            {
                try
                {
                    _pipeServer = new NamedPipeServerStream(
                        _pipeName,
                        PipeDirection.InOut,
                        1,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);

                    Console.Error.WriteLine($"[NamedPipeServer] Waiting for client connection...");
                    await _pipeServer.WaitForConnectionAsync(_cts.Token);
                    
                    Console.Error.WriteLine("[NamedPipeServer] Client connected");
                    ClientConnected?.Invoke(this, EventArgs.Empty);
                    
                    await HandleClientAsync(_pipeServer);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (IOException ex)
                {
                    Console.Error.WriteLine($"[NamedPipeServer] Client disconnected: {ex.Message}");
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[NamedPipeServer] Error: {ex.Message}");
                }
                finally
                {
                    ClientDisconnected?.Invoke(this, EventArgs.Empty);
                    _pipeServer?.Dispose();
                    _pipeServer = null;
                }
            }
        });

        await Task.CompletedTask;
    }

    /// <summary>
    /// Handle the client protocol: handshake then data exchange.
    /// </summary>
    private async Task HandleClientAsync(NamedPipeServerStream pipe)
    {
        // Read handshake (8 bytes)
        byte[] handshake = new byte[8];
        int read = await ReadExactlyAsync(pipe, handshake, 8);
        
        if (read < 8)
        {
            Console.Error.WriteLine("[NamedPipeServer] Incomplete handshake");
            return;
        }

        // Parse handshake
        byte bitDepth = handshake[0];
        byte mandatoryFrames = handshake[1];
        ushort channels = BitConverter.ToUInt16(handshake, 2);
        int updateRate = BitConverter.ToInt32(handshake, 4);

        Console.Error.WriteLine($"[NamedPipeServer] Handshake: depth={bitDepth}, frames={mandatoryFrames}, ch={channels}, rate={updateRate}");
        
        // Check for file-based mode (negative updateRate)
        bool fileBasedMode = updateRate < 0;
        if (fileBasedMode)
        {
            Console.Error.WriteLine("[NamedPipeServer] File-based mode detected");
            await HandleFileBasedModeAsync(pipe);
        }
        else
        {
            HandshakeReceived?.Invoke(this, new HandshakeEventArgs
            {
                BitDepth = bitDepth,
                MandatoryFrames = mandatoryFrames,
                Channels = channels,
                UpdateRate = updateRate
            });
            await HandleStreamingModeAsync(pipe);
        }
    }

    /// <summary>
    /// File-based mode: receive file path, read/process audio file.
    /// </summary>
    private async Task HandleFileBasedModeAsync(NamedPipeServerStream pipe)
    {
        // Read path length (4 bytes)
        byte[] lengthBytes = new byte[4];
        await ReadExactlyAsync(pipe, lengthBytes, 4);
        int pathLength = BitConverter.ToInt32(lengthBytes, 0);

        // Read path
        byte[] pathBytes = new byte[pathLength];
        await ReadExactlyAsync(pipe, pathBytes, pathLength);
        string filePath = System.Text.Encoding.UTF8.GetString(pathBytes);

        Console.Error.WriteLine($"[NamedPipeServer] File path: {filePath}");

        if (!File.Exists(filePath))
        {
            Console.Error.WriteLine($"[NamedPipeServer] ERROR: File not found: {filePath}");
            await SendPcmChunkAsync(pipe, Array.Empty<byte>()); // Signal EOF
            return;
        }

        // In a real implementation, this would decode the audio file
        // and stream PCM back. For now, we simulate the response.
        await SimulateAudioPlaybackAsync(pipe, filePath);
    }

    /// <summary>
    /// Streaming mode: receive audio chunks, process, return PCM.
    /// </summary>
    private async Task HandleStreamingModeAsync(NamedPipeServerStream pipe)
    {
        byte[] lengthBuffer = new byte[4];
        byte[] audioBuffer = new byte[65536];
        int chunkCount = 0;

        try
        {
            while (!_cts.Token.IsCancellationRequested)
            {
                // Read chunk length
                int read = await ReadExactlyAsync(pipe, lengthBuffer, 4);
                if (read < 4) break;

                int chunkLength = BitConverter.ToInt32(lengthBuffer, 0);
                if (chunkLength < 0 || chunkLength > audioBuffer.Length)
                {
                    Console.Error.WriteLine($"[NamedPipeServer] Invalid chunk length: {chunkLength}");
                    break;
                }

                if (chunkLength == 0) continue;

                // Read audio data
                if (chunkLength > audioBuffer.Length)
                {
                    audioBuffer = new byte[chunkLength];
                }

                read = await ReadExactlyAsync(pipe, audioBuffer, chunkLength);
                if (read < chunkLength)
                {
                    Console.Error.WriteLine($"[NamedPipeServer] Short read: {read}/{chunkLength}");
                    break;
                }

                chunkCount++;

                // Extract the actual audio data
                byte[] audioData = new byte[chunkLength];
                Buffer.BlockCopy(audioBuffer, 0, audioData, 0, chunkLength);

                // Raise event for processing
                var args = new AudioDataEventArgs { AudioData = audioData };
                AudioDataReceived?.Invoke(this, args);

                // Return processed PCM (echo back for now, or use processed data)
                byte[] pcmData = args.ProcessedPcm ?? audioData;
                await SendPcmChunkAsync(pipe, pcmData);
            }
        }
        catch (IOException)
        {
            // Client disconnected
        }

        Console.Error.WriteLine($"[NamedPipeServer] Processed {chunkCount} chunks");
    }

    /// <summary>
    /// Simulate audio file playback by reading and streaming PCM.
    /// </summary>
    private async Task SimulateAudioPlaybackAsync(NamedPipeServerStream pipe, string filePath)
    {
        // In a real implementation, use FFmpeg or Cavern to decode the file
        // For demonstration, we'll simulate by sending some PCM data
        
        const int chunkSize = 4096;
        byte[] pcmChunk = new byte[chunkSize];
        Random rnd = new();
        int totalChunks = 0;
        long fileSize = new FileInfo(filePath).Length;
        long estimatedChunks = fileSize / 100; // Rough estimate

        Console.Error.WriteLine($"[NamedPipeServer] Streaming file ({fileSize} bytes, ~{estimatedChunks} chunks)...");

        // Simulate streaming the file
        for (int i = 0; i < estimatedChunks && !_cts.Token.IsCancellationRequested; i++)
        {
            // Generate some dummy PCM data (in real impl, this would be actual decoded audio)
            rnd.NextBytes(pcmChunk);
            
            await SendPcmChunkAsync(pipe, pcmChunk);
            totalChunks++;

            // Simulate real-time streaming
            await Task.Delay(20);
        }

        // Send EOF marker
        await SendPcmChunkAsync(pipe, Array.Empty<byte>());
        Console.Error.WriteLine($"[NamedPipeServer] Finished streaming {totalChunks} chunks");
    }

    /// <summary>
    /// Send PCM chunk to client.
    /// </summary>
    private async Task SendPcmChunkAsync(NamedPipeServerStream pipe, byte[] pcmData)
    {
        byte[] lengthPrefix = BitConverter.GetBytes(pcmData.Length);
        await pipe.WriteAsync(lengthPrefix, 0, 4);
        if (pcmData.Length > 0)
        {
            await pipe.WriteAsync(pcmData, 0, pcmData.Length);
        }
        await pipe.FlushAsync();
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
        _pipeServer?.Disconnect();
    }

    public void Dispose()
    {
        Stop();
        _cts.Dispose();
        _pipeServer?.Dispose();
    }
}

public class AudioDataEventArgs : EventArgs
{
    public byte[] AudioData { get; set; } = Array.Empty<byte>();
    public byte[]? ProcessedPcm { get; set; }
}

public class HandshakeEventArgs : EventArgs
{
    public byte BitDepth { get; set; }
    public byte MandatoryFrames { get; set; }
    public ushort Channels { get; set; }
    public int UpdateRate { get; set; }
}
