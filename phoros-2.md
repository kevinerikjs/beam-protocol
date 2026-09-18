# PHOROS 2 — APPLE-NATIVE REALTIME PEER ENGINE

You are redesigning **Phoros** from a lightweight TCP-based Apple screen-streaming protocol into a serious, ultra-low-latency, Apple-native realtime peer engine for macOS, iOS, iPadOS, tvOS, and visionOS.

The intended result is not “rewrite WebRTC in Swift.”

The intended result is:

> **Take the networking ideas WebRTC has spent years getting right, use an existing high-quality Rust WebRTC transport engine where possible, preserve Phoros’s exceptionally simple Apple-native API and media integration, and optimize the whole system specifically for interactive Apple-device streaming.**

The likely architecture is:

* Swift for Apple frameworks and public API.
* VideoToolbox for video encode/decode.
* ScreenCaptureKit for macOS capture.
* Core Audio / AudioToolbox / AVFAudio for audio.
* GameController / CoreGraphics / IOKit for input.
* Bonjour / Network.framework where they make sense.
* Rust for the realtime transport engine.
* **str0m** as the first transport-engine candidate.
* A very small C ABI / FFI boundary between Swift and Rust.
* UDP/WebRTC media transport rather than TCP for realtime media.
* WebRTC-style congestion control, pacing, retransmission, feedback, encryption, clocking, and loss recovery.
* A Phoros-specific API that hides WebRTC concepts entirely from application developers.

Do not expose WebRTC jargon unless absolutely necessary.

The public mental model should remain:

```swift
let host = PhorosHost(...)
let client = PhorosClient(...)

let session = try await client.connect(to: host)

session.video
session.audio
session.input
session.metrics
```

not:

```text
RTCPeerConnection
SDP
ICE candidates
RTCRtpTransceiver
RTCRtpSender
RTCDataChannel
```

WebRTC may exist underneath. It should not infect the Phoros API.

---

# 1. FIRST: UNDERSTAND PHOROS V1

Before writing code, inspect the entire current repository.

Read:

* Package.swift
* README
* wire-format docs
* session docs
* compatibility docs
* media docs
* input docs
* security docs
* all tests
* `PhorosConnection`
* `SendScheduler`
* `FrameAssembler`
* `QualityLadder`
* `RoundTripProbe`
* `VideoEncoder`
* video decoder / sample-buffer creation
* AAC encoder and decoder
* pairing/authentication
* controller sampling
* virtual HID gamepad
* keyboard/click/text/media-key paths

Do not discard the production lessons represented by these types.

Phoros v1 contains valuable application-layer work that WebRTC does not solve:

* Apple-device pairing.
* Capability negotiation.
* Codec capability handling.
* Window/source selection.
* Screen geometry mapping.
* Tap-to-source coordinate conversion.
* Keyboard replay.
* Text input.
* Mouse clicks.
* Media keys.
* GameController sampling.
* Virtual HID controller creation.
* Pause/resume semantics.
* Parameter-set recovery.
* Conservative compatibility behavior.
* Versioning rules.
* Audio clock lessons.
* Keyframe recovery behavior.
* Remote-display-specific Swift APIs.

The redesign should preserve those lessons while replacing the weak transport architecture underneath them.

Treat current behavior and tests as valuable regression fixtures.

---

# 2. WHY PHOROS 2 EXISTS

The current architecture is roughly:

```text
ScreenCaptureKit
       ↓
VideoToolbox
       ↓
custom H264/HEVC framing
       ↓
SendScheduler
       ↓
TCP / NWConnection
       ↓
FrameAssembler
       ↓
VideoToolbox
       ↓
display
```

Control goes in the reverse direction over the same conceptual protocol.

This design is wonderfully simple but has a fundamental mismatch with interactive media.

TCP guarantees:

```text
ordered
reliable
eventually delivered
```

Interactive streaming often wants:

```text
latest
deadline-sensitive
discard stale information
continue despite loss
```

If part of an old video frame disappears, we often prefer:

```text
drop stale frame 100
show frame 101 immediately
```

rather than:

```text
stall 101 until missing bytes from 100 are retransmitted
```

That distinction is the core motivation for Phoros 2.

The target is not maximum data integrity.

The target is:

> **minimum motion-to-photon latency while maintaining acceptable visual/audio quality.**

---

# 3. IMPORTANT CURRENT PHOROS V1 FINDINGS

Verify each of these against current source before modifying anything.

Do not treat this prompt as more authoritative than the repository.

## 3.1 SendScheduler backlog accounting may not mean what it claims

Current `SendScheduler` maintains:

```text
control[]
audio[]
video[]

bytesInFlight
audioBytesInFlight
writesInFlight
```

The video admission decision is based primarily on `bytesInFlight`.

But `bytesInFlight` counts buffers that have already been dequeued and handed to the transport.

It does not appear to count the potentially large amount of video data still sitting in the internal `video[]` queue.

Current defaults are approximately:

```text
maximumQueuedBytes = 192 KB
maximumConcurrentWrites = 8
```

The documented host path fragments video around ~1400-byte payloads.

Therefore, depending on exactly how the scheduler is used, only something on the order of:

```text
8 × ~1.4 KB ≈ ~11 KB
```

may be represented by the in-flight counter at once, while considerably more data could remain queued internally.

Investigate this carefully.

Do not simply patch the threshold.

Instrument:

```text
queued bytes
queued frames
oldest queued frame age
transport-accepted bytes
socket/send-buffer state if measurable
encoded frame production rate
actual network departure rate
```

A realtime scheduler should primarily care about **age/deadline**, not just bytes.

---

# 4. THE CENTRAL DESIGN PRINCIPLE: DEADLINES, NOT QUEUES

Phoros 2 should become **deadline-aware end to end**.

Every realtime unit should conceptually have:

```text
capture time
media timestamp
enqueue time
deadline / maximum useful age
priority
reliability policy
```

A video frame that is already too old should not consume:

```text
encoder time
packetizer capacity
network bandwidth
decoder time
display queue space
```

merely because it exists.

The engine should constantly ask:

> “Is this piece of information still useful?”

Examples:

### Video delta frame

```text
reliability: best effort / selective retransmission
deadline: very short
stale behavior: drop
```

### Video keyframe

```text
reliability: higher importance
deadline: still bounded
stale behavior: request/produce a newer keyframe rather than endlessly rescuing an ancient one
```

### Pointer position

```text
reliability: latest-value-wins
ordered: unnecessary
retransmit: no
```

### Controller axis state

```text
reliability: latest-value-wins
ordered: unnecessary
retransmit: no
```

### Keyboard down/up

```text
reliability: reliable
ordered: usually yes
```

### Mouse/controller button transitions

```text
reliability: reliable
```

### Clipboard

```text
reliable
```

