using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace CavernSnapcastStreaming;

/// <summary>
/// A lightweight Snapserver emulator that implements enough of the Snapcast protocol
/// to work with Snapclients. This is a workaround since native Windows builds are problematic.
/// </summary>
public class SnapserverEmulator : IDisposable
{
    private TcpListener? _tcpListener;
    private HttpListener? _httpListener;
    private readonly List<TcpClient> _clients = new();
    private readonly CancellationTokenSource _cts = new();
    private Task? _tcpTask;
    private Task? _httpTask;

    public int TcpPort { get; set; } = 1704;
    public int HttpPort { get; set; } = 1780;
    public int RpcPort { get; set; } = 1705;

    // Audio configuration
    public int SampleRate { get; set; } = 48000;
    public int Channels { get; set; } = 6;
    public int BitDepth { get; set; } = 16;
    public string Codec { get; set; } = "flac";

    // Server info
    public string ServerId { get; } = Guid.NewGuid().ToString("N")[..12];
    public string ServerName { get; set; } = "CavernSnapcast";

    private readonly Queue<byte[]> _audioBuffer = new();
    private readonly object _bufferLock = new();
    private int _maxBufferSize = 100; // chunks

    public bool IsRunning => _tcpListener?.Server.IsBound ?? false;

    /// <summary>
    /// Start the emulator (TCP server for streaming + HTTP for control).
    /// </summary>
    public async Task StartAsync()
    {
        Console.WriteLine($"[SnapserverEmulator] Starting...");
        Console.WriteLine($"[SnapserverEmulator] Server ID: {ServerId}");
        Console.WriteLine($"[SnapserverEmulator] TCP Port: {TcpPort} (streaming)");
        Console.WriteLine($"[SnapserverEmulator] HTTP Port: {HttpPort} (control)");
        Console.WriteLine($"[SnapserverEmulator] RPC Port: {RpcPort} (JSON-RPC)");

        // Start TCP listener for streaming
        _tcpListener = new TcpListener(IPAddress.Any, TcpPort);
        _tcpListener.Start();
        _tcpTask = AcceptTcpClientsAsync();

        // Start HTTP listener for control interface
        _httpListener = new HttpListener();
        _httpListener.Prefixes.Add($"http://*:{HttpPort}/");
        try
        {
            _httpListener.Start();
            _httpTask = HandleHttpRequestsAsync();
        }
        catch (HttpListenerException ex)
        {
            Console.WriteLine($"[SnapserverEmulator] WARNING: HTTP listener failed: {ex.Message}");
            Console.WriteLine($"[SnapserverEmulator] Try running as Administrator or use netsh to add URL reservation:");
            Console.WriteLine($"  netsh http add urlacl url=http://*:{HttpPort}/ user=YOUR_USERNAME");
        }

        // Start RPC listener
        _ = Task.Run(HandleRpcAsync);

        Console.WriteLine($"[SnapserverEmulator] Ready!");
    }

    /// <summary>
    /// Accept incoming TCP connections (Snapclients).
    /// </summary>
    private async Task AcceptTcpClientsAsync()
    {
        while (!_cts.Token.IsCancellationRequested)
        {
            try
            {
                var client = await _tcpListener!.AcceptTcpClientAsync();
                lock (_clients)
                {
                    _clients.Add(client);
                }
                Console.WriteLine($"[SnapserverEmulator] Client connected: {client.Client.RemoteEndPoint}");
                Console.WriteLine($"[SnapserverEmulator] Total clients: {_clients.Count}");
                
                _ = HandleClientAsync(client);
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[SnapserverEmulator] Accept error: {ex.Message}");
            }
        }
    }

    /// <summary>
    /// Handle a connected Snapclient.
    /// </summary>
    private async Task HandleClientAsync(TcpClient client)
    {
        try
        {
            using var stream = client.GetStream();
            
            // Send hello message
            await SendHelloAsync(stream);
            
            // Send codec header
            await SendCodecHeaderAsync(stream);
            
            // Start streaming audio
            await StreamAudioAsync(stream, client);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[SnapserverEmulator] Client handler error: {ex.Message}");
        }
        finally
        {
            lock (_clients)
            {
                _clients.Remove(client);
            }
            client.Close();
            Console.WriteLine($"[SnapserverEmulator] Client disconnected. Total: {_clients.Count}");
        }
    }

    /// <summary>
    /// Send Snapcast "hello" message.
    /// </summary>
    private async Task SendHelloAsync(NetworkStream stream)
    {
        var hello = new
        {
            id = ServerId,
            name = ServerName,
            version = "0.27.0",  // Pretend to be recent version
            protocol_version = 2
        };
        
        var json = JsonSerializer.Serialize(hello);
        var data = Encoding.UTF8.GetBytes(json);
        
        // Snapcast wire format: type(2) + size(4) + data
        var message = new byte[6 + data.Length];
        BitConverter.GetBytes((ushort)0).CopyTo(message, 0); // type 0 = server settings
        BitConverter.GetBytes((uint)data.Length).CopyTo(message, 2);
        data.CopyTo(message, 6);
        
        await stream.WriteAsync(message);
        Console.WriteLine($"[SnapserverEmulator] Sent hello to client");
    }

