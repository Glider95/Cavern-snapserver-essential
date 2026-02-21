using System.IO.Pipes;

namespace PipeToFifo;

/// <summary>
/// Bridges processed PCM audio from CavernPipeClient stdout to Snapserver FIFO.
/// This is a simple stdin to file bridge.
/// </summary>
class Program
{
    const int BufferSize = 8192;

    static async Task Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: PipeToFifo <fifo_path>");
            Console.Error.WriteLine("Reads PCM from stdin and writes to the specified FIFO.");
            Environment.Exit(1);
        }

        string fifoPath = args[0];
        Console.Error.WriteLine($"[PipeToFifo] Writing stdin to FIFO: {fifoPath}");

        try
        {
            // Wait for FIFO to exist (Snapserver creates it or we create it via mkfifo)
            int attempts = 0;
            while (!File.Exists(fifoPath) && attempts < 30)
            {
                await Task.Delay(100);
                attempts++;
            }

            if (!File.Exists(fifoPath))
            {
                Console.Error.WriteLine($"[PipeToFifo] ERROR: FIFO not found: {fifoPath}");
                Environment.Exit(1);
            }

            Console.Error.WriteLine("[PipeToFifo] Opening FIFO for writing...");
            // Open FIFO - this will block until Snapserver opens it for reading
            using var fifo = new FileStream(fifoPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            Console.Error.WriteLine("[PipeToFifo] FIFO opened, starting data transfer...");

            using var stdin = Console.OpenStandardInput();
            byte[] buffer = new byte[BufferSize];
            long totalBytes = 0;
            int readCount = 0;

            while (true)
            {
                int bytesRead = await stdin.ReadAsync(buffer, 0, buffer.Length);
                if (bytesRead <= 0)
                {
                    Console.Error.WriteLine($"[PipeToFifo] stdin closed after {totalBytes} bytes ({readCount} reads).");
                    break;
                }

                await fifo.WriteAsync(buffer, 0, bytesRead);
                await fifo.FlushAsync();
                totalBytes += bytesRead;
                readCount++;

                // Log first chunk for debugging
                if (readCount == 1)
                {
                    Console.Error.WriteLine($"[PipeToFifo] First chunk: {bytesRead} bytes");
                    Console.Error.WriteLine($"[PipeToFifo] First 16 bytes: {BitConverter.ToString(buffer, 0, Math.Min(16, bytesRead))}");
                }

                // Log progress every 1MB
                if (totalBytes % 1_000_000 < BufferSize)
                {
                    Console.Error.WriteLine($"[PipeToFifo] Progress: {totalBytes / 1_000_000} MB transferred");
                }
            }

            Console.Error.WriteLine($"[PipeToFifo] Transfer complete: {totalBytes} total bytes");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[PipeToFifo] ERROR: {ex.Message}");
            Environment.Exit(1);
        }
    }
}