### Session negotiation

```text
reliable
```

### Audio

```text
deadline-sensitive
small jitter tolerance
generally do not allow ancient audio packets to create huge latency
```

Make semantic delivery policy part of Phoros itself.

Possible API:

```swift
enum PhorosDelivery {
    case realtime
    case latest
    case reliable
}
```

or something richer.

Do not force applications to understand SCTP/WebRTC transport settings.

---

# 5. USE STR0M AS THE FIRST PHOROS 2 TRANSPORT ENGINE

Investigate current `str0m` before committing architecture.

The reason it is interesting is not merely that it is Rust WebRTC.

Its architecture matches Phoros unusually well.

str0m is Sans-I/O:

```text
no internal socket ownership
no mandatory async runtime
no hidden network thread
network packets go in
network packets come out
timeouts go in/out
application drives the state machine
```

That means Phoros can decide how networking integrates with Apple platforms.

It also exposes a frame-level media API.

The desired architecture is:

```text
VideoToolbox encoded complete frame
                ↓
        Phoros Swift API
                ↓
            narrow FFI
                ↓
             str0m
                ↓
        RTP packetization
        sequencing
        pacing
        TWCC
        congestion control
        NACK/retransmission
        RTCP
        SRTP encryption
        ICE/DTLS
                ↓
               UDP
```

Receive:

```text
UDP
 ↓
str0m
 ↓
depacketization / reordering / recovery
 ↓
complete encoded frame
 ↓
FFI
 ↓
Swift
 ↓
VideoToolbox decode
```

This is exactly the boundary Phoros wants.

Phoros should not normally manipulate RTP packets itself.

---

# 6. DO NOT FORK OR REIMPLEMENT STR0M PREMATURELY

The goal is not:

```text
read str0m
copy algorithms
write phoros-rtc from scratch
```

Start with:

```text
PhorosCore
    ↓
str0m
```

Only replace parts if measurements prove there is a concrete reason.

Prefer:

```text
upstream contribution
```

over:

```text
private fork forever
```

when practical.

Create a transport abstraction around it so Phoros is not permanently coupled to str0m internals.

For example:

```swift
protocol PhorosRealtimeTransport {
    func sendVideo(_ frame: EncodedVideoFrame)
    func sendAudio(_ frame: EncodedAudioFrame)
    func sendRealtime(_ data: ...)
    func sendReliable(_ data: ...)
}
```

The exact public abstraction may differ.

Internally there can eventually be:

```text
PhorosRTCTransport        ← str0m
PhorosLegacyTCPTransport  ← v1 compatibility
PhorosExperimentalQUIC    ← future research
```

Do not design this abstraction so generically that it becomes meaningless.

Design it around Phoros’s actual semantics.

---

# 7. RUST/SWIFT RESPONSIBILITY BOUNDARY

Keep Apple-specific media functionality in Swift.

## SWIFT SHOULD OWN

```text
ScreenCaptureKit
VideoToolbox compression
VideoToolbox decompression
CoreMedia
CoreVideo
AudioToolbox / AVFAudio
GameController
CoreGraphics / CGEvent
IOKit virtual HID
UIKit / AppKit / SwiftUI
Bonjour
Keychain
Apple lifecycle
permissions
screen selection
window selection
display rendering
```

Do not wrap ScreenCaptureKit from Rust merely because Rust exists.

That makes maintenance worse for little benefit.

## RUST SHOULD OWN

```text
str0m/WebRTC state
packetization
depacketization
RTP/RTCP
TWCC
bandwidth estimation
congestion control
pacing
selective retransmission
NACK handling
keyframe request signaling
ICE
DTLS
SRTP
data-channel transport
network feedback state
packet sequence tracking
RTT/loss measurements
transport metrics
realtime scheduling state that belongs near packets
```

Rust is valuable here because this is protocol/state-machine/buffer-heavy systems code.

Swift itself is not intrinsically too slow.

This split is about architecture and ecosystem, not language mythology.

---

# 8. FFI DESIGN

Consumers of the Swift package should not need Rust installed.

Build Rust into binaries distributed by SwiftPM.

Likely:

```text
Rust crate
    ↓
static libraries per Apple architecture
    ↓
XCFramework
    ↓
SwiftPM binary target
    ↓
Swift wrapper target
```

Target at least:

```text
arm64-apple-macos
x86_64-apple-macos where still supported

arm64-apple-ios
arm64-apple-ios-simulator
x86_64 simulator if deployment/support policy needs it

appropriate tvOS / visionOS targets
```

Investigate current supported Rust targets and deployment constraints rather than assuming this list.

Use a tiny stable C-compatible ABI for the hot path.

Example conceptually:

```c
phoros_peer_t *phoros_peer_create(...);

void phoros_peer_receive_datagram(
    phoros_peer_t *,
    const uint8_t *bytes,
    size_t length,
    uint64_t receive_time_ns
);

void phoros_peer_send_video(
    phoros_peer_t *,
    const uint8_t *bytes,
    size_t length,
    uint64_t media_time,
    bool keyframe
);
```

Do not expose Rust types over ABI.

Do not expose C types publicly to normal Swift consumers.

Wrap everything.

For high-level configuration and uncommon control paths, UniFFI may be worth evaluating.

For the media hot path, prefer deliberately designed low-copy FFI.

Measure every copy.

---

# 9. ZERO/LOW-COPY MEDIA PATH

Avoid this:

```text
CMBlockBuffer
 ↓ copy
Swift Data
 ↓ copy
FFI generated representation
 ↓ copy
Rust Vec
 ↓ copy
packetizer
```

Aim for:

```text
VideoToolbox
 ↓
CMBlockBuffer / encoded bytes
 ↓
borrowed pointer + length
 ↓
C ABI
 ↓
Rust consumes during call / controlled ownership handoff
 ↓
str0m packetization
```

On receive:

```text
str0m reconstructed encoded frame
 ↓
stable frame buffer
 ↓
FFI callback / pull API
 ↓
CMBlockBuffer or compatible Swift representation
 ↓
VideoToolbox
```

Be extremely explicit about:

```text
ownership
lifetime
threading
copy count
allocation count
```

Do not invent unsafe zero-copy APIs merely to say “zero copy.”

One predictable copy can be better than fragile lifetime machinery.

Benchmark first.

---

# 10. STR0M RUN LOOP MUST BE CORRECT

str0m has important state-machine/run-loop invariants.

Study them.

Do not wrap it casually.

Design one owner/executor for each peer.

Conceptually:

```text
event arrives
 ↓
mutate Rtc
 ↓
drain all generated outputs
 ↓
send network outputs
 ↓
schedule requested timeout
 ↓
wait for next event
```

Events can include:

```text
incoming UDP datagram
media frame from Swift
input data from Swift
timer firing
ICE update
configuration change
```

