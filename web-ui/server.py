#!/usr/bin/env python3
"""
CavernPipe Web UI Server - Enhanced Version
Integrates cavern-wireless.sh features: codec detection, TrueHD conversion, caching, streaming
"""

import os
import sys
import json
import subprocess
import signal
import psutil
import time
import hashlib
import threading
import shutil
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional, Dict, List, Tuple
from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Configuration
PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
LOG_DIR = PROJECT_ROOT / "logs"
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
BIN_DIR = PROJECT_ROOT / "bin"
FIFO_PATH = "/tmp/snapcast-out"
CACHE_DIR = Path.home() / ".cavern-wireless" / "cache"

# Ensure cache directory exists
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Process tracking
pipeline_processes = {
    'cavern': None,
    'snapserver': None,
    'playback': None,
    'streaming': None
}

# Thread locks
log_lock = threading.Lock()
metrics_lock = threading.Lock()
playback_lock = threading.Lock()

# Log buffer
log_buffer = []
MAX_LOG_LINES = 1000

# Metrics tracking
metrics_data = {
    'bytes_streamed': 0,
    'last_bytes': 0,
    'last_check_time': datetime.now(),
    'speed_mbps': 0.0,
    'buffer_size_bytes': 0,
    'buffer_percent': 0,
    'active_streams': 0,
    'current_file': None,
    'playback_state': 'idle',  # idle, playing, paused, converting
    'conversion_progress': 0
}

# Current configuration
CURRENT_CONFIG = {
    'output_channels': 6,
    'sample_rate': 48000,
    'bit_depth': 16,
    'buffer_ms': 2000,
    'latency_ms': 100,
    'codec': 'flac',
    'chunk_ms': 60
}


@dataclass
class AudioFileInfo:
    """Information about an audio file"""
    path: str
    codec: str
    channels: int
    sample_rate: int
    duration: float
    hash: str
    cached_damf: Optional[str] = None
    
    def to_dict(self):
        return asdict(self)


def log(message: str, level: str = 'info'):
    """Add log entry"""
    entry = {
        'time': datetime.now().isoformat(),
        'level': level,
        'message': message
    }
    with log_lock:
        log_buffer.append(entry)
        if len(log_buffer) > MAX_LOG_LINES:
            log_buffer.pop(0)
    print(f"[{level}] {message}")


def find_process(name: str) -> Optional[psutil.Process]:
    """Find process by name"""
    for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
        try:
            cmdline = ' '.join(proc.info['cmdline'] or [])
            proc_name = proc.info['name'] or ''
            if name in cmdline or name in proc_name:
                if proc_name in ['bash', 'sh', 'zsh']:
                    if name not in cmdline.split(' ', 1)[-1] if cmdline.split() else '':
                        continue
                return proc
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return None


def is_pipeline_running() -> Dict:
    """Check if pipeline is running"""
    cavern = find_process('CavernPipeServer')
    snap = find_process('snapserver')
    return {
        'cavern': cavern is not None,
        'snapserver': snap is not None,
        'cavern_pid': cavern.info['pid'] if cavern else None,
        'snapserver_pid': snap.info['pid'] if snap else None
    }


def get_file_hash(filepath: str) -> str:
    """Calculate MD5 hash of file for caching"""
    hash_md5 = hashlib.md5()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()


def detect_codec(filepath: str) -> Tuple[str, int, int, float]:
    """Detect audio codec, channels, sample rate, and duration"""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'error', '-select_streams', 'a:0',
             '-show_entries', 'stream=codec_name,channels,sample_rate,duration',
             '-of', 'csv=p=0', filepath],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = result.stdout.strip().split(',')
            codec = parts[0] if len(parts) > 0 else 'unknown'
            channels = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 6
            sample_rate = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 48000
            # Handle 'N/A' or empty duration
            duration = 0.0
            if len(parts) > 3:
                try:
                    duration = float(parts[3])
                except ValueError:
                    duration = 0.0
            return codec, channels, sample_rate, duration
    except Exception as e:
        log(f'Codec detection error: {e}', 'warn')
    return 'unknown', 6, 48000, 0.0


def check_cached_damf(file_hash: str) -> Optional[str]:
    """Check if DAMF file exists in cache"""
    # Check for .atmos files (DAMF format from shell scripts)
    cached_atmos = CACHE_DIR / f"{file_hash}.atmos"
    if cached_atmos.exists():
        return str(cached_atmos)
    # Fallback to .wav files (from web UI conversion)
    cached_wav = CACHE_DIR / f"{file_hash}.wav"
    if cached_wav.exists():
        return str(cached_wav)
    return None


def extract_truehd(input_path: str, output_path: str) -> bool:
    """Extract TrueHD stream to temp file"""
    try:
        log(f'Extracting TrueHD stream...', 'info')
        result = subprocess.run(
            ['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
             '-i', input_path, '-map', '0:a:0', '-c', 'copy', '-f', 'truehd',
             '-max_muxing_queue_size', '9999', output_path],
            capture_output=True, text=True, timeout=300
        )
        # Filter out non-fatal DTS warnings
        stderr_filtered = '\n'.join(
            line for line in result.stderr.split('\n')
            if 'non monotonically increasing dts' not in line
        )
        if stderr_filtered.strip():
            log(f'FFmpeg: {stderr_filtered}', 'warn')
        return result.returncode == 0 and os.path.exists(output_path)
    except Exception as e:
        log(f'TrueHD extraction failed: {e}', 'error')
        return False


