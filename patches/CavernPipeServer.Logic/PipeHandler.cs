using System.IO.Pipes;

using Cavern.Format.Utilities;

namespace CavernPipeServer.Logic;

/// <summary>
/// Handles the network communication of CavernPipe. A watchdog for a self-created named pipe called &quot;CavernPipe&quot;.
/// </summary>
public class PipeHandler : IDisposable {
    /// <summary>
    /// Rendering of new content has started, the <see cref="Listener.Channels"/> are updated from the latest Cavern user files.
    /// </summary>
    public event Action OnRenderingStarted;

    /// <summary>
    /// Either the <see cref="Running"/> or <see cref="IsConnected"/> status have changed.
    /// </summary>
    public event Action StatusChanged;

    /// <summary>
    /// Allows subscribing to <see cref="CavernPipeRenderer.MetersAvailable"/>.
    /// </summary>
    public event CavernPipeRenderer.OnMetersAvailable MetersAvailable;

    /// <summary>
    /// Exceptions coming from the named pipe or the rendering thread are passed down from this event.
    /// </summary>
    public event Action<Exception> OnException;

    /// <summary>
    /// The network connection is kept alive.
    /// </summary>
    public bool Running {
        get => running;
        set {
            running = value;
            StatusChanged?.Invoke();
        }
    }
    bool running;

    /// <summary>
    /// A client is connected to the server.
    /// </summary>
    public bool IsConnected {
        get => isConnected;
        set {
            isConnected = value;
            StatusChanged?.Invoke();
        }
    }
    bool isConnected;

    /// <summary>
    /// Used for providing thread safety.
    /// </summary>
    readonly object locker = new object();

    /// <summary>
    /// A thread that keeps the named pipe active in a loop - if the pipe was closed by a client and CavernPipe is still <see cref="Running"/>,
    /// the named pipe is recreated, waiting for the next application to connect to CavernPipe.
    /// </summary>
    Thread thread;

    /// <summary>
    /// Cancels waiting for a player/consumer when quitting the application.
    /// </summary>
    CancellationTokenSource canceler;

    /// <summary>
    /// Network endpoint instance.
    /// </summary>
    NamedPipeServerStream server;

    /// <summary>
    /// Handles the network communication of CavernPipe. A watchdog for a self-created named pipe called &quot;CavernPipe&quot;.
    /// </summary>
    public PipeHandler() => Start();

    /// <summary>
    /// Start the named pipe watchdog. If it's already running, an <see cref="InvalidOperationException"/> is thrown.
    /// </summary>
    public void Start() {
        lock (locker) {
            if (Running) {
                throw new CavernPipeAlreadyRunningException(server == null);
            }
            canceler = new CancellationTokenSource();
            thread = new Thread(ThreadProc);
            thread.Start();
            Running = true;
        }
    }

    /// <summary>
    /// Stop keeping the named pipe alive.
    /// </summary>
    public void Dispose() {
        lock (locker) {
            Running = false;
            if (server != null) {
                if (server.IsConnected) {
                    server.Close();
                } else {
                    canceler.Cancel();
                }
            }
        }
        thread.Join();
        canceler.Dispose();
        GC.SuppressFinalize(this);
    }