Avoid races from multiple Swift queues calling mutable Rust state simultaneously.

Prefer a clearly serialized peer core.

This may be:

```text
dedicated Rust worker thread
```

or:

```text
Swift serial executor feeding Sans-I/O core
```

or another measured design.

The goal is predictable latency, not ideological purity.

---

# 11. NETWORK SOCKET OWNERSHIP: BENCHMARK TWO DESIGNS

Because str0m is Sans-I/O, there are two plausible designs.

## OPTION A — Network.framework owns UDP

```text
NWConnection / NWListener / UDP
              ↕
             Swift
              ↕
             FFI
              ↕
            str0m
```

Advantages:

* Native Apple networking lifecycle.
* Path monitoring.
* Interface changes.
* Local-network permission integration.
* Bonjour integration.
* Swift ownership.
* Less Rust platform networking code.

Potential disadvantage:

* one FFI crossing / data bridge per packet.

## OPTION B — Rust owns UDP socket

```text
Rust UDP socket
     ↕
   str0m
```

Advantages:

* tighter packet loop.
* potentially fewer copies/crossings.

Disadvantages:

* more platform integration complexity.
* path/lifecycle integration may be worse.
* harder Swift ownership model.

Prototype both if necessary.

Do not guess that FFI per packet is expensive enough to matter.

Measure.

At typical realtime packet rates, it may be entirely irrelevant compared with encode/decode/display delays.

---

# 12. CONNECTION / DISCOVERY MODEL

Phoros should remain delightfully simple on a LAN.

The desired user experience is roughly:

```text
Mac advertises via Bonjour
        ↓
iPhone discovers Mac
        ↓
pair once
        ↓
tap connect
        ↓
secure direct UDP session
```

No cloud account.

No mandatory signaling server.

WebRTC does not inherently require a centralized signaling server.

Signaling is simply information exchange.

For LAN Phoros, use a small bootstrap path.

Possible design:

```text
Bonjour discovery

        ↓

authenticated bootstrap connection
(existing TCP path or a replacement)

        ↓

exchange:
ICE information
DTLS fingerprint / session identity
capabilities
codec preferences
pairing transcript
session metadata

        ↓

establish direct str0m UDP transport

        ↓

move realtime media/control onto RTC transport
```

Do not expose SDP to the user API.

If str0m's direct negotiation API cleanly fits two Phoros-native peers, investigate using that instead of serializing full browser-oriented SDP.

But do not reject SDP internally simply because it looks ugly.

Internal ugliness that buys protocol correctness is acceptable.

---

# 13. SECURITY MUST BE BETTER THAN V1

Phoros 2 transport should be encrypted by default.

Media and realtime data should use established WebRTC security primitives where str0m provides them:

```text
DTLS
SRTP
SCTP/data-channel security as appropriate
```

Do not create custom crypto.

Existing paired secrets should not simply cross the network as plaintext authentication tokens.

Design a real v2 pairing/authentication transcript.

One plausible model:

```text
paired devices already share secret K

new session:
host nonce
client nonce
session ID
negotiated fingerprints / identities

derive or compute:
HMAC(K, transcript)
```

Authenticate the handshake and bind the secure transport identity/fingerprint to the paired identity.

Goals:

* passive LAN observer cannot read the stream.
* active LAN attacker cannot impersonate an already-paired host.
* shared pairing secret is never transmitted directly.
* replayed authentication messages fail.
* protocol downgrade is detectable.
* old v1 peers continue to behave according to explicitly documented compatibility rules.

Have the design reviewed carefully.

Do not invent cryptographic constructions if established ones fit.

---

# 14. MEDIA CODECS

## VIDEO

Prioritize:

```text
HEVC / H.265
H.264 fallback
```

for Apple-to-Apple sessions.

Verify current str0m H.265 support and exact expected bitstream format.

Determine whether `Writer::write` expects:

```text
Annex B
length-prefixed NAL units
another representation
```

for each codec/version.

Do not assume.

Make parameter-set behavior explicit.

Keep codec negotiation conservative.

If one peer cannot decode HEVC:

```text
H.264
```

should remain straightforward.

Future codecs may be added later.

Do not make AV1/VP9 a requirement for v2.

## AUDIO

Reconsider AAC for the RTC path.

WebRTC transports commonly use Opus, and current str0m APIs support Opus.

Apple platforms expose Opus as a Core Audio format.

Investigate a native Apple Opus encode/decode path using:

```text
AudioConverter
AudioToolbox
Core Audio
```

Measure:

```text
encode latency
decode latency
frame duration
CPU
quality
packetization
clock behavior
```

Potentially use:

```text
48 kHz
stereo where appropriate
small frame duration suitable for low latency
```

Do not choose settings merely because voice-chat defaults use them.

This is computer/system/game audio.

If maintaining AAC has compelling advantages, investigate custom RTP payload support separately.

Do not distort str0m just to preserve AAC compatibility unless measurements justify it.

V1 can continue using AAC.

V2 does not need to preserve every internal choice from v1.

---

# 15. FIX VIDEO ENCODER LATENCY BEFORE BLAMING NETWORKING

The current encoder already does useful things:

```text
hardware encoder
RealTime = true
AllowFrameReordering = false
no B-frame latency
controlled keyframe interval
target bitrate
```

Keep those.

But explicitly investigate Apple’s low-latency encoding features.

In particular evaluate:

```text
kVTVideoEncoderSpecification_EnableLowLatencyRateControl
```

and the appropriate low-latency/video-conferencing compression presets or relevant supported configuration.

Also investigate:

```text
kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality
```

where supported and appropriate.

Do not simply enable every “low latency” property.

Query supported properties.

Benchmark quality and latency.

Create a dedicated profile:

```swift
VideoEncoderProfile.interactiveStreaming
```

whose objective is not archival quality.

It should optimize:

```text
motion-to-photon latency
predictable encode time
hardware encoding
rapid bitrate adjustment
no frame reordering
bounded queue depth
```

---

# 16. DO NOT RECREATE THE ENCODER FOR EVERY BITRATE CHANGE

Current coarse quality adaptation may recreate/reconfigure sessions when changing large quality presets.

Phoros 2 should distinguish:

```text
bitrate adaptation
```

from:

```text
resolution/FPS adaptation
```

Congestion control should continuously influence target bitrate.

Example:

```text
estimated safe rate:
12.0 Mbps
10.7 Mbps
9.8 Mbps
10.4 Mbps
11.3 Mbps
```

Prefer updating VideoToolbox target bitrate dynamically when supported rather than restarting the encoder.

Only step:

```text
1080p60
→ 1080p45
→ 900p60
→ 720p60
...
```

when sustained conditions justify a structural change.

The exact ladder should emerge from measurement.

Do not blindly preserve the old:

