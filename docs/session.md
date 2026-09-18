# Building a host and a client

`PhorosSession` holds the decisions a peer has to make during a session. `PhorosNetwork` moves the bytes. Neither knows about your UI, your Keychain or your capture source. This page walks a host and a client from connection to media, naming the type for each step.

Every `PhorosSession` type is a value type with no locking. Own one per connection and touch it from one queue.

## The connection

Both sides use `PhorosConnection`. It reads the four-byte length and checks it against `maximumFrameLength` before it allocates. Then it reads the body and classifies it as a packet or a bare JSON message.

```swift
let link = PhorosConnection(to: endpoint)              // client
let link = PhorosConnection(accepting: nwConnection)   // host, from an NWListener

link.onReady = { … }
link.onWaiting = { error in … }   // no route right now; start a timer and cancel() if it expires
link.onFrame = { frame in … }
link.onEnd = { reason in … }      // closedByPeer, transportFailed, protocolViolation, cancelled
link.start()

link.send(bytes)                  // adds the length prefix
```

A frame is `.packet(DecodedPacket)` or `.message(Data)`. The host sends everything as a packet. The client sends JSON bare and wraps only binary payloads. Handle both forms on both sides.

## Pairing, once

The person reads a six-digit code from the host's screen and types it on the client. The code never crosses the wire.

**Client**

```swift
let me = ClientCapabilities(deviceName: UIDevice.current.name, deviceID: stableID)
link.send(try encoder.encode(me.hello()))

// on a frame:
switch PairingClient.interpret(message) {
case .codeRequested(let hostName): showCodeEntry(for: hostName)
case .paired(let secret, let host, let hostName): keychain.store(secret, for: hostName); remember(host.remoteHosts)
case .failed(let reason): show(reason)
default: break
}

// when the person types the code:
link.send(try encoder.encode(me.codeVerify(typed)))
```

**Host**

```swift
var pairing = PairingHost(capabilities: myCapabilities)

// on hello:
if let (challenge, code) = pairing.begin(hello: message) {
    showCode(code)                                     // on screen, for the person
    send(challenge)
}

// on codeVerify:
switch pairing.verify(message) {
case .paired(let secret, let reply): keychain.store(secret, for: pairing.peerDeviceID!); send(reply); hideCode()
case .rejected(let reply): send(reply)                 // the attempt stays open for another try
case .ignored: break                                   // expired or not a codeVerify
}
```

`PairingHost.begin` accepts a `validFor` interval (default five minutes). `verify` ignores a code after that interval.

## Authentication, every time

**Client**

```swift
link.send(try encoder.encode(me.authRequest(secret: storedSecret)))

// on the reply:
if case .authenticated(let host, _, _, _) = PairingClient.interpret(message) {
    canPauseVideo = host.supportsVideoHold
    canToggleAudio = host.supportsAudioToggle
    buttons = host.controls
}
```

`host` is a `PeerCapabilities`. Every absent field has already been given its conservative meaning.

**Host**

```swift
switch HostAuthenticator.authenticate(message, storedSecret: keychain.secret(for:), capabilities: myCapabilities) {
case .authenticated(let session):
    send(session.reply)
    audioCodec = session.audioCodec      // .aacLC only if the client listed it
    videoCodec = session.videoCodec      // .hevc only if the client listed it
    wantsAudio = session.peer.wantsAudio
case .rejected(let reply):
    send(reply); link.cancel()
}
```

Pass `audioPreferences: [.pcmFloat32]` to force PCM for a session, for example from a "safe mode" default.

## Sending media

The host owns one `SendScheduler` per connection.

