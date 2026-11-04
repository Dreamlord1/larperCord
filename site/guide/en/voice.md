# Voice calls

larperCord joins real Discord voice channels, with end-to-end encryption. Everything voice-related runs on its own thread, created only when you join a call. Outside a call, the module uses no CPU and the app doesn't even initialize audio.

## Using it

Click a voice channel to join. The panel above your user shows the call, with mute, deafen and disconnect. You can also leave through "Leave call" when you right-click the voice channel. Whoever is talking gets a ring around their avatar.

The **mixer** gives each person their own volume.

![The call mixer](shot:f-voz)

Channels where you lack the permission to connect are shown with a padlock, and the app doesn't try.

## How it works

| Layer | What it uses |
|---|---|
| Signaling | Voice gateway v8 over WebSocket, with heartbeat (`seq_ack`) and RESUME when the connection drops |
| Connection | IP discovery (74-byte packet) and Select Protocol over UDP |
| Transport encryption | RTP with `aead_xchacha20_poly1305_rtpsize` |
| End-to-end encryption | DAVE over MLS, through libdave and MLSpp |
| Codec | Opus at 48 kHz stereo, 20 ms per packet. Lost packets become Opus packet-loss concealment |
| Audio | SDL3 mixes. Each person is one `SDL_AudioStream` on the same output device, and their volume is the stream's gain. The microphone is a stream read every 20 ms |

A few details that took work to get right:

- The "speaking" opcode (op 5) goes out once when the session opens, and again on resume. It doesn't toggle on every sentence, since the server dropped the start of each one that way.
- The RTP clock keeps moving with real time while you're silent, so receivers don't drop your packets after a pause.
- Jitter margin applies only at the start of each talk spurt. Applying it whenever the queue emptied caused audible gaps.
- People already in a call can arrive before DAVE exists, so they're kept and added when it starts.

## Limits today

- It uses your system's default audio device. There's no device picker yet.
- No push-to-talk and no noise suppression.
- No screen sharing, camera or streaming.
- No automated test for a real call. QA covers the UI only.

## Debugging

```bash
LARPER_VOICE_DEBUG=1 larpercord
```

This prints opcodes, close codes and DAVE events, and microphone level and frames sent. It never prints the token or any keys.

To test only the connection, `--voice-test` joins a channel for 25 seconds, **always muted**:

```bash
LARPER_TOKEN=... larpercord --voice-test GUILD_ID CHANNEL_ID
```