```text
quality scalar
wait seconds
step entire preset
```

model.

---

# 17. WEBRTC-STYLE CONGESTION CONTROL

This is one of the primary reasons to use str0m.

Current Phoros quality adaptation should not pretend to be a congestion controller.

Phoros 2 needs transport feedback driving sender behavior.

Use str0m’s current TWCC/GCC implementation if stable for our requirements.

Understand:

```text
delay trend
packet arrival timing
RTT
packet loss
available bitrate estimate
pacer behavior
probe behavior
send rate
queue delay
```

Expose a Phoros-level abstraction such as:

```swift
session.network.availableOutgoingBitrate
session.network.rtt
session.network.lossRate
session.network.queueDelay
```

Do not expose TWCC internals unless useful for diagnostics.

Feed the estimated bitrate into a **media allocator**.

Something like conceptually:

```text
available capacity
    ↓
reserve audio
    ↓
reserve control
    ↓
video target bitrate
    ↓
VideoToolbox
```

Avoid oscillating the encoder.

Use smoothing/hysteresis where needed.

But do not introduce multi-second sluggishness into bitrate response.

---

# 18. PACING

Do not let the encoder emit a giant keyframe and dump it into the socket instantly.

Use packet pacing.

Keyframes should be spread according to the available send rate.

Otherwise one keyframe can produce:

```text
socket burst
Wi-Fi queue
bufferbloat
audio delay
input-feedback delay
```

If str0m provides pacing, use and understand it.

Do not add an independent competing Swift pacer unless required.

Measure:

```text
packet burst size
pacer queue age
pacer queue bytes
network queue delay
```

Phoros should prefer dropping/replacing stale media before allowing pacer queue delay to grow excessively.

---

# 19. SELECTIVE RETRANSMISSION

Do not recover video like TCP.

Use media-aware retransmission.

For missing RTP packets:

```text
NACK if recovery can still beat the frame deadline
```

Otherwise:

```text
skip
```

If decoder recovery requires it:

```text
request keyframe
```

Do not waste bandwidth rescuing an old frame after a newer one would be more useful.

str0m already has relevant machinery.

Use it before inventing custom logic.

Keyframe requests must connect cleanly to:

```swift
VideoEncoder.requestKeyframe()
```

The transport should be able to tell Swift:

```text
receiver needs refresh frame now
```

---

# 20. JITTER / REORDERING

For video, do not build a huge playback jitter buffer by default.

This is remote interaction, not Netflix.

Target minimal buffering sufficient for:

```text
normal Wi-Fi reordering
brief jitter
packet recovery
decode continuity
```

Expose tunable latency modes if useful:

```swift
.interactive
.balanced
.quality
```

But default Phoros to interactive behavior.

For audio, a small adaptive jitter buffer may be needed.

Audio needs a different policy than video because gaps and timing discontinuities are perceptually different.

Implement and measure audio carefully rather than treating it as another video stream.

---

# 21. CLOCKING AND A/V SYNC

A/V synchronization must not create excessive latency.

Keep separate concepts:

```text
capture timestamp
media timestamp
network arrival
decode completion
presentation time
```

Design clock synchronization deliberately.

We need to know:

```text
host monotonic time
client monotonic time
estimated clock offset
RTT
```

Add periodic clock probes if WebRTC timing does not already expose everything needed at Phoros level.

Phoros should be able to answer:

```text
this frame was captured X ms ago
```

on the receiver.

That single number is extraordinarily useful for latency control.

When latency grows, the receiver should be able to prefer catching up over faithfully presenting stale frames.

---

# 22. RECEIVER DISPLAY PATH IS CRITICAL

Do not assume network latency is the whole problem.

Investigate current:

```text
receive
reassemble
create CMSampleBuffer
VTDecompressionSession
AVSampleBufferDisplayLayer
CoreAnimation
display refresh
```

Instrument every stage.

`AVSampleBufferDisplayLayer` may schedule according to timestamps and maintain internal queues.

For interactive streaming investigate:

```text
kCMSampleAttachmentKey_DisplayImmediately
```

and modern `sampleBufferRenderer` behavior/APIs.

Determine whether immediate-display attachments produce lower stable latency without visual problems.

Monitor renderer readiness.

Never feed the renderer a pile of stale frames merely because they decoded successfully.

Possible policy:

```text
if decoded frame age > threshold:
    discard before display
```

If the renderer itself becomes backed up:

```text
flush stale queued media
resume from latest decodable frame
request keyframe if necessary
```

This behavior needs real-device testing.

---

# 23. MOTION-TO-PHOTON TELEMETRY MUST BE FIRST-CLASS

This is mandatory.

Before major architectural work, build observability.

For every video frame assign a stable ID.

Track timestamps such as:

```text
t0 screen/capture timestamp
t1 frame accepted by encoder
t2 VideoToolbox encoded frame callback
t3 frame submitted to RTC engine
t4 first packet sent
t5 last packet sent
t6 first packet received
t7 complete frame reconstructed
t8 frame submitted to decoder
t9 decoder callback
t10 frame enqueued to display
t11 best available approximation of actual presentation
```

Not every timestamp must cross the network.

But Phoros should ultimately expose metrics such as:

```swift
struct PhorosLatencyMetrics {
    var captureToEncode: Duration
    var encode: Duration
    var senderQueue: Duration
    var network: Duration
    var receiverReassembly: Duration
    var decode: Duration
    var displayQueue: Duration

    var estimatedGlassToGlass: Duration
    var rtt: Duration
}
```

For input-driven applications also track:

```text
input sample
input packet send
host input injection
resulting visual change capture
resulting frame display
```

Eventually create an automated input-to-photon benchmark.

Without telemetry, every optimization is guesswork.

---

# 24. BUILD A LATENCY HUD

For development builds, add an optional overlay:

```text
FPS
capture FPS
encode FPS
bitrate
available bitrate
RTT
packet loss
NACK rate
keyframe rate
pacer queue ms
video frame age
decode ms
display queue ms
estimated glass-to-glass latency
dropped-before-encode
dropped-before-send
dropped-in-network/recovery
dropped-before-display
```

Make it trivial to screenshot during testing.

Also provide structured logs suitable for Instruments or offline graphing.

---

# 25. USE OS SIGNPOSTS / INSTRUMENTS

Add signposts for:

```text
capture
encode
transport enqueue
packet output
packet input
frame reconstructed
decode
render enqueue
input receive
input inject
```

Make Phoros pleasant to profile in Instruments.

Do not require adding random print statements to understand latency.

---

# 26. SCREEN CAPTURE PIPELINE

Inspect Beam’s actual ScreenCaptureKit configuration.

Possible sources of latency include:

```text
SCStream queueDepth
minimumFrameInterval
capture resolution
pixel format
callback queue
frame filtering
extra copies
late frame handling
```