    /// <summary>
    /// Watchdog for the CavernPipe named pipe. Allows a single instance of this named pipe to exist.
    /// </summary>
    async void ThreadProc() {
        while (Running) {
            try {
                TryStartServer();
                await server.WaitForConnectionAsync(canceler.Token);
                IsConnected = true;
                using CavernPipeRenderer renderer = new CavernPipeRenderer(server);
                renderer.OnRenderingStarted += OnRenderingStarted;
                renderer.MetersAvailable += MetersAvailable;
                renderer.OnException += OnException;

                // Handle file-based mode: read file path from client
                Console.WriteLine($"[PipeHandler] FileBasedMode={renderer.Protocol.IsFileBasedMode}, UpdateRate={renderer.Protocol.UpdateRate}");
                if (renderer.Protocol.IsFileBasedMode) {
                    Console.WriteLine("[PipeHandler] Entering file-based mode handling...");
                    int pathLength = server.ReadInt32();
                    Console.WriteLine($"[PipeHandler] Path length: {pathLength}");
                    if (pathLength <= 0 || pathLength > 65535) {
                        throw new InvalidDataException($"Invalid file path length: {pathLength}");
                    }
                    byte[] pathBytes = new byte[pathLength];
                    ReadAll(pathBytes, pathLength);
                    Console.WriteLine($"[PipeHandler] Read path bytes: {pathBytes.Length}");
                    // Write both length and path to Input so CavernPipeRenderer can read it
                    renderer.Input.Write(BitConverter.GetBytes(pathLength), 0, 4);
                    renderer.Input.Write(pathBytes, 0, pathLength);
                    // DO NOT call Flush() - it clears the queue in QueueStream!
                    Console.WriteLine("[PipeHandler] Wrote to Input, calling Start()...");
                    
                    // Now safe to start rendering (file path is in Input)
                    renderer.Start();
                    
                    // Wait a bit for renderer to start
                    await Task.Delay(100, canceler.Token);
                    
                    // For file-based mode, just pump output to client until renderer is done
                    await PumpOutputToClient(renderer, canceler.Token);
                    continue; // Go to next connection
                }

                byte[] inBuffer = [],
                    outBuffer = [];
                while (Running) {
                    int length = server.ReadInt32();
                    if (inBuffer.Length < length) {
                        inBuffer = new byte[length];
                    }
                    ReadAll(inBuffer, length);
                    renderer.Input.Write(inBuffer, 0, length);

                    while (renderer.Output.Length < renderer.Protocol.MandatoryBytesToSend) {
                        // Wait until mandatory frames are rendered or pipe is closed
                    }
                    length = (int)renderer.Output.Length;
                    if (outBuffer.Length < length) {
                        outBuffer = new byte[length];
                    }
                    renderer.Output.Read(outBuffer, 0, length);
                    server.Write(BitConverter.GetBytes(length));
                    server.Write(outBuffer, 0, length);
                }
            } catch (TimeoutException) {
                OnException?.Invoke(new CavernPipeLaunchTimeoutException());
                return;
            } catch (Exception e) { // Content type change or server/stream closed
                OnException?.Invoke(e);
            }

            IsConnected = false;
            lock (locker) {
                if (server.IsConnected) {
                    server.Flush();
                }
                server.Dispose();
                server = null;
            }
        }
    }

    /// <summary>
    /// For file-based mode: continuously pump rendered output to client until done.
    /// Uses chunked transfers with flow control to prevent client buffer overrun.
    /// </summary>
    async Task PumpOutputToClient(CavernPipeRenderer renderer, CancellationToken ct) {
        const int MaxChunkSize = 65536; // 64KB max per chunk
        byte[] outBuffer = new byte[MaxChunkSize];
        try {
            while (Running && !ct.IsCancellationRequested) {
                // Wait for output to be available
                await Task.Delay(5, ct);
                
                if (renderer?.Output == null) break;
                
                long available = renderer.Output.Length;
                if (available == 0) {
                    // Check if renderer is done
                    if (renderer.Input == null) break;
                    continue;
                }
                
                // Send data in smaller chunks to prevent client overrun
                while (available > 0 && Running) {
                    int chunkSize = (int)Math.Min(available, MaxChunkSize);
                    renderer.Output.Read(outBuffer, 0, chunkSize);
                    
                    // Send to client
                    if (server?.IsConnected == true) {
                        await server.WriteAsync(BitConverter.GetBytes(chunkSize), 0, 4, ct);
                        await server.WriteAsync(outBuffer, 0, chunkSize, ct);
                        await server.FlushAsync(ct);
                    } else {
                        return;
                    }
                    
                    available -= chunkSize;
                    
                    // Small delay between chunks to let client process
                    if (available > 0) {
                        await Task.Delay(1, ct);
                    }
                }
            }
            
            // Send end-of-stream marker
            if (server?.IsConnected == true) {
                await server.WriteAsync(BitConverter.GetBytes(0), 0, 4, ct);
                await server.FlushAsync(ct);
            }
        } catch (Exception e) {
            OnException?.Invoke(e);
        }
    }

    /// <summary>
    /// Try to open the CavernPipe and assign the <see cref="server"/> variable if it was successful. If not, the thread stops,
    /// and the user gets a message that it should be restarted.
    /// </summary>
    void TryStartServer() {
        DateTime tryUntil = DateTime.Now + TimeSpan.FromSeconds(timeout);
        while (DateTime.Now < tryUntil) {
            try {
                server = new NamedPipeServerStream("CavernPipe");
                return;
            } catch {
                server = null;
            }
        }
        Running = false;
        throw new TimeoutException();
    }

    /// <summary>
    /// Read a specific number of bytes from the stream or throw an <see cref="EndOfStreamException"/> if it was closed midway.
    /// </summary>
    void ReadAll(byte[] buffer, int length) {
        int read = 0;
        while (read < length) {
            if (server.IsConnected) {
                read += server.Read(buffer, read, length - read);
            } else {
                throw new EndOfStreamException();
            }
        }
    }

    /// <summary>
    /// Number of seconds to allow for starting the pipe.
    /// </summary>
    internal const int timeout = 3;
}
