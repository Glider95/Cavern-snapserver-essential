using System.Text;

using Cavern;
using Cavern.Format;
using Cavern.Format.Renderers;
using Cavern.Format.Utilities;
using Cavern.Utilities;

namespace CavernPipeServer.Logic;

/// <summary>
/// Handles rendering of incoming audio content and special protocol additions/transformations.
/// </summary>
public class CavernPipeRenderer : IDisposable {
    /// <summary>
    /// Rendering of new content has started, the <see cref="Listener.Channels"/> are updated from the latest Cavern user files.
    /// </summary>
    public event Action OnRenderingStarted;

    /// <summary>
    /// Provides per-channel metering data. Channel gains are ratios between -50 and 0 dB FS.
    /// </summary>
    public delegate void OnMetersAvailable(float[] meters);

    /// <summary>
    /// New output data was rendered, audio meters can be updated. Channel gains are ratios between -50 and 0 dB FS.
    /// </summary>
    public event OnMetersAvailable MetersAvailable;

    /// <summary>
    /// Exceptions coming from the rendering thread are passed down from this event.
    /// </summary>
    public event Action<Exception> OnException;

    /// <summary>
    /// Protocol message decoder.
    /// </summary>
    public CavernPipeProtocol Protocol { get; private set; }

    /// <summary>
    /// Bytes to be processed.
    /// </summary>
    public QueueStream Input { get; private set; } = new();

    /// <summary>
    /// Bytes to send to the client.
    /// </summary>
    public QueueStream Output { get; private set; } = new();

    /// <summary>
    /// If true, the renderer needs to be manually started after the handshake is complete.
    /// This is used for file-based mode where the file path needs to be written to Input first.
    /// </summary>
    public bool NeedsManualStart { get; private set; }

    /// <summary>
    /// Handles rendering of incoming audio content and special protocol additions/transformations.
    /// </summary>
    public CavernPipeRenderer(Stream stream) {
        Protocol = new CavernPipeProtocol(stream);
        // For file-based mode, defer starting until file path is written
        if (Protocol.IsFileBasedMode) {
            NeedsManualStart = true;
        } else {
            Task.Run(RenderThread);
        }
    }

    /// <summary>
    /// Start the render thread. Must be called after the handshake is complete.
    /// For file-based mode, call this after writing the file path to Input.
    /// </summary>
    public void Start() {
        Task.Run(RenderThread);
    }

    /// <inheritdoc/>
    public void Dispose() {
        lock (Protocol) {
            Input?.Dispose();
            Output?.Dispose();
        }
        Input = null;
        Output = null;
        GC.SuppressFinalize(this);
    }