For interactive mode, prefer a shallow capture queue.

If ScreenCaptureKit provides frames faster than downstream can consume them:

```text
drop old frame
```

rather than:

```text
build queue
```

The newest screen state is almost always more valuable.

Implement latest-frame semantics between capture and encoder.

If encoder is busy:

```text
replace pending uncoded frame with newer one
```

where technically safe.

Do not encode frames that are already stale.

---

# 27. INPUT PATH

The user has clarified that controller input itself appears responsive on the physical Mac display.

Therefore do not prematurely rewrite controller input assuming it causes the perceived lag.

The perceived controller latency is likely largely:

```text
controller
 ↓
Mac game receives input
 ↓
screen changes
 ↓
capture
 ↓
encode
 ↓
network
 ↓
decode
 ↓
display
```

i.e. video motion-to-photon delay.

Still improve input semantics in v2.

Use:

### Latest-value delivery

```text
joystick axes
pointer position
gyro
touch movement
scroll velocity
```

Old states should be replaceable.

### Reliable transition delivery

```text
key down
key up
mouse down
mouse up
controller button transitions
controller connect/disconnect
```

Be careful with controller representation.

A periodic complete controller-state report may naturally recover lost transitions, but discrete events may have different semantics.

Design intentionally.

Do not assume every input event deserves reliable ordered delivery.

---

# 28. DATA CHANNEL DESIGN

Map Phoros semantics onto WebRTC data channels/SCTP rather than exposing raw SCTP choices.

Possible channels:

```text
sessionReliable
inputReliable
inputRealtime
telemetry
```

or possibly fewer channels if ordering interactions are better managed another way.

Investigate str0m’s current data-channel support:

```text
ordered
unordered
max retransmits
partial reliability
```

Use appropriate modes.

For `latest` data, if partial-reliability semantics are not sufficient, implement application-level sequence numbers:

```text
axis report sequence 500
axis report sequence 501
```

Receiver discards older sequence numbers.

Never let stale pointer/controller movement queue for hundreds of milliseconds.

---

# 29. FRAME DROPPING POLICY

Create a coherent drop policy.

Frames may be dropped:

```text
before encode
after encode / before transport
inside congestion-controlled sender
at receiver before decode
after decode / before display
```

Each has different cost.

Generally prefer earliest possible drop.

If frame is already obsolete:

```text
drop before expensive encode
```

If encoded frame has missed its network deadline:

```text
drop before packetization
```

If receiver receives a complete but ancient frame:

```text
possibly skip decode
```

If decoded frame is obsolete:

```text
do not enqueue it merely for completeness
```

However:

* preserve decoder reference requirements.
* do not drop frames in ways that corrupt inter-frame decode state.
* distinguish keyframes/reference structure correctly.
* request refresh when needed.

The system should remain visually recoverable.

---

# 30. KEYFRAMES

Current fixed ~2 second keyframes are simple but potentially expensive.

Investigate more intelligent behavior.

Potential strategy:

```text
normal operation:
longer keyframe interval

force keyframe when:
receiver joins
decoder reports failure
PLI/FIR/keyframe request arrives
resolution changes
codec session restarts
stream resumes
major packet-loss recovery requires it
```

Screen content can produce large keyframes, which can cause network bursts.

Use pacing.

Consider whether periodic safety keyframes are still useful.

Measure.

---

# 31. BITRATE CONTROL SHOULD TALK DIRECTLY TO VIDEOTOOLBOX

Build an adaptation controller something like:

```text
str0m estimated capacity
          ↓
Phoros media allocator
          ↓
target video bitrate
          ↓
VTCompressionSession property update
```

Reserve bandwidth for:

```text
audio
control
transport overhead
```

Add a safety margin.

Do not simply tell VideoToolbox to consume 100% of estimated bandwidth.

Avoid oscillation.

Potential conceptual formula:

```text
videoBudget =
    estimatedAvailableRate
    - audioRate
    - protocolOverhead
    - safetyMargin
```

The exact algorithm should be tuned experimentally.

---

# 32. QUALITY LADDER BECOMES SECONDARY

Retain the idea of a quality ladder, but make it a **structural fallback**, not the primary congestion controller.

Example:

```text
1080p60 HEVC
1080p45 HEVC
900p60 HEVC
720p60 HEVC
720p45 HEVC
720p30 HEVC
```

Do not assume this exact ladder is correct.

Use bitrate adaptation continuously within a tier.

Move between tiers only for sustained inability to maintain acceptable:

```text
quality
bitrate
frame delivery
queue latency
```

Step down faster than step up.

But “faster” should likely mean hundreds of milliseconds / a small number of feedback windows where appropriate, not necessarily the multi-second v1 behavior.

Benchmark.

---

# 33. TRANSPORT QUEUE AGE IS MORE IMPORTANT THAN BYTE COUNT

Track:

```text
oldest unsent packet age
oldest unsent video frame age
pacer queue duration
```

Do not merely track:

```text
queue bytes
```

A 200 KB queue is completely different at:

```text
1 Mbps
```

versus:

```text
30 Mbps
```

Use time-domain latency metrics.

If queue delay exceeds the interactive budget:

```text
shed stale media
reduce encoder bitrate
possibly reduce frame rate
```

---

# 34. AUDIO PRIORITY

Do not allow giant video bursts to destroy audio continuity.

But also do not build huge audio buffers.

The sender media allocator should reserve sufficient audio bandwidth.

Packets should be paced intelligently.

Audio latency target should be bounded.

If audio falls dramatically behind:

```text
catch up rather than replaying seconds of stale sound
```

while avoiding jarring discontinuities where possible.

Implement this based on measurement.

---

# 35. V1 TCP TRANSPORT SHOULD SURVIVE AS A COMPATIBILITY / BASELINE PATH

Do not delete it immediately.

Rename/reframe it as something like:

```text
PhorosLegacyTransport
```

or internally equivalent.

Reasons:

1. It gives a known baseline.
2. It helps regression testing.
3. Existing Beam/Beacon versions may rely on it.
4. It allows side-by-side latency tests.
5. It helps prove whether v2 is actually better.

Phoros 2 should be able to run A/B tests:

```text
same Mac
same iPhone
same capture settings

V1 TCP
vs
V2 RTC
```

with identical instrumentation.

This is essential.

---

# 36. WIRE COMPATIBILITY

Phoros historically values wire compatibility strongly.

Do not silently mutate v1 bytes to mean new things.

Phoros 2 may need a new protocol family.

Possible negotiation:

```text
Bonjour metadata:
phoros=2

bootstrap:
supportedTransports = [
    rtc2,
    tcp1
]
```

Then:

```text
new ↔ new:
RTC v2

new ↔ old:
TCP v1

old ↔ new:
TCP v1
```