def convert_to_damf(truehd_path: str, output_prefix: str) -> Optional[str]:
    """Convert TrueHD to DAMF format using truehdd"""
    truehdd_path = "/tmp/truehdd/target/release/truehdd"
    
    if not os.path.exists(truehdd_path):
        log(f'truehdd not found at {truehdd_path}', 'error')
        return None
    
    try:
        log(f'Converting TrueHD to DAMF...', 'info')
        
        # truehdd decode --output-path <PATH_PREFIX> <INPUT>
        # Creates: <prefix>.atmos, <prefix>.atmos.audio, <prefix>.atmos.metadata
        result = subprocess.run(
            [truehdd_path, 'decode', '--output-path', output_prefix, truehd_path],
            capture_output=True, text=True, timeout=600
        )
        
        if result.returncode != 0:
            log(f'truehdd error: {result.stderr}', 'error')
            return None
        
        # Check for output files (truehdd may add .atmos extension)
        output_atmos = f"{output_prefix}.atmos"
        output_atmos_alt = f"{output_prefix}.atmos.atmos"
        
        if os.path.exists(output_atmos_alt):
            # Rename if double extension
            os.rename(output_atmos_alt, output_atmos)
            os.rename(f"{output_prefix}.atmos.atmos.audio", f"{output_prefix}.atmos.audio")
            os.rename(f"{output_prefix}.atmos.atmos.metadata", f"{output_prefix}.atmos.metadata")
        
        if os.path.exists(output_atmos):
            log(f'Conversion complete: {output_atmos}', 'info')
            return output_atmos
        
    except Exception as e:
        log(f'DAMF conversion failed: {e}', 'error')
    
    return None


def prepare_audio_file(filepath: str) -> AudioFileInfo:
    """Prepare audio file - detect codec, convert if needed, cache"""
    log(f'Analyzing: {filepath}', 'info')
    
    codec, channels, sample_rate, duration = detect_codec(filepath)
    file_hash = get_file_hash(filepath)
    
    info = AudioFileInfo(
        path=filepath,
        codec=codec,
        channels=channels,
        sample_rate=sample_rate,
        duration=duration,
        hash=file_hash
    )
    
    # Always check cache first (in case codec detection failed but cache exists)
    cached = check_cached_damf(file_hash)
    if cached:
        log(f'Using cached DAMF: {cached}', 'info')
        info.cached_damf = cached
        # If we have a cached file, treat it as playable
        if info.codec == 'unknown' or info.codec == 'truehd':
            info.codec = 'atmos'  # Mark as DAMF/atmos format
    elif codec == 'truehd':
        log(f'TrueHD detected - needs conversion', 'info')
    
    return info


def convert_and_cache(filepath: str, info: AudioFileInfo) -> Optional[str]:
    """Convert TrueHD and cache result"""
    if info.codec != 'truehd':
        return filepath
    
    with playback_lock:
        metrics_data['playback_state'] = 'converting'
        metrics_data['conversion_progress'] = 0
    
    try:
        # Check cache first
        cached = check_cached_damf(info.hash)
        if cached:
            with playback_lock:
                metrics_data['playback_state'] = 'playing'
            return cached
        
        # Extract TrueHD
        temp_truehd = str(CACHE_DIR / f"tmp_{info.hash}.truehd")
        with playback_lock:
            metrics_data['conversion_progress'] = 10
        
        if not extract_truehd(filepath, temp_truehd):
            log('TrueHD extraction failed', 'error')
            with playback_lock:
                metrics_data['playback_state'] = 'idle'
            return None
        
        with playback_lock:
            metrics_data['conversion_progress'] = 40
        
        # Convert to WAV
        output_prefix = str(CACHE_DIR / info.hash)
        wav_path = convert_to_damf(temp_truehd, output_prefix)
        
        with playback_lock:
            metrics_data['conversion_progress'] = 90
        
        # Cleanup temp file
        if os.path.exists(temp_truehd):
            os.remove(temp_truehd)
        
        if wav_path and os.path.exists(wav_path):
            with playback_lock:
                metrics_data['playback_state'] = 'playing'
                metrics_data['conversion_progress'] = 100
            return wav_path
        
    except Exception as e:
        log(f'Conversion error: {e}', 'error')
    
    with playback_lock:
        metrics_data['playback_state'] = 'idle'
        metrics_data['conversion_progress'] = 0
    return None


# ===== API Routes =====

