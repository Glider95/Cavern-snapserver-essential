#!/usr/bin/env python3
"""
CavernPipe Web UI Server - Fixed Version
Enhanced Flask-based backend with proper pipeline management
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
import select
from datetime import datetime
from pathlib import Path
from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Configuration
PROJECT_ROOT = Path(__file__).parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
LOG_DIR = PROJECT_ROOT / "logs"
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
CACHE_DIR = Path.home() / ".cavern-wireless" / "cache"
FIFO_PATH = "/tmp/snapcast-out"
BIN_DIR = PROJECT_ROOT / "bin"

# Create directories
CACHE_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Process tracking - stores subprocess.Popen objects
pipeline_processes = {
    'cavern': None,
    'snapserver': None,
    'current_playback': None
}
process_lock = threading.Lock()

# Conversion status tracking
conversion_status = {
    'active': False,
    'file': None,
    'progress': 0,
    'stage': None,
    'message': None,
    'cached': False,
    'error': None
}
conversion_lock = threading.Lock()

# Log buffer
log_buffer = []
MAX_LOG_LINES = 1000
log_lock = threading.Lock()

# Metrics tracking
metrics_data = {
    'bytes_streamed': 0,
    'last_bytes': 0,
    'last_check_time': datetime.now(),
    'speed_mbps': 0.0,
    'buffer_size_bytes': 0,
    'buffer_percent': 0,
    'active_streams': 0,
    'fifo_data_flowing': False
}
metrics_lock = threading.Lock()

# Configuration defaults
STREAMING_CONFIG = {
    'buffer_ms': 1000,
    'latency_ms': 100
}

# Current playback info
current_playback = {
    'file': None,
    'codec': None,
    'started_at': None,
    'status': 'idle',  # 'idle', 'playing', 'converting', 'error', 'starting'
    'pid': None
}
playback_lock = threading.Lock()

# ==================== Logging ====================

def log(message, level='info'):
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
    print(f"[{level.upper()}] {message}", flush=True)

# ==================== Process Management ====================

def find_process(name):
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

def is_pipeline_running():
    """Check if pipeline services are running"""
    cavern = find_process('CavernPipeServer')
    snap = find_process('snapserver')
    return {
        'cavern': cavern is not None,
        'snapserver': snap is not None,
        'cavern_pid': cavern.info['pid'] if cavern else None,
        'snapserver_pid': snap.info['pid'] if snap else None
    }

def is_process_alive(proc):
    """Check if a subprocess is still running"""
    if proc is None:
        return False
    try:
        return proc.poll() is None
    except:
        return False

def kill_process_tree(pid):
    """Kill a process and all its children"""
    try:
        parent = psutil.Process(pid)
        for child in parent.children(recursive=True):
            try:
                child.terminate()
            except:
                pass
        parent.terminate()
        
        # Wait for termination
        gone, alive = psutil.wait_procs([parent] + parent.children(recursive=True), timeout=2)
        for p in alive:
            try:
                p.kill()
            except:
                pass
    except psutil.NoSuchProcess:
        pass
    except Exception as e:
        log(f'Error killing process tree: {e}', 'debug')

# ==================== Internal Pipeline Functions ====================

def _do_start_pipeline():
    """Internal function to start pipeline (no Flask context needed)"""
    global pipeline_processes
    
    with process_lock:
        try:
            log('Starting pipeline infrastructure...')
            
            # Check if already running
            current_status = is_pipeline_running()
            if current_status['cavern'] and current_status['snapserver']:
                log('Pipeline already running')
                return {'success': True, 'message': 'Already running', 'already_running': True}
            
            # Cleanup old processes
            for name in ['snapserver', 'cavern']:
                proc = pipeline_processes.get(name)
                if proc and is_process_alive(proc):
                    log(f'Terminating existing {name}')
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except:
                        proc.kill()
                pipeline_processes[name] = None
            
            # Kill any stray processes
            for proc_name in ['snapserver', 'CavernPipeServer']:
                proc = find_process(proc_name)
                if proc:
                    log(f'Killing stray {proc_name} (PID {proc.pid})')
                    try:
                        proc.terminate()
                        proc.wait(timeout=2)
                    except:
                        try:
                            proc.kill()
                        except:
                            pass
            
            time.sleep(0.5)
            
            # Clean up old FIFO
            if os.path.exists(FIFO_PATH):
                try:
                    os.remove(FIFO_PATH)
                    log('Removed old FIFO')
                except Exception as e:
                    log(f'Could not remove FIFO: {e}', 'warn')
            
            # Create FIFO first (snapserver with mode=read expects it to exist)
            try:
                os.mkfifo(FIFO_PATH)
                log(f'Created FIFO: {FIFO_PATH}')
            except Exception as e:
                log(f'Failed to create FIFO: {e}', 'error')
                return {'success': False, 'error': f'FIFO creation failed: {e}'}
            
            # Start Snapserver (will read from existing FIFO)
            log('Starting snapserver...')
            snap_log_path = LOG_DIR / 'snapserver.log'
            snap_log = open(snap_log_path, 'a')
            
            snap_proc = subprocess.Popen(
                ['snapserver', '-c', str(CONFIG_DIR / 'snapserver.conf')],
                stdout=snap_log,
                stderr=subprocess.STDOUT,
                start_new_session=True
            )
            pipeline_processes['snapserver'] = snap_proc
            log(f'Snapserver started (PID: {snap_proc.pid})')
            
            # Wait for snapserver control port to be ready
            snap_ready = False
            for i in range(40):  # Wait up to 20 seconds
                if not is_process_alive(snap_proc):
                    log('Snapserver died during startup', 'error')
                    return {'success': False, 'error': 'Snapserver failed to start'}
                
                # Check control port
                try:
                    import socket
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(0.5)
                    result = sock.connect_ex(('127.0.0.1', 1705))
                    sock.close()
                    if result == 0:
                        snap_ready = True
                        log('Snapserver ready (control port responding)')
                        break
                except:
                    pass
                
                time.sleep(0.5)
            
            if not snap_ready:
                log('Snapserver started but control port not responding', 'warn')
            
            # Small delay after FIFO creation
            time.sleep(0.5)
            
            # Start CavernPipeServer
            log('Starting CavernPipeServer...')
            cavern_log_path = LOG_DIR / 'cavernpipe.log'
            cavern_log = open(cavern_log_path, 'a')
            
            cavern_proc = subprocess.Popen(
                ['dotnet', 'CavernPipeServer.dll'],
                cwd=BIN_DIR,
                stdout=cavern_log,
                stderr=subprocess.STDOUT,
                start_new_session=True
            )
            pipeline_processes['cavern'] = cavern_proc
            log(f'CavernPipeServer started (PID: {cavern_proc.pid})')
            
            # Wait for CavernPipeServer to initialize
            time.sleep(2)
            
            # Check if still running
            if not is_process_alive(cavern_proc):
                log('CavernPipeServer died during startup', 'error')
                return {'success': False, 'error': 'CavernPipeServer failed to start'}
            
            log('Pipeline infrastructure started successfully')
            return {'success': True, 'message': 'Pipeline started'}
            
        except Exception as e:
            log(f'Failed to start pipeline: {e}', 'error')
            import traceback
            log(traceback.format_exc(), 'error')
            return {'success': False, 'error': str(e)}

def _do_stop_pipeline():
    """Internal function to stop pipeline"""
    global pipeline_processes
    
    with process_lock:
        stopped = False
        
        # Stop all tracked processes
        for name in ['current_playback', 'cavern', 'snapserver']:
            proc = pipeline_processes.get(name)
            if proc and is_process_alive(proc):
                try:
                    log(f'Stopping {name} (PID {proc.pid})')
                    proc.terminate()
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=1)
                    stopped = True
                except Exception as e:
                    log(f'Error stopping {name}: {e}', 'warn')
                finally:
                    pipeline_processes[name] = None
        
        # Kill any stray processes
        for proc_name in ['CavernPipeClient', 'PipeToFifo', 'CavernPipeServer', 'snapserver', 'ffmpeg']:
            proc = find_process(proc_name)
            if proc:
                try:
                    log(f'Killing stray {proc_name} (PID {proc.pid})')
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except:
                        proc.kill()
                except:
                    pass
                stopped = True
        
        # Clean up FIFO
        if os.path.exists(FIFO_PATH):
            try:
                os.remove(FIFO_PATH)
                log('Removed FIFO')
            except:
                pass
        
        # Reset playback state
        with playback_lock:
            current_playback.update({
                'status': 'idle',
                'file': None,
                'codec': None,
                'pid': None
            })
        
        if stopped:
            log('Pipeline stopped')
        return stopped

def _do_play_file(file_path, channels=6, sample_rate=48000, bit_depth=16):
    """Internal function to play a file (no Flask context)"""
    global pipeline_processes
    
    with process_lock:
        try:
            # Stop any current playback
            if pipeline_processes.get('current_playback'):
                try:
                    old_proc = pipeline_processes['current_playback']
                    if is_process_alive(old_proc):
                        old_proc.terminate()
                        old_proc.wait(timeout=2)
                except:
                    pass
                pipeline_processes['current_playback'] = None
            
            # Ensure pipeline is running
            status = is_pipeline_running()
            if not status['cavern'] or not status['snapserver']:
                log('Pipeline not running, starting it first...')
                result = _do_start_pipeline()
                if not result['success']:
                    return result
                time.sleep(3)  # Give more time for services to initialize
            
            # Verify FIFO exists
            if not os.path.exists(FIFO_PATH):
                log('FIFO not available, creating manually...')
                try:
                    os.mkfifo(FIFO_PATH)
                    time.sleep(0.5)
                except Exception as e:
                    return {'success': False, 'error': f'Cannot create FIFO: {e}'}
            
            # Prepare audio
            log(f'Preparing audio: {file_path}')
            with playback_lock:
                current_playback.update({
                    'file': file_path,
                    'status': 'starting',
                    'started_at': datetime.now().isoformat()
                })
            
            prepared = prepare_audio_file(file_path)
            
            if prepared.get('error'):
                with playback_lock:
                    current_playback.update({'status': 'error'})
                return {'success': False, 'error': prepared['error']}
            
            audio_file = prepared['file']
            codec = prepared['codec']
            
            # Setup environment
            env = os.environ.copy()
            env['OUTPUT_CHANNELS'] = str(channels)
            env['SAMPLE_RATE'] = str(sample_rate)
            env['BIT_DEPTH'] = str(bit_depth)
            
            client_dll = BIN_DIR / 'CavernPipeClient.dll'
            pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
            
            # Verify binaries exist
            if not client_dll.exists():
                return {'success': False, 'error': f'CavernPipeClient.dll not found at {client_dll}'}
            if not pipetofifo_dll.exists():
                return {'success': False, 'error': f'PipeToFifo.dll not found at {pipetofifo_dll}'}
            
            log(f'Starting playback: {audio_file} ({codec}, {channels}ch @ {sample_rate}Hz)')
            
            file_ext = Path(audio_file).suffix.lower()
            
            # Note: Only .atmos files work in file-based mode
            # WAV files need streaming mode because CavernPipeServer
            # only supports its own DAMF format for file-based mode
            if file_ext == '.atmos':
                # File-based mode (most reliable - only for DAMF format)
                log('Using file-based mode for DAMF file')
                
                # Create log files
                client_log = open(LOG_DIR / 'client.log', 'a')
                fifo_log = open(LOG_DIR / 'fifo.log', 'a')
                
                playback_proc = subprocess.Popen(
                    ['stdbuf', '-o0', 'dotnet', str(client_dll), 
                     audio_file, str(channels), str(bit_depth)],
                    stdout=subprocess.PIPE,
                    stderr=client_log,
                    env=env,
                    start_new_session=True
                )
                
                fifo_proc = subprocess.Popen(
                    ['dotnet', str(pipetofifo_dll), FIFO_PATH, '2048'],
                    stdin=playback_proc.stdout,
                    stderr=fifo_log,
                    env=env,
                    start_new_session=True
                )
                playback_proc.stdout.close()
                
                pipeline_processes['current_playback'] = fifo_proc
                
                with playback_lock:
                    current_playback.update({
                        'file': file_path,
                        'codec': codec,
                        'status': 'playing',
                        'pid': fifo_proc.pid,
                        'started_at': datetime.now().isoformat()
                    })
                
                log(f'Playback started (PID: {fifo_proc.pid})')
                
                # Start monitoring thread
                threading.Thread(target=monitor_playback, daemon=True).start()
                
                return {
                    'success': True,
                    'message': 'Playback started',
                    'file': file_path,
                    'codec': codec,
                    'converted': prepared.get('converted', False),
                    'pid': fifo_proc.pid
                }
                
            else:
                # Streaming mode for WAV and container files (mkv, mp4, etc.)
                # Important: For streaming mode, we do NOT pass the file path to the client
                # The client determines mode by checking if File.Exists(args[0])
                
                client_log = open(LOG_DIR / 'client.log', 'a')
                fifo_log = open(LOG_DIR / 'fifo.log', 'a')
                
                if file_ext == '.wav':
                    # For WAV files, bypass CavernPipeServer and stream PCM directly to FIFO
                    # CavernPipeServer streaming mode expects compressed audio, not PCM
                    log('Streaming WAV directly to FIFO (bypassing CavernPipe)')
                    
                    # Convert WAV to raw PCM s16le with optimized buffering for smooth playback
                    ffmpeg_proc = subprocess.Popen(
                        ['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
                         '-thread_queue_size', '4096',  # Larger input buffer
                         '-i', audio_file, 
                         '-acodec', 'pcm_s16le', '-ar', str(sample_rate), '-ac', str(channels),
                         '-f', 's16le', 
                         '-thread_queue_size', '4096',  # Larger output buffer

                         '-'],
                        stdout=subprocess.PIPE,
                        stderr=open(LOG_DIR / 'ffmpeg.log', 'a'),
                        start_new_session=True
                    )
                    
                    # Pipe PCM directly to PipeToFifo with 4MB buffer, bypassing CavernPipeClient/Server
                    fifo_proc = subprocess.Popen(
                        ['dotnet', str(pipetofifo_dll), FIFO_PATH, '4096'],  # 4MB buffer
                        stdin=ffmpeg_proc.stdout,
                        stderr=fifo_log,
                        env=env,
                        start_new_session=True
                    )
                    ffmpeg_proc.stdout.close()
                    # For WAV files, fifo_proc is already created above
                    
                else:
                    # For container files (mkv, mp4, etc.), extract audio first
                    log('Using streaming mode with container extraction')
                    temp_audio = f"/tmp/cavern-web-{int(time.time())}.mka"
                    
                    # Extract audio
                    extract_result = subprocess.run(
                        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                         '-i', audio_file, '-map', '0:a:0', '-c:a', 'copy', temp_audio],
                        capture_output=True, text=True, timeout=120
                    )
                    
                    if extract_result.returncode != 0 or not os.path.exists(temp_audio):
                        with playback_lock:
                            current_playback.update({'status': 'error'})
                        return {'success': False, 'error': f'Extraction failed: {extract_result.stderr}'}
                    
                    log(f'Audio extracted to: {temp_audio}')
                    
                    # Chain: cat -> client -> PipeToFifo
                    playback_proc = subprocess.Popen(
                        ['cat', temp_audio],
                        stdout=subprocess.PIPE,
                        start_new_session=True
                    )
                    
                    client_proc = subprocess.Popen(
                        ['dotnet', str(client_dll), str(channels), str(sample_rate), str(bit_depth)],
                        stdin=playback_proc.stdout,
                        stdout=subprocess.PIPE,
                        stderr=client_log,
                        env=env,
                        start_new_session=True
                    )
                    playback_proc.stdout.close()
                    
                    # Chain to PipeToFifo
                    fifo_proc = subprocess.Popen(
                        ['dotnet', str(pipetofifo_dll), FIFO_PATH, '2048'],
                        stdin=client_proc.stdout,
                        stderr=fifo_log,
                        env=env,
                        start_new_session=True
                    )
                    client_proc.stdout.close()
                
                pipeline_processes['current_playback'] = fifo_proc
                
                with playback_lock:
                    current_playback.update({
                        'file': file_path,
                        'codec': codec,
                        'status': 'playing',
                        'pid': fifo_proc.pid,
                        'started_at': datetime.now().isoformat()
                    })
                
                log(f'Playback started (PID: {fifo_proc.pid})')
                
                # Cleanup thread (only for container files with temp audio)
                if file_ext != '.wav' and 'temp_audio' in locals():
                    def cleanup_temp():
                        try:
                            fifo_proc.wait()
                            os.unlink(temp_audio)
                            log(f'Cleaned up temp file: {temp_audio}')
                        except:
                            pass
                    
                    threading.Thread(target=cleanup_temp, daemon=True).start()
                
                # Start monitoring thread
                threading.Thread(target=monitor_playback, daemon=True).start()
                
                return {
                    'success': True,
                    'message': 'Playback started',
                    'file': file_path,
                    'codec': codec,
                    'converted': prepared.get('converted', False),
                    'pid': fifo_proc.pid
                }
                
        except Exception as e:
            log(f'Playback failed: {e}', 'error')
            import traceback
            log(traceback.format_exc(), 'error')
            with playback_lock:
                current_playback.update({'status': 'error'})
            return {'success': False, 'error': str(e)}

def monitor_playback():
    """Monitor playback process and update status when it ends"""
    global pipeline_processes
    
    proc = pipeline_processes.get('current_playback')
    if not proc:
        return
    
    try:
        # Wait for process to complete
        proc.wait()
        log('Playback process ended')
        
        with playback_lock:
            if current_playback['status'] == 'playing':
                current_playback.update({
                    'status': 'idle',
                    'file': None,
                    'pid': None
                })
        
        with process_lock:
            pipeline_processes['current_playback'] = None
            
    except Exception as e:
        log(f'Monitor error: {e}', 'debug')

# ==================== Audio Processing ====================

def detect_codec(file_path):
    """Detect audio codec using ffprobe"""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'error', '-select_streams', 'a:0', 
             '-show_entries', 'stream=codec_name,channels,sample_rate',
             '-of', 'default=noprint_wrappers=1:nokey=1', file_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split('\n')
            if len(parts) >= 3:
                return {
                    'codec': parts[0],
                    'channels': parts[1],
                    'sample_rate': parts[2]
                }
    except Exception as e:
        log(f'Codec detection error: {e}', 'error')
    
    return {'codec': 'unknown', 'channels': '0', 'sample_rate': '0'}

def get_file_hash(file_path):
    """Calculate MD5 hash for caching"""
    hash_md5 = hashlib.md5()
    with open(file_path, "rb") as f:
        hash_md5.update(f.read(1024 * 1024))
        f.seek(-1024 * 1024, 2)
        hash_md5.update(f.read(1024 * 1024))
    return hash_md5.hexdigest()

def get_cached_damf(file_path):
    """Check if a DAMF version exists in cache"""
    try:
        file_hash = get_file_hash(file_path)
        cached_wav = CACHE_DIR / f"{file_hash}.wav"
        if cached_wav.exists():
            return str(cached_wav)
    except Exception:
        pass
    return None

def convert_truehd_to_damf(input_file):
    """Convert TrueHD to WAV/DAMF format"""
    global conversion_status
    
    with conversion_lock:
        conversion_status.update({
            'active': True,
            'file': input_file,
            'progress': 0,
            'stage': 'detecting',
            'message': 'Detecting codec...',
            'cached': False,
            'error': None
        })
    
    try:
        # Calculate cache key
        file_hash = get_file_hash(input_file)
        cached_wav = CACHE_DIR / f"{file_hash}.wav"
        
        # Check cache first
        if cached_wav.exists():
            log(f'Using cached conversion: {cached_wav}')
            with conversion_lock:
                conversion_status.update({
                    'active': False,
                    'file': input_file,
                    'progress': 100,
                    'stage': 'complete',
                    'message': 'Using cached file',
                    'cached': True,
                    'error': None
                })
            return str(cached_wav)
        
        # Stage 1: Extract TrueHD stream
        with conversion_lock:
            conversion_status.update({
                'stage': 'extracting',
                'message': 'Extracting TrueHD stream...',
                'progress': 10
            })
        
        temp_truehd = CACHE_DIR / f"tmp_{file_hash}.truehd"
        
        log(f'Extracting TrueHD from: {input_file}')
        result = subprocess.run(
            ['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
             '-i', input_file, '-map', '0:a:0', '-c', 'copy', 
             '-f', 'truehd', '-max_muxing_queue_size', '9999', str(temp_truehd)],
            capture_output=True, text=True, timeout=120
        )
        
        if result.returncode != 0 or not temp_truehd.exists():
            error_msg = f'TrueHD extraction failed: {result.stderr[:200]}'
            log(error_msg, 'error')
            with conversion_lock:
                conversion_status.update({
                    'active': False,
                    'stage': 'error',
                    'message': error_msg,
                    'error': error_msg
                })
            return None
        
        # Stage 2: Convert with truehdd
        with conversion_lock:
            conversion_status.update({
                'stage': 'converting',
                'message': 'Converting TrueHD to WAV...',
                'progress': 40
            })
        
        truehdd_path = "/tmp/truehdd/target/release/truehdd"
        if not Path(truehdd_path).exists():
            error_msg = 'truehdd not found. Please build it first.'
            log(error_msg, 'error')
            with conversion_lock:
                conversion_status.update({
                    'active': False,
                    'stage': 'error',
                    'message': error_msg,
                    'error': error_msg
                })
            return None
        
        temp_w64_prefix = CACHE_DIR / f"{file_hash}_temp"
        
        log('Decoding TrueHD to W64...')
        result = subprocess.run(
            [truehdd_path, 'decode', '--output-path', str(temp_w64_prefix), 
             '--format', 'w64', '--presentation', '1', str(temp_truehd)],
            capture_output=True, text=True, timeout=300
        )
        
        # truehdd creates {prefix}.wav, not {prefix}.w64.wav
        temp_w64 = Path(f"{temp_w64_prefix}.wav")
        
        # Check if output file was created (truehdd outputs INFO logs to stderr, not errors)
        if not temp_w64.exists():
            error_msg = f'truehdd conversion failed (exit code {result.returncode})'
            if result.stderr:
                error_msg += f': {result.stderr[:200]}'
            log(error_msg, 'error')
            with conversion_lock:
                conversion_status.update({
                    'active': False,
                    'stage': 'error',
                    'message': error_msg,
                    'error': error_msg
                })
            temp_truehd.unlink(missing_ok=True)
            return None
        
        log(f'truehdd success: {temp_w64} ({temp_w64.stat().st_size / 1024 / 1024:.1f} MB)')
        
        with conversion_lock:
            conversion_status.update({'progress': 80})
        
        # Stage 3: Convert W64 to standard WAV
        log('Converting W64 to standard WAV...')
        result = subprocess.run(
            ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
             '-i', str(temp_w64), '-c:a', 'pcm_s24le', str(cached_wav)],
            capture_output=True, text=True, timeout=60
        )
        
        # Cleanup temp files
        temp_w64.unlink(missing_ok=True)
        temp_truehd.unlink(missing_ok=True)
        
        if result.returncode != 0:
            error_msg = f'WAV conversion failed: {result.stderr[:200]}'
            log(error_msg, 'error')
            cached_wav.unlink(missing_ok=True)
            with conversion_lock:
                conversion_status.update({
                    'active': False,
                    'stage': 'error',
                    'message': error_msg,
                    'error': error_msg
                })
            return None
        
        # Success!
        log(f'Conversion complete: {cached_wav}')
        with conversion_lock:
            conversion_status.update({
                'active': False,
                'file': input_file,
                'progress': 100,
                'stage': 'complete',
                'message': 'Conversion complete',
                'cached': False,
                'error': None
            })
        
        return str(cached_wav)
        
    except subprocess.TimeoutExpired:
        error_msg = 'Conversion timed out'
        log(error_msg, 'error')
        with conversion_lock:
            conversion_status.update({
                'active': False,
                'stage': 'error',
                'message': error_msg,
                'error': error_msg
            })
        return None
    except Exception as e:
        error_msg = f'Conversion error: {str(e)}'
        log(error_msg, 'error')
        with conversion_lock:
            conversion_status.update({
                'active': False,
                'stage': 'error',
                'message': error_msg,
                'error': error_msg
            })
        return None

def prepare_audio_file(file_path):
    """Prepare audio file for playback"""
    file_ext = Path(file_path).suffix.lower()
    
    # Already a WAV/DAMF file
    if file_ext in ['.wav', '.atmos']:
        return {'file': file_path, 'codec': 'wav', 'converted': False}
    
    # Detect codec
    info = detect_codec(file_path)
    codec = info.get('codec', 'unknown')
    
    log(f'Detected codec: {codec} for {file_path}')
    
    # TrueHD needs conversion
    if codec == 'truehd':
        converted = convert_truehd_to_damf(file_path)
        if converted:
            return {'file': converted, 'codec': 'wav', 'converted': True, 'original': file_path}
        else:
            return {'file': None, 'codec': codec, 'converted': False, 'error': 'Conversion failed'}
    
    # Other formats can use streaming mode
    return {'file': file_path, 'codec': codec, 'converted': False}

# ==================== API Routes ====================

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
        lines = [l for l in result.stdout.strip().split('\n') if l and not l.startswith('COMMAND')]
        client_count = max(0, len(lines) - 1)
    except:
        pass
    
    # Check if audio is flowing
    fifo_flowing = False
    try:
        if os.path.exists(FIFO_PATH):
            result = subprocess.run(
                ['lsof', FIFO_PATH],
                capture_output=True, text=True
            )
            fifo_flowing = 'write' in result.stdout.lower()
    except:
        pass
    
    with playback_lock:
        playback_info = current_playback.copy()
    
    # Check if playback process is actually alive
    if playback_info.get('pid'):
        try:
            proc = psutil.Process(playback_info['pid'])
            if not proc.is_running():
                playback_info['status'] = 'idle'
        except:
            playback_info['status'] = 'idle'
    
    return jsonify({
        'timestamp': datetime.now().isoformat(),
        'pipeline': status,
        'clients': max(0, client_count),
        'fifo_exists': os.path.exists(FIFO_PATH),
        'fifo_flowing': fifo_flowing,
        'playback': playback_info
    })

@app.route('/api/start', methods=['POST'])
def start_pipeline():
    """Start the pipeline - optionally with a file to play"""
    data = request.json or {}
    file_to_play = data.get('file')
    
    try:
        # Start infrastructure
        result = _do_start_pipeline()
        
        if not result['success']:
            return jsonify(result), 500
        
        # If file provided, start playback too
        if file_to_play and os.path.exists(file_to_play):
            log(f'Auto-starting playback: {file_to_play}')
            
            channels = data.get('channels', 6)
            sample_rate = data.get('sample_rate', 48000)
            bit_depth = data.get('bit_depth', 16)
            
            # Small delay to ensure services are ready
            time.sleep(1)
            
            play_result = _do_play_file(file_to_play, channels, sample_rate, bit_depth)
            
            if play_result['success']:
                return jsonify({
                    'success': True,
                    'message': 'Pipeline started with playback',
                    'pipeline': result,
                    'playback': play_result
                })
            else:
                return jsonify({
                    'success': True,  # Pipeline still started
                    'message': 'Pipeline started but playback failed',
                    'pipeline': result,
                    'playback_error': play_result.get('error')
                }), 207  # Multi-status
        
        return jsonify(result)
        
    except Exception as e:
        log(f'Start failed: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/stop', methods=['POST'])
def stop_pipeline():
    """Stop the pipeline"""
    try:
        _do_stop_pipeline()
        return jsonify({'success': True, 'message': 'Pipeline stopped'})
    except Exception as e:
        log(f'Error stopping: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/analyze', methods=['POST'])
def analyze_file():
    """Analyze a media file"""
    data = request.json
    file_path = data.get('file')
    
    if not file_path or not os.path.exists(file_path):
        return jsonify({'success': False, 'error': 'File not found'}), 400
    
    try:
        info = detect_codec(file_path)
        cached = get_cached_damf(file_path)
        
        return jsonify({
            'success': True,
            'file': file_path,
            'codec': info['codec'],
            'channels': info['channels'],
            'sample_rate': info['sample_rate'],
            'cached_damf': cached,
            'needs_conversion': info['codec'] == 'truehd'
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/convert', methods=['POST'])
def start_conversion():
    """Start TrueHD to DAMF conversion"""
    data = request.json
    file_path = data.get('file')
    
    if not file_path or not os.path.exists(file_path):
        return jsonify({'success': False, 'error': 'File not found'}), 400
    
    with conversion_lock:
        if conversion_status['active']:
            return jsonify({
                'success': True, 
                'message': 'Conversion in progress',
                'status': conversion_status.copy()
            })
    
    def do_conversion():
        convert_truehd_to_damf(file_path)
    
    thread = threading.Thread(target=do_conversion, daemon=True)
    thread.start()
    
    return jsonify({
        'success': True,
        'message': 'Conversion started',
        'status': conversion_status.copy()
    })

@app.route('/api/convert/status')
def get_conversion_status():
    """Get conversion status"""
    with conversion_lock:
        return jsonify(conversion_status.copy())

@app.route('/api/play', methods=['POST'])
def play_file():
    """Play a media file"""
    data = request.json
    file_path = data.get('file')
    
    if not file_path or not os.path.exists(file_path):
        return jsonify({'success': False, 'error': 'File not found'}), 400
    
    channels = data.get('channels', 6)
    sample_rate = data.get('sample_rate', 48000)
    bit_depth = data.get('bit_depth', 16)
    
    result = _do_play_file(file_path, channels, sample_rate, bit_depth)
    
    if result['success']:
        return jsonify(result)
    else:
        return jsonify(result), 500

@app.route('/api/play/stop', methods=['POST'])
def stop_playback():
    """Stop current playback"""
    try:
        global pipeline_processes
        
        with process_lock:
            # Stop playback process
            if pipeline_processes.get('current_playback'):
                try:
                    proc = pipeline_processes['current_playback']
                    if is_process_alive(proc):
                        proc.terminate()
                        proc.wait(timeout=2)
                except:
                    pass
                pipeline_processes['current_playback'] = None
            
            # Kill related processes
            for proc_name in ['CavernPipeClient', 'PipeToFifo', 'ffmpeg', 'cat']:
                proc = find_process(proc_name)
                if proc:
                    try:
                        proc.terminate()
                    except:
                        pass
        
        with playback_lock:
            current_playback.update({'status': 'idle', 'file': None, 'pid': None})
        
        log('Playback stopped')
        return jsonify({'success': True, 'message': 'Playback stopped'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/config', methods=['GET', 'POST'])
def handle_config():
    """Get or update configuration"""
    config_file = CONFIG_DIR / 'speaker-layouts.json'
    user_config = Path.home() / '.cavern-wireless' / 'web-config.json'
    
    if request.method == 'GET':
        try:
            with open(config_file) as f:
                config = json.load(f)
            
            config['streaming'] = {
                'buffer_ms': STREAMING_CONFIG['buffer_ms'],
                'latency_ms': STREAMING_CONFIG['latency_ms']
            }
            
            if user_config.exists():
                with open(user_config) as f:
                    user_data = json.load(f)
                    if 'streaming' in user_data:
                        config['streaming'].update(user_data['streaming'])
            
            return jsonify(config)
        except Exception as e:
            return jsonify({'error': str(e)}), 404
    
    else:  # POST
        data = request.json
        
        if 'streaming' in data:
            STREAMING_CONFIG['buffer_ms'] = data['streaming'].get('buffer_ms', STREAMING_CONFIG['buffer_ms'])
            STREAMING_CONFIG['latency_ms'] = data['streaming'].get('latency_ms', STREAMING_CONFIG['latency_ms'])
            log(f"Updated streaming config: buffer={STREAMING_CONFIG['buffer_ms']}ms, latency={STREAMING_CONFIG['latency_ms']}ms")
        
        user_config.parent.mkdir(parents=True, exist_ok=True)
        with open(user_config, 'w') as f:
            json.dump(data, f, indent=2)
        
        return jsonify({'success': True})

@app.route('/api/logs')
def get_logs():
    """Get recent logs"""
    lines = request.args.get('lines', 100, type=int)
    with log_lock:
        return jsonify(log_buffer[-lines:])

@app.route('/api/audio-levels')
def get_audio_levels():
    """Get current audio levels"""
    import random
    import struct
    channels = request.args.get('channels', 6, type=int)
    
    levels = []
    
    try:
        if os.path.exists(FIFO_PATH):
            result = subprocess.run(
                ['dd', f'if={FIFO_PATH}', 'bs=4096', 'count=1'],
                capture_output=True, timeout=0.1
            )
            
            if result.returncode == 0 and result.stdout:
                data = result.stdout
                if len(data) >= channels * 2:
                    frame_size = channels * 2
                    num_frames = min(len(data) // frame_size, 100)
                    
                    channel_samples = [[] for _ in range(channels)]
                    
                    for i in range(num_frames):
                        frame_start = i * frame_size
                        for ch in range(channels):
                            sample_start = frame_start + ch * 2
                            if sample_start + 2 <= len(data):
                                sample = struct.unpack('<h', data[sample_start:sample_start+2])[0]
                                channel_samples[ch].append(sample)
                    
                    for ch in range(channels):
                        if channel_samples[ch]:
                            rms = (sum(s*s for s in channel_samples[ch]) / len(channel_samples[ch])) ** 0.5
                            level = min(100, (rms / 32767) * 100 * 3)
                            levels.append({
                                'channel': ch,
                                'level': level,
                                'peak': min(100, level * 1.2)
                            })
                        else:
                            levels.append({'channel': ch, 'level': 0, 'peak': 0})
                    
                    return jsonify({
                        'timestamp': datetime.now().isoformat(),
                        'channels': levels,
                        'source': 'fifo'
                    })
    except:
        pass
    
    # Fallback
    for i in range(channels):
        levels.append({
            'channel': i,
            'level': 2 + random.random() * 3,
            'peak': 5
        })
    
    return jsonify({
        'timestamp': datetime.now().isoformat(),
        'channels': levels,
        'source': 'silence'
    })

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
            'fifo_exists': os.path.exists(FIFO_PATH)
        })

@app.route('/api/stream/start', methods=['POST'])
def start_streaming():
    """Start streaming from system audio or URL"""
    data = request.json
    source = data.get('source')
    url = data.get('url')
    
    try:
        # Ensure pipeline is running
        status = is_pipeline_running()
        if not status['cavern'] or not status['snapserver']:
            result = _do_start_pipeline()
            if not result['success']:
                return jsonify(result), 500
            time.sleep(2)
        
        # Stop current playback
        if pipeline_processes.get('current_playback'):
            try:
                pipeline_processes['current_playback'].terminate()
                pipeline_processes['current_playback'].wait(timeout=2)
            except:
                pass
            pipeline_processes['current_playback'] = None
        
        channels = data.get('channels', 6)
        sample_rate = data.get('sample_rate', 48000)
        bit_depth = data.get('bit_depth', 16)
        
        env = os.environ.copy()
        env['OUTPUT_CHANNELS'] = str(channels)
        env['SAMPLE_RATE'] = str(sample_rate)
        env['BIT_DEPTH'] = str(bit_depth)
        
        client_dll = BIN_DIR / 'CavernPipeClient.dll'
        pipetofifo_dll = BIN_DIR / 'PipeToFifo.dll'
        
        if source == 'url' and url:
            log(f'Starting URL stream: {url}')
            
            ffmpeg_proc = subprocess.Popen(
                ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-re', '-i', url,
                 '-acodec', 'pcm_s16le', '-ar', str(sample_rate), '-ac', '2', '-f', 's16le', '-'],
                stdout=subprocess.PIPE,
                stderr=open(LOG_DIR / 'ffmpeg.log', 'a')
            )
            
            client_proc = subprocess.Popen(
                ['dotnet', str(client_dll), str(channels), str(sample_rate), str(bit_depth)],
                stdin=ffmpeg_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=open(LOG_DIR / 'client.log', 'a'),
                env=env
            )
            ffmpeg_proc.stdout.close()
            
            fifo_proc = subprocess.Popen(
                ['dotnet', str(pipetofifo_dll), FIFO_PATH, '2048'],
                stdin=client_proc.stdout,
                stderr=open(LOG_DIR / 'fifo.log', 'a'),
                env=env
            )
            client_proc.stdout.close()
            
            pipeline_processes['current_playback'] = fifo_proc
            
        elif source == 'system':
            log('Starting system audio capture')
            
            import platform
            os_name = platform.system()
            
            if os_name == 'Darwin':
                ffmpeg_input = ['-f', 'avfoundation', '-i', ':BlackHole 16ch']
            else:
                ffmpeg_input = ['-f', 'pulse', '-i', 'cavern_capture.monitor']
            
            ffmpeg_proc = subprocess.Popen(
                ['ffmpeg', '-hide_banner', '-loglevel', 'error'] + ffmpeg_input +
                ['-acodec', f'pcm_s{bit_depth}le', '-ar', str(sample_rate), 
                 '-ac', str(channels), '-f', f's{bit_depth}le', '-'],
                stdout=subprocess.PIPE,
                stderr=open(LOG_DIR / 'ffmpeg.log', 'a')
            )
            
            client_proc = subprocess.Popen(
                ['dotnet', str(client_dll), str(channels), str(sample_rate), str(bit_depth)],
                stdin=ffmpeg_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=open(LOG_DIR / 'client.log', 'a'),
                env=env
            )
            ffmpeg_proc.stdout.close()
            
            fifo_proc = subprocess.Popen(
                ['dotnet', str(pipetofifo_dll), FIFO_PATH, '2048'],
                stdin=client_proc.stdout,
                stderr=open(LOG_DIR / 'fifo.log', 'a'),
                env=env
            )
            client_proc.stdout.close()
            
            pipeline_processes['current_playback'] = fifo_proc
        
        with playback_lock:
            current_playback.update({
                'file': f'[Stream: {source}]',
                'codec': 'pcm',
                'status': 'playing',
                'started_at': datetime.now().isoformat(),
                'pid': fifo_proc.pid
            })
        
        threading.Thread(target=monitor_playback, daemon=True).start()
        
        return jsonify({
            'success': True,
            'message': f'Streaming started from {source}',
            'source': source
        })
        
    except Exception as e:
        log(f'Streaming failed: {e}', 'error')
        return jsonify({'success': False, 'error': str(e)}), 500

# ==================== Static Files ====================

@app.route('/')
def serve_index():
    return send_from_directory('.', 'index.html')

@app.route('/<path:path>')
def serve_static(path):
    return send_from_directory('.', path)

# ==================== Background Threads ====================

def update_metrics():
    """Background thread to update streaming metrics"""
    while True:
        try:
            now = datetime.now()
            pipeline_running = is_pipeline_running()
            
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
            
            fifo_has_data = False
            fifo_size = 0
            if os.path.exists(FIFO_PATH):
                try:
                    result = subprocess.run(
                        ['lsof', FIFO_PATH],
                        capture_output=True, text=True
                    )
                    fifo_has_data = 'write' in result.stdout.lower()
                    stat = os.stat(FIFO_PATH)
                    fifo_size = stat.st_size
                except:
                    pass
            
            is_streaming = (pipeline_running['cavern'] or pipeline_running['snapserver']) and \
                          (active_streams > 0 or fifo_has_data)
            
            bytes_streamed = metrics_data['bytes_streamed']
            speed_mbps = 0.0
            
            if is_streaming and metrics_data['last_check_time']:
                time_diff = (now - metrics_data['last_check_time']).total_seconds()
                if time_diff > 0:
                    audio_rate = 48000 * 2 * 6
                    new_bytes = int(audio_rate * time_diff)
                    bytes_streamed = metrics_data['bytes_streamed'] + new_bytes
                    speed_mbps = new_bytes / time_diff / 1024 / 1024
            
            buffer_capacity = 576000
            buffer_percent = min(100, int((fifo_size / buffer_capacity) * 100)) if fifo_size > 0 else 0
            
            with metrics_lock:
                metrics_data['bytes_streamed'] = bytes_streamed
                metrics_data['last_bytes'] = bytes_streamed
                metrics_data['last_check_time'] = now
                metrics_data['speed_mbps'] = speed_mbps
                metrics_data['buffer_size_bytes'] = fifo_size
                metrics_data['buffer_percent'] = buffer_percent
                metrics_data['active_streams'] = active_streams
                metrics_data['fifo_data_flowing'] = fifo_has_data
                
        except Exception as e:
            pass
        
        time.sleep(1)

def tail_log_file(filepath, source_name):
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
        'info': 'info', 'Info': 'info', 'INFO': 'info',
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
                
                entry = {
                    'time': datetime.now().isoformat(),
                    'level': level,
                    'message': f'[{source_name}] {line}'
                }
                
                with log_lock:
                    log_buffer.append(entry)
                    if len(log_buffer) > MAX_LOG_LINES:
                        log_buffer.pop(0)
    except:
        pass

def start_background_threads():
    """Start background threads"""
    # Metrics thread
    t = threading.Thread(target=update_metrics, daemon=True)
    t.start()
    
    # Log tail threads
    log_files = [
        (LOG_DIR / 'cavernpipe.log', 'Cavern'),
        (LOG_DIR / 'snapserver.log', 'Snapserver'),
        (LOG_DIR / 'client.log', 'Client'),
        (LOG_DIR / 'fifo.log', 'PipeToFifo'),
    ]
    
    for filepath, source in log_files:
        t = threading.Thread(target=tail_log_file, args=(filepath, source), daemon=True)
        t.start()

# ==================== Main ====================

def signal_handler(sig, frame):
    print('\nShutting down...')
    _do_stop_pipeline()
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

if __name__ == '__main__':
    print("="*50)
    print("CavernPipe Web UI Server")
    print("="*50)
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Logs: {LOG_DIR}")
    print(f"Cache: {CACHE_DIR}")
    print("")
    print("Open http://localhost:8080 in your browser")
    print("Press Ctrl+C to stop")
    print("="*50)
    
    start_background_threads()
    
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