If that is feasible.

Document exactly what happens for each pairing.

Create fixtures.

A major version does not justify ambiguous bytes.

---

# 37. PUBLIC API GOAL

The eventual public API should feel astonishingly simple.

Conceptually:

```swift
let host = PhorosHost(
    video: .screen(display),
    audio: .system
)

try await host.start()
```

Client:

```swift
let session = try await Phoros.connect(to: discoveredHost)

RemoteView(session: session)
```

Input:

```swift
session.input.send(.pointer(...))
session.input.send(.keyboard(...))
session.input.send(.controller(...))
```

Metrics:

```swift
session.metrics.rtt
session.metrics.videoBitrate
session.metrics.motionToPhoton
```

Advanced callers can inject their own encoded streams.

For example:

```swift
session.videoSender.send(encodedFrame)
```

But the normal path should remain easy.

---

# 38. DO NOT MAKE PHOROS A VIDEOCALL SDK

Phoros’s specialization is an advantage.

Optimize around:

```text
one host
one interactive viewer
screen content
high frame rate
hardware Apple codecs
remote input
LAN-first
low latency
Apple devices
```

Do not spend enormous complexity supporting:

```text
12-person conferencing
active speaker detection
grid layout
recording bots
MCU mixing
browser compatibility
SFU topology
```

unless a real future requirement demands it.

This is how Phoros can remain dramatically simpler than libwebrtc while benefiting from WebRTC transport engineering.

---

# 39. INTERNET SUPPORT SHOULD BECOME POSSIBLE, NOT MANDATORY

LAN is first.

But do not architect v2 so internet use is impossible.

A future path can add:

```text
STUN
TURN
relay
remote signaling
```

because the underlying RTC transport already understands ICE.

For LAN-only operation:

```text
host candidates
Bonjour discovery
direct UDP
```

should be enough in common cases.

The package should not require a cloud service.

---

# 40. DO NOT BUILD CUSTOM QUIC/UDP YET

Keep the possibility open.

A future custom Phoros transport might use:

```text
QUIC reliable streams
+
QUIC datagrams
```

or raw UDP with custom media protocol.

But str0m/WebRTC should be the baseline first.

Custom QUIC would still require Phoros to implement:

```text
media packetization
deadline-aware recovery
NACK policy
keyframe requests
bandwidth estimation
pacing
jitter/reordering
clock sync
possibly FEC
```

Those are the hard parts.

QUIC by itself does not solve them.

Only pursue custom transport if measurements demonstrate a concrete limitation in the RTC approach.

---

# 41. BENCHMARKS BEFORE AND AFTER EVERY MAJOR CHANGE

Build repeatable benchmarks.

## Local wired / ideal

Where possible:

```text
Mac Ethernet
iPhone/iPad strong network
minimal loss
```

This estimates pipeline floor.

## Excellent Wi-Fi

Typical same-room Wi-Fi.

## Congested Wi-Fi

Introduce competing traffic.

## Artificial packet loss

Test approximately:

```text
0.1%
0.5%
1%
2%
5%
```

or appropriate measured scenarios.

## Jitter

Inject variable latency.

## Bandwidth reductions

For example:

```text
30 Mbps
15 Mbps
8 Mbps
5 Mbps
3 Mbps
```

## Burst loss

Important because Wi-Fi loss is not always independent random loss.

Measure:

```text
median
p90
p95
p99
```

not only averages.

---

# 42. TARGET METRICS

Do not treat these as guaranteed requirements until hardware measurements establish what is realistic.

Use them as aspirational engineering goals.

On a modern Mac + modern iPhone/iPad on excellent LAN:

```text
1080p60
hardware HEVC where available

capture → encode:
single-digit to low-teens ms

network:
a few ms on strong LAN

decode:
single-digit to low-teens ms

display buffering:
near one refresh or less where possible

motion-to-photon:
target < 50 ms
stretch target around 30–40 ms
```

More importantly:

```text
latency should remain bounded
```

when bandwidth temporarily drops.

A system that goes:

```text
35 ms
35 ms
40 ms
45 ms
DROP
38 ms
```

is preferable for interactive use to:

```text
35
50
80
150
300
700
1200 ms
```

even if the latter technically delivers every frame.

---

# 43. FAILURE / RECOVERY TESTS

Explicitly test:

```text
Wi-Fi path changes
temporary packet loss
screen resolution changes
host display sleep/wake
app background/foreground where platform allows
video pause/resume
encoder restart
decoder restart
network interruption
keyframe lost
parameter sets lost
audio sequence discontinuity
controller disconnect/reconnect
peer disappears uncleanly
UDP path temporarily unavailable
```

Session recovery should be designed, not incidental.

---

# 44. STR0M-SPECIFIC QUESTIONS TO ANSWER DURING IMPLEMENTATION

Before integrating deeply, answer from current source/docs/tests:

1. What exact H.264 bitstream representation does frame-level `Writer::write` expect?

2. What exact H.265 representation does it expect?

3. How are VPS/SPS/PPS represented and negotiated?

4. Does its H.265 implementation support the VideoToolbox output profile Phoros uses?

5. What is current support quality for peer-to-peer versus SFU workloads?

6. How does current BWE interact with externally encoded media?

7. How do we feed target bitrate estimates back into VideoToolbox cleanly?

8. Does str0m expose the estimated bitrate directly?

9. What pacing behavior exists today?

10. How does it decide whether/when to retransmit video?

11. How do keyframe requests surface to application code?

12. What MTU should Phoros target on Apple LANs?

13. How are SCTP partial-reliability settings exposed?

14. Are unordered/unreliable data channels available in the current version?

15. What timer precision does the run loop need?

16. What happens during interface changes?

17. Can we use direct negotiation between two Phoros peers and avoid most SDP handling?

18. What fingerprint verification hooks exist?

19. Can we bind Phoros pairing identity to the DTLS fingerprint?

20. What stats/events can be mapped into Phoros metrics?

Do not assume answers from old examples.

Use the exact dependency version Phoros pins.

---

# 45. DEPENDENCY POLICY

Pin str0m exactly or tightly enough that protocol behavior cannot silently change beneath shipped peers.

Phoros historically pins wire assumptions.

Continue that philosophy.

Track:

```text
str0m version
Rust toolchain/MSRV
crypto provider
XCFramework build metadata
Phoros protocol version
```

Create reproducible release builds.

Consumers of Phoros should not have to install Cargo.

---

# 46. TESTING THE RUST CORE

Add:

```text
unit tests
property tests
fuzzing
malformed packet tests
session-state tests
loss/reordering simulations
timer tests
FFI lifetime tests
```

Leverage Rust fuzzing around:

```text
FFI parsers
control messages
packet handling
session bootstrap
```

Do not duplicate str0m's own entire test suite.