    /// <summary>
    /// Send codec header to client.
    /// </summary>
    private async Task SendCodecHeaderAsync(NetworkStream stream)
    {
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        string codec = Codec;
        byte[] codecBytes = Encoding.UTF8.GetBytes(codec);

        // Base message header
        uint msgSize = (uint)(26 + codecBytes.Length + 8);
        
        writer.Write((ushort)0);           // type: codec header
        writer.Write(msgSize);             // size
        writer.Write((uint)0);             // received secs
        writer.Write((uint)0);             // received usecs
        writer.Write((uint)0);             // remote timestamp

        // Codec header
        writer.Write((uint)codecBytes.Length);
        writer.Write(codecBytes);

        // PCM header
        writer.Write((uint)SampleRate);
        writer.Write((ushort)BitDepth);
        writer.Write((ushort)Channels);

        await stream.WriteAsync(ms.ToArray());
        Console.WriteLine($"[SnapserverEmulator] Sent codec header: {codec}, {SampleRate}Hz, {Channels}ch");
    }

    /// <summary>
    /// Stream audio chunks to client.
    /// </summary>
    private async Task StreamAudioAsync(NetworkStream stream, TcpClient client)
    {
        byte[]? lastChunk = null;
        
        while (!_cts.Token.IsCancellationRequested && client.Connected)
        {
            byte[]? chunk = null;
            
            lock (_bufferLock)
            {
                if (_audioBuffer.Count > 0)
                {
                    chunk = _audioBuffer.Dequeue();
                }
            }

            if (chunk != null)
            {
                lastChunk = chunk;
                await SendWireChunkAsync(stream, chunk);
            }
            else if (lastChunk != null)
            {
                // Send silence or repeat last chunk to keep connection alive
                await Task.Delay(20);
            }
            else
            {
                await Task.Delay(10);
            }
        }
    }

    /// <summary>
    /// Send a wire chunk (audio data).
    /// </summary>
    private async Task SendWireChunkAsync(NetworkStream stream, byte[] data)
    {
        using var ms = new MemoryStream();
        using var writer = new BinaryWriter(ms);

        long timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        
        writer.Write((ushort)1);           // type: wire chunk
        writer.Write((uint)data.Length);   // size
        writer.Write((uint)(timestamp / 1000));    // secs
        writer.Write((uint)((timestamp % 1000) * 1000)); // usecs

        await stream.WriteAsync(ms.ToArray());
        await stream.WriteAsync(data);
    }

    /// <summary>
    /// Add audio data to be streamed to all clients.
    /// </summary>
    public void StreamAudio(byte[] data)
    {
        lock (_bufferLock)
        {
            if (_audioBuffer.Count >= _maxBufferSize)
            {
                _audioBuffer.Dequeue(); // Drop oldest
            }
            _audioBuffer.Enqueue(data);
        }
    }

    /// <summary>
    /// Handle HTTP control requests.
    /// </summary>
    private async Task HandleHttpRequestsAsync()
    {
        while (!_cts.Token.IsCancellationRequested)
        {
            try
            {
                var context = await _httpListener!.GetContextAsync();
                _ = Task.Run(() => ProcessHttpRequest(context));
            }
            catch (HttpListenerException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
        }
    }

    private void ProcessHttpRequest(HttpListenerContext context)
    {
        var request = context.Request;
        var response = context.Response;

        try
        {
            if (request.Url?.AbsolutePath == "/jsonrpc")
            {
                // Handle JSON-RPC
                response.ContentType = "application/json";
                var result = JsonSerializer.Serialize(new { result = "ok" });
                var buffer = Encoding.UTF8.GetBytes(result);
                response.OutputStream.Write(buffer, 0, buffer.Length);
            }
            else if (request.Url?.AbsolutePath == "/")
            {
                // Status page
                response.ContentType = "text/html";
                var html = $@"
<!DOCTYPE html>
<html>
<head><title>CavernSnapcast</title></head>
<body>
<h1>CavernSnapcast Server</h1>
<p>Server ID: {ServerId}</p>
<p>Connected clients: {_clients.Count}</p>
<p>Format: {Channels}ch @ {SampleRate}Hz</p>
</body>
</html>";
                var buffer = Encoding.UTF8.GetBytes(html);
                response.OutputStream.Write(buffer, 0, buffer.Length);
            }
            else
            {
                response.StatusCode = 404;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[SnapserverEmulator] HTTP error: {ex.Message}");
            response.StatusCode = 500;
        }
        finally
        {
            response.Close();
        }
    }

    /// <summary>
    /// Handle JSON-RPC control interface.
    /// </summary>
    private async Task HandleRpcAsync()
    {
        var listener = new TcpListener(IPAddress.Any, RpcPort);
        listener.Start();
        Console.WriteLine($"[SnapserverEmulator] RPC listening on port {RpcPort}");

        while (!_cts.Token.IsCancellationRequested)
        {
            try
            {
                var client = await listener.AcceptTcpClientAsync();
                _ = HandleRpcClientAsync(client);
            }
            catch { break; }
        }
    }

    private async Task HandleRpcClientAsync(TcpClient client)
    {
        using var stream = client.GetStream();
        using var reader = new StreamReader(stream);
        using var writer = new StreamWriter(stream) { AutoFlush = true };

        while (!_cts.Token.IsCancellationRequested && client.Connected)
        {
            try
            {
                var line = await reader.ReadLineAsync();
                if (line == null) break;

                // Simple RPC responses
                var response = JsonSerializer.Serialize(new
                {
                    id = 1,
                    jsonrpc = "2.0",
                    result = new { }
                });
                await writer.WriteLineAsync(response);
            }
            catch { break; }
        }
    }

    public void Stop()
    {
        _cts.Cancel();
        
        lock (_clients)
        {
            foreach (var client in _clients)
            {
                client.Close();
            }
            _clients.Clear();
        }

        _tcpListener?.Stop();
        _httpListener?.Stop();
    }

    public void Dispose()
    {
        Stop();
        _cts.Dispose();
    }
}