```swift
var scheduler = SendScheduler()                      // or SendPolicy.pcmAudio for a PCM-only client

// video, from the encoder callback
guard scheduler.admitVideo(isKeyframe: isKeyframe) else { return }
for payload in VideoFragmentHeader.fragment(annexB, frameNumber: n, presentationTimestamp: pts, maximumPayloadLength: 1400) {
    scheduler.enqueue(Packet.encode(isKeyframe ? .videoKeyframe : .video, payload: payload).lengthPrefixed(), lane: .video)
}

// audio, from the encoder callback
guard scheduler.admitAudio() else { return }
let chunk = AudioChunkHeader(sequenceNumber: seq, presentationTimestamp: pts).serialized() + accessUnit
scheduler.enqueue(Packet.encode(.audio, flags: codec.packetFlags, payload: chunk).lengthPrefixed(), lane: .audio)

// control
scheduler.enqueue(Packet.encode(.control, payload: json).lengthPrefixed(), lane: .control)

// drain, after every enqueue and every completion
while let write = scheduler.dequeue() {
    link.connection.send(content: write.data, completion: .contentProcessed { _ in
        scheduler.completed(write)
        drain()
    })
}
```

`admitVideo` refuses delta frames when the backlog is above `policy.maximumQueuedBytes` and never refuses a keyframe. `admitAudio` refuses only on the audio backlog and never for longer than `policy.maximumAudioSilence`. `dequeue` returns control first, then audio, then video, and holds at `policy.maximumConcurrentWrites` outstanding writes.

## Pause and resume

```swift
var hold = VideoHold()

case .videoPause:
    hold.pause()
    scheduler.dropQueuedVideo()
case .videoResume:
    for action in hold.resume() {
        switch action {
        case .resendParameterSets: send(.parameterSets, cachedSets, flags: codec.packetFlags)
        case .requestKeyframe: encoder.requestKeyframe()
        }
    }
```

Send video only while `hold.isHeld` is false. A client sends `.videoPause` only to a host whose `supportsVideoHold` is true.

## Receiving media

```swift
var assembler = FrameAssembler()
var sequenceGuard = AudioSequenceGuard()

case .parameterSets:
    guard let codec = VideoCodecID(packetFlags: packet.flags) else { return }          // unknown: drop
    formatDescription = VideoFormat.makeDescription(parameterSets: packet.payload, codec: codec)

case .video, .videoKeyframe:
    if let frame = assembler.receive(packet.payload, isKeyframe: packet.type == .videoKeyframe) {
        display(VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: formatDescription, presentationTime: hostNow))
    }

case .audio:
    guard let codec = AudioCodecID(packetFlags: packet.flags),                          // unknown: drop
          let header = AudioChunkHeader.parse(from: packet.payload) else { return }
    switch sequenceGuard.accept(header.sequenceNumber) {
    case .duplicate: return
    case .restarted: player.resync()
    case .accept: break
    }
    play(packet.payload.dropFirst(AudioChunkHeader.size), codec: codec, at: header.presentationTimestamp)
```

## Liveness

```swift
var probe = RoundTripProbe()
var heartbeat = HeartbeatMonitor(timeout: 30)

// on a timer
if probe.shouldSend() { send(.ping) }
if heartbeat.isTimedOut() { link.cancel() }

// on any inbound frame
heartbeat.heard()

// on pong
if let rtt = probe.receivedPong() { showLinkQuality(rtt) }
```

## Quality adaptation

The host owns a `QualityLadder` with the presets it is willing to move between, lowest first.

```swift
var ladder = QualityLadder(tiers: [.p360_30, .p480_30, .p720_30, .p1080_30])

case .qualityFeedback(let quality): ladder.feedback(quality)
case .qualityRequest(let preset):
    if preset == .auto { autoTimer.start() } else { autoTimer.stop(); apply(preset) }

// every two seconds while in auto
if let next = ladder.evaluate() { apply(next) }

func apply(_ preset: QualityPreset) {
    encoder.reconfigure { $0.width = Int32(preset.width); $0.height = Int32(preset.height); $0.frameRate = preset.frameRate }
    send(.qualityChanged(preset))
}
```
