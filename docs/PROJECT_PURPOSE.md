
Project Specification: "Open-Atmos" Wireless Surround System
1. Executive Summary
The goal is to build a high-fidelity, wireless 7.1.4 Dolby Atmos home theater system avoiding proprietary Audio-Video Receivers (AVRs) and closed-source ecosystems (Sonos/Heos).

The system leverages Cavern for object-based decoding, Snapcast for synchronized wireless transport, and a custom ESP32-C5 + TAS5825M hardware stack for the endpoints. This architecture shifts the cost from expensive proprietary hardware to open-source software and low-cost, high-performance microcontrollers.

2. System Architecture
The signal path flows from a Windows PC (Decoding Core) to a Linux/Windows Server (Distribution), over WiFi 6, to individual speaker endpoints.

The Data Flow

Source: Media Player (VLC/MPV) plays a Dolby TrueHD/Atmos video file.

Decoding: Cavern Driver intercepts the audio stream, decoding the spatial objects (Atmos metadata) into 12 discrete PCM channels (7.1.4 configuration).

Routing: FFmpeg captures the 12-channel PCM stream and splits it into 6 stereo pairs (e.g., FL+FR, SL+SR, C+LFE).

Distribution: Snapserver ingests these stereo pairs as 6 distinct named pipes.

Transport: Audio is broadcast over 5GHz WiFi (802.11ax).

Reception: ESP32-C5 endpoints subscribe to their specific stereo stream (e.g., "Rear Surround").

Amplification: TAS5825M receives digital I2S audio, applies local DSP (crossover/EQ), and drives the speaker.

3. The Software Stack (The Brain)
A. Decoding Layer: Cavern

Role: The "Virtual AVR."

Implementation: * Use the Cavern Driver for Windows. It presents itself as a 7.1.4 sound card to the OS.

Any media player (MPC-HC, VLC) outputs to this virtual device.

Cavern performs the object rendering, mixing height channels into the bed channels if necessary, or outputting full discrete channels.

B. The Bridge: FFmpeg & Pipes

Snapcast does not natively support 12-channel audio. We must "trick" it by treating the surround system as multiple synchronized stereo zones.

Command Logic:

Bash


ffmpeg -f dshow -i "audio=Cavern Output" \
-filter_complex "[0:a]pan=stereo|c0=c0|c1=c1[front]; \
                 [0:a]pan=stereo|c0=c2|c1=c3[center_sub]; \
                 [0:a]pan=stereo|c0=c4|c1=c5[surround]; ..." \
-map "[front]" -f s16le pipe:\\.\pipe\snap_front \
-map "[center_sub]" -f s16le pipe:\\.\pipe\snap_center \
...
C. Distribution Layer: Snapserver

Role: Time-sync master and buffer manager.

Configuration: * snapserver.conf defines multiple streams, reading from the named pipes created by FFmpeg.

Latency Management: Snapserver handles the buffering. You will likely have a fixed global latency (e.g. 1000ms).

Sync: Snapserver ensures the "Front Left" packet and "Rear Right" packet play at the exact same system timestamp.

4. The Hardware Stack (The Endpoints)
This is the most innovative part of your design, utilizing the latest WiFi 6 IoT chips.

A. The Microcontroller: ESP32-C5

Why C5? The first RISC-V ESP32 with dual-band WiFi 6 (2.4/5GHz).

Benefit: 5GHz is mandatory for low-latency, uncompressed audio. 2.4GHz is too congested.

The Challenge: The C5 architecture is RISC-V. Existing snapclient ports for ESP32 are written for Xtensa (ESP32/S3).

Action Item: You must port the audio buffer handling code in snapclient to standard C++ or RISC-V assembly.

B. The Amplifier: TAS5825M

Role: Digital-input Class-D Amplifier (Stereo/Mono configurable).

Interface:

I2S: Receives the audio data (BCLK, LRCLK, DIN).

I2C: Receives control commands (Volume, Mute, DSP Init).

DSP Advantage: The TAS5825M has internal BiQuads. You can program the Crossover (High Pass for satellites, Low Pass for Sub) directly into the amp chip via I2C at boot. This saves CPU cycles on the ESP32.

5. Implementation Roadmap
Phase 1: The "Wired" Proof of Concept

Goal: Validate Cavern + Snapcast channel splitting.

Hardware: Windows PC + 2 Laptops/Phones as "clients".

Test: Install Cavern. Route audio to Snapserver. Connect phones via Snapcast App.

Success Metric: Can you hear "Left" audio on one phone and "Right" audio on the other, perfectly synchronized?

Phase 2: The ESP32 Firmware Port

Goal: Get audio out of the ESP32-C5.

Task:

Set up ESP-IDF 5.1+ (or 6.0 Preview) for C5.

Write a basic I2S driver to output a sine wave to the TAS5825M. Note: You need to send the TAS5825M init sequence via I2C first!

Port snapclient (or a lightweight UDP receiver) to the C5. Focus on the audio_output_i2s component.

Phase 3: The Assembly

PCB/wiring: Connect ESP32-C5 to TAS5825M carrier board.

Power: 12V-24V DC power supply for the Amp + Buck converter (5V) for the ESP32.

Housing: 3D print a case that mounts to the back of your speakers.

6. Critical Challenges & Mitigations
Challenge	Risk Level	Mitigation Strategy
Sync Drift	High	Use Snapcast's control protocol. Avoid generic RTP. Ensure ESP32 creates a feedback loop adjusting sample rate based on buffer fullness.
RISC-V Porting	High	If C5 porting is too hard, fall back to ESP32-S3. It has 5GHz WiFi support (on specific modules like ESP32-S3-WROOM-1U) and mature software support.
WiFi Congestion	Medium	Use a dedicated WiFi 6 Router solely for the audio system. Do not connect phones/laptops to this SSID.
Audio Delay	Low	Set a fixed buffer in Snapserver (e.g. 2000ms). Adjust "Audio Delay" in your video player (VLC/MPV) to -2000ms.
7. Conclusion
This project is technically feasible and economically disruptive. By leveraging Cavern for processing and WiFi 6 for transport, you eliminate the $1000+ AVR. The primary hurdle is software engineering: specifically, porting the synchronous audio client to the RISC-V architecture of the ESP32-C5.