@app.route('/api/status')
def get_status():
    """Get pipeline status"""
    status = is_pipeline_running()
    
    # Count connected clients
    client_count = 0
    try:
        result = subprocess.run(
            ['lsof', '-i', 'TCP:1704', '-sTCP:ESTABLISHED'],
            capture_output=True, text=True
        )
        lines = [l for l in result.stdout.strip().split('\n') 
                 if l and not l.startswith('COMMAND')]
        client_count = max(0, len(lines) - 1)
    except:
        pass
    
    with playback_lock:
        current_file = metrics_data.get('current_file')
        playback_state = metrics_data.get('playback_state', 'idle')
        conversion_progress = metrics_data.get('conversion_progress', 0)
    
    return jsonify({
        'timestamp': datetime.now().isoformat(),
        'pipeline': status,
        'clients': max(0, client_count),
        'fifo_exists': os.path.exists(FIFO_PATH),
        'current_file': current_file,
        'playback_state': playback_state,
        'conversion_progress': conversion_progress,
        'cache_size_mb': get_cache_size()
    })


def get_cache_size() -> float:
    """Get total cache size in MB"""
    try:
        total = sum(f.stat().st_size for f in CACHE_DIR.rglob('*') if f.is_file())
        return round(total / 1024 / 1024, 2)
    except:
        return 0.0


@app.route('/api/analyze', methods=['POST'])
def analyze_file():
    """Analyze media file - detect codec, check cache"""
    data = request.json
    filepath = data.get('file')
    
    if not filepath or not os.path.exists(filepath):
        return jsonify({'success': False, 'error': 'File not found'}), 400
    
    try:
        info = prepare_audio_file(filepath)
        needs_conversion = info.codec == 'truehd' and not info.cached_damf
        
        return jsonify({
            'success': True,
            'file': info.to_dict(),
            'needs_conversion': needs_conversion,
            'can_play_directly': info.codec in ['eac3', 'aac', 'mp3', 'flac', 'pcm_s16le', 'pcm_s24le', 'wav', 'atmos'] or info.cached_damf is not None
        })
    except Exception as e:
        log(f'Analysis failed: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/cache/clear', methods=['POST'])
def clear_cache():
    """Clear conversion cache"""
    try:
        cleared = 0
        # Clear all cache files including .atmos, .atmos.audio, .atmos.metadata, .wav, .truehd
        for pattern in ['*.atmos', '*.atmos.audio', '*.atmos.metadata', '*.wav', '*.truehd']:
            for f in CACHE_DIR.glob(pattern):
                if f.is_file():
                    f.unlink()
                    cleared += 1
        log(f'Cache cleared: {cleared} files removed', 'info')
        return jsonify({'success': True, 'files_removed': cleared})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/cache/list')
def list_cache():
    """List cached files"""
    try:
        files = []
        # List both .atmos (DAMF) and .wav files
        for pattern in ['*.atmos', '*.wav']:
            for f in CACHE_DIR.glob(pattern):
                stat = f.stat()
                files.append({
                    'name': f.name,
                    'size_mb': round(stat.st_size / 1024 / 1024, 2),
                    'created': datetime.fromtimestamp(stat.st_ctime).isoformat()
                })
        return jsonify({'success': True, 'files': files, 'total_mb': get_cache_size()})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/start', methods=['POST'])
def start_pipeline():
    """Start the pipeline"""
    global pipeline_processes
    
    try:
        log('Starting pipeline...', 'info')
        
        current_status = is_pipeline_running()
        if current_status['cavern'] and current_status['snapserver']:
            return jsonify({'success': True, 'message': 'Pipeline already running', 'already_running': True})
        
        # Cleanup old processes
        for name, proc in list(pipeline_processes.items()):
            if proc:
                try:
                    if proc.poll() is None:
                        proc.terminate()
                        proc.wait(timeout=2)
                except:
                    pass
                pipeline_processes[name] = None
        
        time.sleep(0.2)
        
        # Remove old FIFO
        current_snap = find_process('snapserver')
        if not current_snap and os.path.exists(FIFO_PATH):
            try:
                os.remove(FIFO_PATH)
                log('Removed old FIFO', 'info')
            except Exception as e:
                log(f'Could not remove FIFO: {e}', 'warn')
        
        # Start Snapserver
        log('Starting snapserver...', 'info')
        snap_log = open(LOG_DIR / 'snapserver.log', 'a')
        
        # Update config with current settings
        update_snapserver_config()
        
        snap_proc = subprocess.Popen(
            ['snapserver', '-c', str(CONFIG_DIR / 'snapserver.conf')],
            stdout=snap_log,
            stderr=subprocess.STDOUT,
            start_new_session=True
        )
        pipeline_processes['snapserver'] = snap_proc
        log(f'Snapserver started (PID: {snap_proc.pid})', 'info')
        
        # Wait for snapserver
        snap_ready = False
        for i in range(30):
            if snap_proc.poll() is not None:
                log(f'Snapserver exited early', 'error')
                break
            try:
                result = subprocess.run(
                    ['lsof', '-i', ':1704'],
                    capture_output=True, timeout=1
                )
                if result.returncode == 0 and b':1704' in result.stdout:
                    if os.path.exists(FIFO_PATH) or i > 10:
                        snap_ready = True
                        log('Snapserver ready', 'info')
                        break
            except:
                pass
            time.sleep(0.5)
        
        if not snap_ready:
            log('Warning: Snapserver may not have started properly', 'warn')
        
        if not os.path.exists(FIFO_PATH):
            os.mkfifo(FIFO_PATH)
            log('Created FIFO manually', 'info')
        
        # Start CavernPipeServer
        log('Starting CavernPipeServer...', 'info')
        cavern_log = open(LOG_DIR / 'cavernpipe.log', 'a')
        cavern_proc = subprocess.Popen(
            ['dotnet', 'CavernPipeServer.dll'],
            cwd=BIN_DIR,
            stdout=cavern_log,
            stderr=subprocess.STDOUT,
            start_new_session=True
        )
        pipeline_processes['cavern'] = cavern_proc
        log(f'CavernPipeServer started (PID: {cavern_proc.pid})', 'info')
        
        return jsonify({'success': True, 'message': 'Pipeline started'})
        
    except Exception as e:
        log(f'Failed to start pipeline: {e}', 'error')
        import traceback
        log(traceback.format_exc(), 'error')
        return jsonify({'success': False, 'error': str(e)}), 500