Test Phoros’s integration assumptions.

---

# 47. TESTING THE SWIFT/RUST BOUNDARY

Have explicit tests for:

```text
create/destroy cycles
connection cancellation
callbacks during teardown
buffer lifetime
double-free resistance
Swift task cancellation
Rust panic containment
invalid enum values
oversized frames
nil pointers
zero-length buffers
threading misuse
```

A Rust panic must never unwind across C FFI.

Convert it to a controlled error or abort according to deliberate policy.

---

# 48. CRASH SAFETY / MEMORY

Realtime code must remain stable over multi-hour sessions.

Run:

```text
Address Sanitizer where applicable
Thread Sanitizer where applicable
Malloc diagnostics
Instruments Allocations
Leaks
Rust sanitizers/tools where possible
```

Watch:

```text
per-frame allocations
per-packet allocations
Data copies
Vec reallocations
queue growth
autorelease buildup
```

Latency and memory stability are related.

---

# 49. THREADING

Avoid an architecture where every stage owns arbitrary queues and dispatches asynchronously forever.

That can create invisible frame delays.

Map the pipeline explicitly.

Possible model:

```text
ScreenCaptureKit callback
       ↓
latest-frame slot
       ↓
VideoToolbox encoder queue
       ↓
transport peer executor
       ↓
UDP
```

Receiver:

```text
UDP
 ↓
transport peer executor
 ↓
complete encoded frame
 ↓
VideoToolbox decoder
 ↓
render queue/main layer as required
```

Each queue should have a clear reason to exist.

Every queue should have bounded depth.

No unbounded arrays.

---

# 50. FRAME AGE SHOULD TRAVEL THROUGH THE SYSTEM

Store/derive a monotonic capture timestamp.

At each stage calculate:

```text
now - captureTime
```

If the value exceeds a configured useful threshold:

```text
drop / recover / request keyframe
```

This is more meaningful than queue counts.

The receiver should know if it is showing:

```text
20 ms old
```

or:

```text
300 ms old
```

content.

---

# 51. INTERACTIVE MODES

Consider explicit tuning modes eventually:

```swift
enum StreamingMode {
    case ultraLowLatency
    case balanced
    case quality
}
```

For Beam/controller use:

```text
ultraLowLatency
```

could mean:

```text
shallow buffers
aggressive stale-frame dropping
speed-oriented encoder
minimal display scheduling
faster bitrate adaptation
```

Do not add this API until real measurements demonstrate meaningful configurations.

Avoid fake knobs.

---

# 52. WHAT “PHOROS 2 SUCCESS” LOOKS LIKE

Phoros 2 should no longer be accurately described as:

> a custom framed TCP stream with Apple codec helpers.

It should be describable as:

> **An Apple-native realtime peer engine for interactive media and remote input, with Apple hardware media pipelines and a sophisticated encrypted congestion-controlled realtime transport underneath.**

Its differentiator versus WebRTC should not be:

```text
we reimplemented every protocol WebRTC has
```

Its differentiator should be:

```text
we hide WebRTC's complexity
we specialize it for Apple hardware
we expose remote-interaction semantics
we use VideoToolbox directly
we use native Apple input APIs
we support HEVC naturally
we make LAN peer discovery/pairing trivial
we give developers a tiny Swift-native API
```

The networking can stand on mature protocol work.

Phoros’s originality belongs in the product-facing abstraction and Apple integration.

---

# 53. IMPLEMENTATION PHASES

Execute in phases.

Do not attempt a giant rewrite in one pull request.

## PHASE 0 — MEASURE V1

Before changing transport:

* build frame IDs.
* add end-to-end timestamps.
* add signposts.
* measure capture latency.
* measure encode latency.
* measure TCP sender backlog.
* measure network time.
* measure decoder latency.
* measure display queue latency.
* build dev HUD.
* establish Beam controller-stream baseline.

This tells us where the current lag actually comes from.

## PHASE 1 — LOW-RISK V1 VIDEO IMPROVEMENTS

Without changing protocol:

* investigate VideoToolbox low-latency rate control.
* investigate encoding-speed prioritization.
* verify hardware encoder.
* ensure no frame reordering.
* reduce capture queueing.
* implement latest-frame behavior before encoder.
* inspect decoder queueing.
* investigate immediate display.
* drop stale frames before renderer.
* repair SendScheduler accounting if confirmed broken.
* measure again.

This may produce a large Beam improvement immediately.

## PHASE 2 — TRANSPORT ABSTRACTION

Separate current TCP transport from Phoros session/application semantics.

No behavior change yet.

Create clean boundaries needed for RTC transport.

Keep all current tests passing.

## PHASE 3 — RUST/XCFRAMEWORK SPIKE

Build the smallest possible Rust library into an XCFramework.

Expose:

```text
create
destroy
feed UDP
poll UDP output
timeout
```

from Swift.

Validate:

```text
macOS
physical iPhone/iPad
simulator
release build
SwiftPM consumption
```

No media yet.

## PHASE 4 — STR0M PEER SPIKE

Connect two Phoros test apps over LAN using str0m.

Prove:

```text
Bonjour discovery
signaling
ICE
DTLS
encrypted direct UDP
data channel
RTT metrics
```

## PHASE 5 — VIDEO ONLY

Feed VideoToolbox H.264/HEVC into str0m.

Receiver returns full encoded frames to VideoToolbox.

Instrument entire path.

Compare:

```text
TCP v1
RTC v2
```

under ideal and impaired conditions.

## PHASE 6 — CONGESTION CONTROL

Expose str0m available bitrate / relevant BWE metrics.

Dynamically drive VideoToolbox bitrate.

Implement pacing/deadline integration.

Stress with changing bandwidth.

## PHASE 7 — AUDIO

Implement/test Opus native Apple path or selected alternative.

Add A/V clocking.

Measure sync and latency.

## PHASE 8 — INPUT

Move realtime and reliable input semantics onto appropriate data-channel modes.

Keep existing PhorosInput replay/HID logic.

## PHASE 9 — SECURITY / PAIRING V2

Bind pairing identity to secure transport.

Remove transmission of raw shared secrets.

Add replay/downgrade tests.

## PHASE 10 — PUBLIC API

Only once the engine is stable, design the elegant Swift-facing Phoros 2 API.

Avoid letting implementation accidents become public API.

## PHASE 11 — BEAM DOGFOOD

Use Beam as the torture test.

Controller/game streaming is excellent because latency problems are obvious immediately.

Measure:

```text
real monitor
vs
Beam display
```

with high-speed camera testing if practical.

---

# 54. DO NOT OPTIMIZE THE WRONG THING

Rust will not fix:

```text
ScreenCaptureKit buffering 20 ms
```

Rust will not fix:

```text
VideoToolbox badly configured
```

