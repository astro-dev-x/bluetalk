# BlueTalk

Offline voice rooms for Android. Talk to friends over a local network, such as a phone hotspot or any Wi-Fi router, with **no internet connection**.

## Features

- Full-duplex voice calls (no push-to-talk), 16 kHz mono
- Create a password-protected room, or join one found automatically on the network
- Mute, earpiece / loudspeaker switch, live speaking indicator, usernames
- Call keeps running in the background (foreground service)
- No accounts, no servers, no third-party audio packages

## How it works

- One phone hosts the room (TCP server on port 7890). Others connect and send the room password.
- Audio is captured with native Android `AudioRecord` (echo cancellation and noise suppression when the device supports them) and played with `AudioTrack`. Both are bridged to Flutter through platform channels.
- The host relays audio between participants, and every device mixes the incoming streams.
- Rooms are found by scanning the local subnet over TCP and by UDP broadcast (port 7891).

## Install

Download the latest `BlueTalk.apk` from the [Releases](../../releases/latest) page and open it on your phone. Android will ask you to allow installing from this source.

## Use

1. Connect all phones to the same network (a phone hotspot works without internet).
2. One person taps **Create Room** and picks a name and password.
3. Everyone else taps **Join Room**, picks the room from the list, and enters the password.

## Build from source

```bash
flutter pub get
flutter run
flutter build apk --release
```

## Limitations

- All devices must be on the same network. Range is the range of the Wi-Fi.
- Audio and the room password are not encrypted, so use it on a private network you trust.
- Tested on Android 10 phones. On some brands, battery optimization may need to be set to unrestricted to keep calls alive with the screen off.
- Not available on iOS.

## Tech

Flutter, Dart, Kotlin, raw TCP/UDP sockets, Provider.