def update_snapserver_config():
    """Update snapserver.conf with current settings and restart snapserver if needed"""
    config_path = CONFIG_DIR / 'snapserver.conf'
    try:
        with open(config_path, 'r') as f:
            content = f.read()
        
        # Update sampleformat line
        channels = CURRENT_CONFIG['output_channels']
        rate = CURRENT_CONFIG['sample_rate']
        depth = CURRENT_CONFIG['bit_depth']
        
        # Replace or add sampleformat
        import re
        pattern = r'sampleformat=\d+:\d+:\d+'
        replacement = f'sampleformat={rate}:{depth}:{channels}'
        
        old_config = re.search(pattern, content)
        new_config_str = f'sampleformat={rate}:{depth}:{channels}'
        
        if old_config:
            content = re.sub(pattern, replacement, content)
        else:
            # Add to source line
            content = re.sub(
                r'(source = pipe:///tmp/snapcast-out[^&]*)',
                rf'\1&{replacement}',
                content
            )
        
        # Set codec based on channel count (snapserver Opus = stereo only, PCM = multichannel)
        if channels <= 2:
            new_codec = 'opus'
        else:
            new_codec = 'pcm'
        
        # Update codec - both global setting AND source URL
        content = re.sub(r'^codec = \w+', f'codec = {new_codec}', content, flags=re.MULTILINE)
        
        # Also update source URL with correct codec
        # Match source = pipe:///tmp/snapcast-out?name=Cavern&... and set codec
        content = re.sub(
            r'(source = pipe:///tmp/snapcast-out\?name=Cavern)(?:&codec=\w+)?(&.*)?',
            rf'\1&codec={new_codec}\2',
            content
        )
        
        with open(config_path, 'w') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())  # Ensure config is written to disk before snapserver reads it
        
        # Check if we need to restart snapserver
        # Check both sampleformat AND codec changes
        sampleformat_changed = old_config and old_config.group(0) != new_config_str
        old_codec_match = re.search(r'^codec = (\w+)', content, flags=re.MULTILINE)
        old_codec = old_codec_match.group(1) if old_codec_match else 'unknown'
        codec_changed = old_codec != new_codec
        restart_needed = sampleformat_changed or codec_changed
        
        # Restart snapserver if needed - even if not started by us (may have been started by run.sh)
        if restart_needed:
            log(f'Restarting snapserver for new format: {channels}ch @ {rate}Hz ({new_codec})', 'info')
            try:
                # Stop existing snapserver (whether started by us or run.sh)
                snapserver_stopped = False
                if pipeline_processes.get('snapserver'):
                    try:
                        pipeline_processes['snapserver'].terminate()
                        pipeline_processes['snapserver'].wait(timeout=2)
                        snapserver_stopped = True
                    except subprocess.TimeoutExpired:
                        pipeline_processes['snapserver'].kill()
                        pipeline_processes['snapserver'].wait(timeout=1)
                        snapserver_stopped = True
                    except Exception:
                        pass
                
                # Also try to kill any system snapserver if not stopped
                if not snapserver_stopped:
                    try:
                        subprocess.run(['pkill', '-x', 'snapserver'], check=False, capture_output=True)
                        time.sleep(0.5)
                    except Exception:
                        pass
                
                # Remove old FIFO and recreate
                if os.path.exists(FIFO_PATH):
                    os.remove(FIFO_PATH)
                os.mkfifo(FIFO_PATH)
                
                # Start new snapserver
                snap_log = open(LOG_DIR / 'snapserver.log', 'a')
                snap_proc = subprocess.Popen(
                    ['snapserver', '-c', str(config_path)],
                    stdout=snap_log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True
                )
                pipeline_processes['snapserver'] = snap_proc
                
                # Wait for it to start
                time.sleep(1)
                log(f'Snapserver restarted (PID: {snap_proc.pid})', 'info')
            except Exception as restart_err:
                log(f'Failed to restart snapserver: {restart_err}', 'error')
        else:
            log(f'Updated config: {channels}ch @ {rate}Hz, {depth}-bit ({new_codec})', 'info')
            
    except Exception as e:
        log(f'Config update error: {e}', 'warn')