    /// <summary>
    /// Wait for enough input stream data and render the next set of samples, of which the count will be <see cref="Listener.UpdateRate"/> per channel.
    /// </summary>
    void RenderThread() {
        Console.WriteLine("[RenderThread] Starting...");
        try {
            Stream audioSource;
            int updateRate;
            
            if (Protocol.IsFileBasedMode) {
                // File-based mode: read file path from Input and open file directly
                Console.WriteLine("[RenderThread] File-based mode, reading file path...");
                audioSource = OpenFileFromPath();
                if (audioSource == null) {
                    Console.WriteLine("[RenderThread] Failed to open file, aborting.");
                    return;
                }
                updateRate = -Protocol.UpdateRate; // Use absolute value
                Console.WriteLine($"[RenderThread] File opened, updateRate={updateRate}");
            } else {
                // Streaming mode: use Input stream directly
                Console.WriteLine("[RenderThread] Streaming mode.");
                audioSource = Input;
                updateRate = Protocol.UpdateRate;
            }
            
            Console.WriteLine("[RenderThread] Opening AudioReader...");
            AudioReader reader = AudioReader.Open(audioSource);
            Console.WriteLine($"[RenderThread] AudioReader opened: {reader?.GetType().Name}");
            reader.ReadHeader(); // CRITICAL: without this, Cavern reports 0ch/0Hz
            Renderer renderer = reader.GetRenderer();
            
            // Get sample rate AFTER renderer is created
            int sampleRate = reader.SampleRate;
            if (sampleRate <= 0) sampleRate = 48000;
            
            // Configure output channel count based on client request
            if (Listener.Channels.Length != Protocol.OutputChannels) {
                Listener.ReplaceChannels(Protocol.OutputChannels);
            }
            
            Listener listener = new Listener {
                // Prevent height limiting, require at least 4 overhead channels for full gain
                Volume = renderer.HasObjects && Listener.Channels.GetOverheadChannelCount() < 4 ? .707f : 1,
                SampleRate = sampleRate,
                UpdateRate = updateRate,
                AudioQuality = QualityModes.Perfect,
            };
            OnRenderingStarted?.Invoke();

            float[] reRender = null;
            if (Listener.Channels.Length != Protocol.OutputChannels) {
                reRender = new float[Protocol.OutputChannels * updateRate];
            }
            listener.AttachSources(renderer.Objects);

            // When this writer is used without writing a header, it's a BitDepth converter from float to anything, and can dump to streams.
            RIFFWaveWriter streamDumper = new RIFFWaveWriter(Output, Protocol.OutputChannels, long.MaxValue, sampleRate, Protocol.OutputFormat);

            long samplesRendered = 0;
            long totalSamples = reader.Length;
            bool isFileBased = Protocol.IsFileBasedMode;
            
            while (Input != null) {
                float[] render = listener.Render();
                UpdateMeters(render);
                if (reRender == null) {
                    streamDumper.WriteBlock(render, 0, render.LongLength);
                } else {
                    Array.Clear(reRender);
                    WaveformUtils.Downmix(render, reRender, updateRate);
                    streamDumper.WriteBlock(reRender, 0, reRender.LongLength);
                }
                
                samplesRendered += updateRate;
                
                // For file-based mode, stop when we've rendered all samples
                if (isFileBased && samplesRendered >= totalSamples) {
                    break;
                }
            }
        } catch (Exception e) {
            Dispose();
            OnException?.Invoke(e);
        }
    }

    /// <summary>
    /// In file-based mode, read the file path from Input and open the file.
    /// </summary>
    Stream? OpenFileFromPath() {
        try {
            Console.WriteLine($"[OpenFileFromPath] Input type: {Input?.GetType().Name}, Length: {Input?.Length}");
            Console.WriteLine("[OpenFileFromPath] Waiting for data...");
            // Wait for data to be available in Input
            if (Input is Cavern.Format.Utilities.QueueStream qs) {
                qs.WaitForData();
                Console.WriteLine("[OpenFileFromPath] WaitForData returned");
            }
            
            // Read path length (4 bytes)
            byte[] lengthBytes = new byte[4];
            int read = Input.Read(lengthBytes, 0, 4);
            Console.WriteLine($"[OpenFileFromPath] Read {read} bytes for length");
            if (read < 4) return null;
            int pathLength = BitConverter.ToInt32(lengthBytes, 0);
            
            if (pathLength <= 0 || pathLength > 65535) return null;
            
            // Read path bytes
            byte[] pathBytes = new byte[pathLength];
            read = Input.Read(pathBytes, 0, pathLength);
            if (read < pathLength) return null;
            
            string filePath = Encoding.UTF8.GetString(pathBytes);
            if (!File.Exists(filePath)) return null;
            
            return File.OpenRead(filePath);
        } catch {
            return null;
        }
    }

    /// <summary>
    /// Send the <see cref="MetersAvailable"/> event with the rendered channel names and their last rendered gains.
    /// </summary>
    /// <remarks>Channel gains are ratios between -50 and 0 dB FS.</remarks>
    void UpdateMeters(float[] audioOut) {
        float[] result = new float[Listener.Channels.Length];
        for (int i = 0; i < result.Length; i++) {
            float channelGain = QMath.GainToDb(WaveformUtils.GetRMS(audioOut, i, result.Length));
            result[i] = QMath.Clamp01(QMath.LerpInverse(-50, 0, channelGain));
        }
        MetersAvailable?.Invoke(result);
    }
}