Rust will not fix:

```text
decoder queuing 25 ms
```

Rust will not fix:

```text
display layer holding 2–3 frames
```

Rust will not fix:

```text
60 Hz display scanout
```

Transport improvements matter tremendously when queues/loss/congestion happen, but low baseline latency requires the complete pipeline.

Always optimize by measured contribution.

---

# 55. DO NOT WORSHIP ZERO LATENCY

Some buffering is necessary.

The objective is:

```text
minimum stable latency
```

not:

```text
zero buffering regardless of artifacts
```

A system constantly stuttering because it buffers nothing can feel worse than a stable extra few milliseconds.

Measure user-perceived interaction.

---

# 56. AVOID THESE FAILURE MODES

Do not:

* rewrite str0m from scratch.
* rewrite VideoToolbox in Rust.
* expose raw WebRTC API concepts publicly.
* preserve AAC merely out of inertia.
* use TCP for v2 media just because it is easy.
* create a custom crypto protocol.
* create unbounded queues.
* retransmit stale pointer movement.
* make every data channel reliable/ordered.
* treat byte queue size as latency.
* switch full video resolution every time bandwidth wiggles.
* recreate encoders unnecessarily.
* let renderer queues silently grow.
* claim latency improvements without measurements.
* delete v1 before v2 proves itself.
* build TURN/cloud infrastructure before LAN is excellent.
* build a custom QUIC media protocol before testing str0m.
* optimize language/runtime overhead before profiling.
* bury transport details in random Swift callbacks.
* use one giant “quality 0...1” signal as the entire congestion system.
* make Phoros into a generic conferencing SDK.

---

# 57. QUESTIONS THAT SHOULD DRIVE CODE REVIEW

For every realtime PR ask:

### Latency

Does this introduce a queue?

If so:

```text
how deep?
why?
what is its maximum age?
what happens when full?
```

### Reliability

If this packet is lost:

```text
must it be recovered?
```

If yes:

```text
for how long is recovery useful?
```

### Freshness

Could newer state replace this state?

### Memory

Does this copy encoded media?

Could it avoid the copy safely?

### Backpressure

What happens if producer outruns consumer for 5 seconds?

The answer must never be:

```text
memory keeps growing
```

### Metrics

Can we observe this stage?

### Recovery

If this state is corrupted/lost, how does the session recover?

---

# 58. INITIAL REPOSITORY TASK

Start by producing a technical design document before invasive changes.

The document must contain:

1. Current V1 pipeline diagram.

2. Measured V1 latency breakdown from real hardware if test hardware is available.

3. Confirmed SendScheduler behavior and whether the backlog-accounting hypothesis is correct.

4. Capture queue-depth findings.

5. Encoder configuration findings.

6. Receiver/rendering behavior findings.

7. str0m current-version capability matrix:

   * H.264
   * H.265
   * Opus
   * data channels
   * partial reliability
   * NACK/RTX
   * TWCC/BWE
   * pacing
   * ICE
   * DTLS/SRTP
   * statistics
   * direct negotiation options

8. Proposed Swift/Rust boundary.

9. Proposed FFI ownership model.

10. Proposed session bootstrap/signaling design.

11. Proposed pairing/security design.

12. Proposed v1/v2 compatibility strategy.

13. Proposed media timestamp/clock model.

14. Proposed metrics schema.

15. Prototype plan.

16. Risks / unanswered questions.

Do not immediately begin a 10,000-line rewrite.

Validate the architecture first.

---

# 59. THEN BUILD THE SMALLEST END-TO-END V2 EXPERIMENT

The first meaningful RTC experiment should contain only:

```text
Mac ScreenCaptureKit
        ↓
VideoToolbox HEVC/H264
        ↓
PhorosCore/str0m
        ↓
direct LAN UDP
        ↓
PhorosCore/str0m
        ↓
VideoToolbox
        ↓
immediate renderer
```

No elaborate production API.

No controller.

No audio.

No cloud.

No TURN.

No fancy pairing UI.

Just:

> Can Phoros 2 beat Phoros 1 on motion-to-photon latency and stay low-latency under packet loss/congestion?

Collect data.

If yes, proceed.

If no, find out why before building more.

---

# 60. THE PRODUCT VISION

The finished product should feel like this:

```text
                 PHOROS 2

        APPLE-NATIVE PUBLIC SURFACE
 ┌────────────────────────────────────┐
 │ ScreenCaptureKit                   │
 │ VideoToolbox                       │
 │ CoreAudio                          │
 │ GameController                     │
 │ CGEvent / IOKit                    │
 │ Bonjour / Keychain                 │
 │ Swift-native Phoros API            │
 └──────────────────┬─────────────────┘
                    │
                narrow FFI
                    │
 ┌──────────────────▼─────────────────┐
 │            PHOROS CORE             │
 │                Rust                │
 │                                    │
 │  str0m WebRTC transport engine     │
 │                                    │
 │  RTP / RTCP                        │
 │  H264/H265 packetization           │
 │  Opus packetization                │
 │  TWCC / GCC                        │
 │  pacing                            │
 │  NACK / recovery                   │
 │  keyframe requests                 │
 │  ICE                               │
 │  DTLS / SRTP                       │
 │  data channels                     │
 │  realtime metrics                  │
 └──────────────────┬─────────────────┘
                    │
                   UDP
                    │
          encrypted peer-to-peer
```

And to a Swift developer:

```swift
import Phoros

let session = try await Phoros.connect(to: mac)

RemoteDisplay(session: session)
```

That is the north star.

---

# 61. FINAL ENGINEERING PHILOSOPHY

Phoros v1’s strongest idea is not its TCP protocol.

Its strongest idea is:

> **Apple developers should not have to assemble ScreenCaptureKit, VideoToolbox, networking, pairing, audio, input replay, HID, synchronization, recovery, and compatibility from scratch just to stream one Apple device to another.**

Keep that.

Replace the transport assumptions that do not scale to truly interactive latency.

WebRTC has already paid the engineering cost for:

```text
loss
jitter
congestion
pacing
retransmission
NAT traversal
secure realtime transport
```

Use that knowledge.

str0m potentially gives Phoros access to that machinery without pulling in Google’s enormous libwebrtc C++ stack and without giving up control of Apple-native capture/codecs.

Phoros can then focus on what it can uniquely do well:

```text
Apple hardware
Apple codecs
Apple display pipeline
Apple input
Apple discovery
Apple pairing UX
remote interaction semantics
a tiny elegant Swift API
```

Do not build “worse WebRTC.”

Build:

> **the Apple-native realtime peer layer that WebRTC itself never tried to be.**

And judge every architectural decision by one primary question:

> **Does this reduce or robustly bound the time between something changing on the host and the user seeing that change on the client?**

If not, it needs a very good reason to exist.