@app.route('/api/stop', methods=['POST'])
def stop_pipeline():
    """Stop the pipeline"""
    try:
        _do_stop_pipeline()
        return jsonify({'success': True, 'message': 'Pipeline stopped'})
    except Exception as e:
        log(f'Error stopping pipeline: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500


def _do_stop_pipeline():
    """Internal stop function"""
    global pipeline_processes
    
    stopped = False
    
    for name, proc in list(pipeline_processes.items()):
        if proc:
            try:
                if proc.poll() is None:
                    proc.terminate()
                    stopped = True
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=1)
            except:
                pass
            pipeline_processes[name] = None
    
    if stopped:
        time.sleep(0.5)
        for proc_name in ['CavernPipeServer', 'snapserver', 'CavernPipeClient', 'PipeToFifo']:
            proc = find_process(proc_name)
            if proc:
                try:
                    proc.terminate()
                    proc.wait(timeout=2)
                except:
                    proc.kill()
    
    if stopped and os.path.exists(FIFO_PATH):
        try:
            os.remove(FIFO_PATH)
        except:
            pass
    
    with playback_lock:
        metrics_data['playback_state'] = 'idle'
        metrics_data['current_file'] = None
    
    if stopped:
        log('Pipeline stopped', 'info')


@app.route('/api/play', methods=['POST'])
def play_file():
    """Play a media file (enhanced with cavern-wireless logic)"""
    global pipeline_processes
    
    data = request.json
    filepath = data.get('file')
    
    if not filepath or not os.path.exists(filepath):
        return jsonify({'success': False, 'error': 'File not found'}), 400
    
    # Stop any existing playback
    if pipeline_processes.get('playback'):
        try:
            pipeline_processes['playback'].terminate()
            pipeline_processes['playback'].wait(timeout=2)
        except:
            pass
        pipeline_processes['playback'] = None
    
    try:
        # Update configuration
        CURRENT_CONFIG['output_channels'] = data.get('channels', 6)
        CURRENT_CONFIG['sample_rate'] = data.get('sample_rate', 48000)
        CURRENT_CONFIG['bit_depth'] = data.get('bit_depth', 16)
        
        # Update snapserver config to match (prevents speed issues)
        update_snapserver_config()
        
        # Analyze file
        info = prepare_audio_file(filepath)
        log(f"Codec: {info.codec}, Channels: {info.channels}, Duration: {info.duration:.1f}s", 'info')
        
        # Handle conversion if needed
        if info.codec == 'truehd' and not info.cached_damf:
            # Start conversion in background thread
            def conversion_thread():
                converted_path = convert_and_cache(filepath, info)
                if converted_path:
                    _start_playback(converted_path, info)
                else:
                    log('Conversion failed, trying streaming mode', 'warn')
                    _start_streaming_playback(filepath, info)
            
            threading.Thread(target=conversion_thread, daemon=True).start()
            
            return jsonify({
                'success': True,
                'message': 'TrueHD conversion started',
                'mode': 'converting',
                'file': info.to_dict()
            })
        
        # Play directly
        play_path = info.cached_damf or filepath
        _start_playback(play_path, info)
        
        return jsonify({
            'success': True,
            'message': 'Playback started',
            'mode': 'file-based' if info.cached_damf or info.codec in ['wav', 'atmos'] else 'streaming',
            'file': info.to_dict()
        })
        
    except Exception as e:
        log(f'Playback failed: {e}', 'error')
        import traceback
        log(traceback.format_exc(), 'error')
        return jsonify({'success': False, 'error': str(e)}), 500


def _start_playback(filepath: str, info: AudioFileInfo):
    """Start file-based playback"""
    global pipeline_processes
    
    with playback_lock:
        metrics_data['playback_state'] = 'playing'
        metrics_data['current_file'] = os.path.basename(filepath)
    
    log(f'Starting playback: {os.path.basename(filepath)}', 'info')
    
    # Use CavernPipeClient in file-based mode
    client_dll = BIN_DIR / 'CavernPipeClient.dll'
    pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
    
    if not client_dll.exists():
        log('CavernPipeClient.dll not found', 'error')
        with playback_lock:
            metrics_data['playback_state'] = 'idle'
        return
    
    channels = CURRENT_CONFIG['output_channels']
    depth = CURRENT_CONFIG['bit_depth']
    
    # File-based mode: -f <file> [channels] [bitDepth]
    client_log = open(LOG_DIR / 'client.log', 'a')
    playback_proc = subprocess.Popen(
        f'stdbuf -o0 dotnet "{client_dll}" -f "{filepath}" {channels} {depth} | dotnet "{pipetofifo_dll}" {FIFO_PATH}',
        shell=True,
        stdout=subprocess.DEVNULL,
        stderr=client_log,
        start_new_session=True
    )
    
    pipeline_processes['playback'] = playback_proc
    log(f'Playback started (PID: {playback_proc.pid})', 'info')


def _start_streaming_playback(filepath: str, info: AudioFileInfo):
    """Start streaming playback for non-DAMF files"""
    global pipeline_processes
    
    with playback_lock:
        metrics_data['playback_state'] = 'playing'
        metrics_data['current_file'] = os.path.basename(filepath)
    
    log(f'Starting streaming playback: {os.path.basename(filepath)}', 'info')
    
    # Extract to temp container and stream
    temp_audio = f"/tmp/cavern-temp-{int(time.time())}.mka"
    
    def streaming_thread():
        try:
            # Extract audio
            subprocess.run(
                ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                 '-i', filepath, '-map', '0:a:0', '-c:a', 'copy', temp_audio],
                check=True, timeout=60
            )
            
            # Stream through pipeline
            # Arguments: channels sampleRate bitDepth
            client_dll = BIN_DIR / 'CavernPipeClient.dll'
            pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
            
            channels = CURRENT_CONFIG['output_channels']
            rate = CURRENT_CONFIG['sample_rate']
            depth = CURRENT_CONFIG['bit_depth']
            
            with open(temp_audio, 'rb') as f:
                playback_proc = subprocess.Popen(
                    f'dotnet "{client_dll}" {channels} {rate} {depth} | dotnet "{pipetofifo_dll}" {FIFO_PATH}',
                    shell=True,
                    stdin=f,
                    stdout=subprocess.DEVNULL,
                    stderr=open(LOG_DIR / 'client.log', 'a'),
                    start_new_session=True
                )
                
                pipeline_processes['playback'] = playback_proc
                playback_proc.wait()
        
        except Exception as e:
            log(f'Streaming error: {e}', 'error')
        finally:
            if os.path.exists(temp_audio):
                os.remove(temp_audio)
            with playback_lock:
                metrics_data['playback_state'] = 'idle'
    
    threading.Thread(target=streaming_thread, daemon=True).start()


@app.route('/api/stop-playback', methods=['POST'])
def stop_playback():
    """Stop current playback"""
    global pipeline_processes
    
    if pipeline_processes.get('playback'):
        try:
            pipeline_processes['playback'].terminate()
            pipeline_processes['playback'].wait(timeout=2)
            pipeline_processes['playback'] = None
        except:
            pass
    
    with playback_lock:
        metrics_data['playback_state'] = 'idle'
        metrics_data['current_file'] = None
    
    return jsonify({'success': True, 'message': 'Playback stopped'})


# ===== Streaming Support =====

@app.route('/api/streaming/start', methods=['POST'])
def start_streaming():
    """Start system audio streaming mode"""
    global pipeline_processes
    
    data = request.json or {}
    source = data.get('source', 'system')  # system, app, url
    
    try:
        if source == 'system':
            return _start_system_audio_streaming()
        elif source == 'url':
            url = data.get('url')
            if not url:
                return jsonify({'success': False, 'error': 'URL required'}), 400
            return _start_url_streaming(url)
        else:
            return jsonify({'success': False, 'error': f'Unknown source: {source}'}), 400
    except Exception as e:
        log(f'Streaming start error: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500


def _start_system_audio_streaming():
    """Start capturing system audio (requires BlackHole on macOS)"""
    # Check for BlackHole
    result = subprocess.run(
        ['pactl', 'list', 'short', 'sources'],
        capture_output=True, text=True
    )
    
    log('Starting system audio streaming...', 'info')
    
    # Use ffmpeg to capture from default audio device
    # On macOS with BlackHole: -f avfoundation -i ":BlackHole"
    # On Linux: -f pulse -i default
    
    client_dll = BIN_DIR / 'CavernPipeClient.dll'
    pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
    channels = CURRENT_CONFIG['output_channels']
    rate = CURRENT_CONFIG['sample_rate']
    depth = CURRENT_CONFIG['bit_depth']
    
    # Platform-specific capture
    if sys.platform == 'darwin':
        # macOS - try BlackHole
        input_device = ':BlackHole 16ch'  # or whatever the user named it
        ffmpeg_input = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'avfoundation',
                       '-i', input_device, '-ar', str(rate), '-ac', str(channels),
                       '-f', 's16le', '-']
    else:
        # Linux - use pulse
        ffmpeg_input = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'pulse',
                       '-i', 'default', '-ar', str(rate), '-ac', str(channels),
                       '-f', 's16le', '-']
    
    # Start ffmpeg | client | fifo chain
    # Arguments: channels sampleRate bitDepth
    ffmpeg_proc = subprocess.Popen(
        ffmpeg_input,
        stdout=subprocess.PIPE,
        stderr=open(LOG_DIR / 'streaming_ffmpeg.log', 'a')
    )
    
    client_proc = subprocess.Popen(
        ['dotnet', str(client_dll), str(channels), str(rate), str(depth)],
        stdin=ffmpeg_proc.stdout,
        stdout=subprocess.PIPE,
        stderr=open(LOG_DIR / 'streaming_client.log', 'a')
    )
    
    fifo_proc = subprocess.Popen(
        ['dotnet', str(pipetofifo_dll), FIFO_PATH],
        stdin=client_proc.stdout,
        stdout=subprocess.DEVNULL,
        stderr=open(LOG_DIR / 'streaming_fifo.log', 'a')
    )
    
    pipeline_processes['streaming'] = ffmpeg_proc
    
    with playback_lock:
        metrics_data['playback_state'] = 'streaming'
        metrics_data['current_file'] = 'System Audio'
    
    log('System audio streaming started', 'info')
    return jsonify({'success': True, 'message': 'System audio streaming started'})


def _start_url_streaming(url: str):
    """Start streaming from URL"""
    log(f'Starting URL streaming: {url}', 'info')
    
    client_dll = BIN_DIR / 'CavernPipeClient.dll'
    pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
    channels = CURRENT_CONFIG['output_channels']
    rate = CURRENT_CONFIG['sample_rate']
    depth = CURRENT_CONFIG['bit_depth']
    
    # ffmpeg to decode URL → raw PCM → client → fifo
    # Arguments: channels sampleRate bitDepth
    ffmpeg_proc = subprocess.Popen(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-re', '-i', url,
         '-ar', str(rate), '-ac', str(channels), '-f', 's16le', '-'],
        stdout=subprocess.PIPE,
        stderr=open(LOG_DIR / 'streaming_ffmpeg.log', 'a')
    )
    
    client_proc = subprocess.Popen(
        ['dotnet', str(client_dll), str(channels), str(rate), str(depth)],
        stdin=ffmpeg_proc.stdout,
        stdout=subprocess.PIPE,
        stderr=open(LOG_DIR / 'streaming_client.log', 'a')
    )
    
    fifo_proc = subprocess.Popen(
        ['dotnet', str(pipetofifo_dll), FIFO_PATH],
        stdin=client_proc.stdout,
        stdout=subprocess.DEVNULL,
        stderr=open(LOG_DIR / 'streaming_fifo.log', 'a')
    )
    
    pipeline_processes['streaming'] = ffmpeg_proc
    
    with playback_lock:
        metrics_data['playback_state'] = 'streaming'
        metrics_data['current_file'] = f'URL: {url[:50]}...'
    
    return jsonify({'success': True, 'message': 'URL streaming started'})


@app.route('/api/streaming/stop', methods=['POST'])
def stop_streaming():
    """Stop streaming"""
    global pipeline_processes
    
    if pipeline_processes.get('streaming'):
        try:
            pipeline_processes['streaming'].terminate()
            pipeline_processes['streaming'].wait(timeout=2)
            pipeline_processes['streaming'] = None
        except:
            pass
    
    with playback_lock:
        metrics_data['playback_state'] = 'idle'
        metrics_data['current_file'] = None
    
    return jsonify({'success': True, 'message': 'Streaming stopped'})


# ===== Configuration =====

@app.route('/api/config', methods=['GET', 'POST'])
def handle_config():
    """Get or update configuration"""
    global CURRENT_CONFIG
    
    if request.method == 'GET':
        config_file = CONFIG_DIR / 'speaker-layouts.json'
        try:
            with open(config_file) as f:
                layouts = json.load(f)
        except:
            layouts = {}
        
        return jsonify({
            'current': CURRENT_CONFIG,
            'layouts': layouts,
            'cache_dir': str(CACHE_DIR),
            'cache_size_mb': get_cache_size()
        })
    
    else:  # POST
        data = request.json
        
        # Update current config
        for key in ['output_channels', 'sample_rate', 'bit_depth', 'buffer_ms', 'latency_ms']:
            if key in data:
                CURRENT_CONFIG[key] = data[key]
        
        log(f"Config updated: {CURRENT_CONFIG['output_channels']}ch @ {CURRENT_CONFIG['sample_rate']}Hz", 'info')
        return jsonify({'success': True, 'config': CURRENT_CONFIG})


# ===== Logs & Metrics =====

@app.route('/api/logs')
def get_logs():
    """Get recent logs"""
    lines = request.args.get('lines', 100, type=int)
    with log_lock:
        return jsonify(log_buffer[-lines:])


@app.route('/api/metrics')
def get_metrics():
    """Get streaming metrics"""
    with metrics_lock:
        return jsonify({
            'timestamp': datetime.now().isoformat(),
            'bytes_streamed': metrics_data['bytes_streamed'],
            'speed_mbps': metrics_data['speed_mbps'],
            'buffer_size_bytes': metrics_data['buffer_size_bytes'],
            'buffer_percent': metrics_data['buffer_percent'],
            'active_streams': metrics_data['active_streams'],
            'fifo_exists': os.path.exists(FIFO_PATH),
            'current_file': metrics_data.get('current_file'),
            'playback_state': metrics_data.get('playback_state'),
            'conversion_progress': metrics_data.get('conversion_progress', 0)
        })


@app.route('/api/audio-levels')
def get_audio_levels():
    """Get audio levels - NOTE: Reading from FIFO interferes with playback.
    This returns simulated levels based on playback state."""
    import random
    
    channels = request.args.get('channels', 6, type=int)
    levels = []
    
    with playback_lock:
        is_playing = metrics_data.get('playback_state') in ['playing', 'streaming']
    
    # Generate simulated levels based on playback state
    # We can't read from the FIFO as it would steal data from snapserver
    for i in range(channels):
        if is_playing:
            # Simulate activity when playing
            base_level = 15 + random.random() * 25
            level = min(100, base_level + random.random() * 10)
            peak = min(100, level + random.random() * 15)
        else:
            # Silence when not playing
            level = random.random() * 2
            peak = level + random.random() * 2
        
        levels.append({'channel': i, 'level': level, 'peak': peak})
    
    return jsonify({'channels': levels, 'source': 'simulated'})


# ===== Static Files =====

@app.route('/')
def serve_index():
    return send_from_directory('.', 'index.html')


@app.route('/<path:path>')
def serve_static(path):
    return send_from_directory('.', path)


# ===== Background Threads =====

def update_metrics():
    """Background thread to update metrics"""
    while True:
        try:
            now = datetime.now()
            
            # Count active streams
            active_streams = 0
            try:
                result = subprocess.run(
                    ['lsof', '-i', 'TCP:1704', '-sTCP:ESTABLISHED'],
                    capture_output=True, text=True
                )
                lines = [l for l in result.stdout.strip().split('\n') if l and not l.startswith('COMMAND')]
                active_streams = max(0, len(lines) - 1)
            except:
                pass
            
            # Check FIFO
            fifo_size = 0
            fifo_has_data = False
            if os.path.exists(FIFO_PATH):
                try:
                    result = subprocess.run(['lsof', FIFO_PATH], capture_output=True, text=True)
                    fifo_has_data = 'write' in result.stdout.lower()
                    stat = os.stat(FIFO_PATH)
                    fifo_size = stat.st_size
                except:
                    pass
            
            # Calculate streaming speed
            with playback_lock:
                is_streaming = metrics_data.get('playback_state') in ['playing', 'streaming']
            
            speed_mbps = 0.0
            if is_streaming:
                time_diff = (now - metrics_data['last_check_time']).total_seconds()
                if time_diff > 0:
                    audio_rate = CURRENT_CONFIG['sample_rate'] * 2 * CURRENT_CONFIG['output_channels']
                    new_bytes = int(audio_rate * time_diff)
                    metrics_data['bytes_streamed'] += new_bytes
                    speed_mbps = new_bytes / time_diff / 1024 / 1024
            
            buffer_capacity = 576000
            buffer_percent = min(100, int((fifo_size / buffer_capacity) * 100)) if fifo_size > 0 else 0
            
            with metrics_lock:
                metrics_data['last_bytes'] = metrics_data['bytes_streamed']
                metrics_data['last_check_time'] = now
                metrics_data['speed_mbps'] = speed_mbps
                metrics_data['buffer_size_bytes'] = fifo_size
                metrics_data['buffer_percent'] = buffer_percent
                metrics_data['active_streams'] = active_streams
                
        except Exception as e:
            log(f'Metrics error: {e}', 'debug')
        
        time.sleep(1)


def tail_log_file(filepath: Path, source_name: str):
    """Tail a log file"""
    for _ in range(30):
        if os.path.exists(filepath):
            break
        time.sleep(1)
    
    if not os.path.exists(filepath):
        return
    
    level_map = {
        'error': 'error', 'Error': 'error', 'ERROR': 'error',
        'warn': 'warn', 'Warn': 'warn', 'WARN': 'warn',
        'warning': 'warn', 'Warning': 'warn', 'WARNING': 'warn',
    }
    
    try:
        with open(filepath, 'r') as f:
            f.seek(0, 2)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.1)
                    continue
                
                line = line.strip()
                if not line:
                    continue
                
                level = 'info'
                for keyword, lvl in level_map.items():
                    if keyword in line:
                        level = lvl
                        break
                
                log(f'[{source_name}] {line}', level)
    except:
        pass


def start_background_threads():
    """Start background threads"""
    threading.Thread(target=update_metrics, daemon=True).start()
    
    log_files = [
        (LOG_DIR / 'cavernpipe.log', 'Cavern'),
        (LOG_DIR / 'snapserver.log', 'Snapserver'),
        (LOG_DIR / 'client.log', 'Client'),
    ]
    
    for filepath, source in log_files:
        t = threading.Thread(target=tail_log_file, args=(filepath, source), daemon=True)
        t.start()


# ===== Signal Handlers =====

def signal_handler(sig, frame):
    print('\nShutting down...')
    _do_stop_pipeline()
    sys.exit(0)


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


# ===== Main =====

if __name__ == '__main__':
    # Ensure directories exist
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    
    # Start background threads
    start_background_threads()
    
    print("="*50)
    print("CavernPipe Web UI Server - Enhanced")
    print("="*50)
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Cache: {CACHE_DIR}")
    print(f"Logs: {LOG_DIR}")
    print("")
    print("Open http://localhost:8080 in your browser")
    print("="*50)
    
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
