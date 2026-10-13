import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'audio.dart';
import 'discovery.dart';
import 'network.dart';
import 'permissions.dart';

const Color kBg = Color(0xFF121212);
const Color kCard = Color(0xFF1E1E1E);
const Color kGreen = Color(0xFF25D366);
const Color kRed = Color(0xFFE53935);

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => RoomState(),
      child: const BlueTalkApp(),
    ),
  );
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum RoomRole { none, host, client }

class Peer {
  final int id;
  final String name;
  bool speaking;
  bool muted;
  DateTime lastLoud = DateTime.fromMillisecondsSinceEpoch(0);

  Peer(this.id, this.name, {this.speaking = false, this.muted = false});
}

class RoomState extends ChangeNotifier {
  RoomRole role = RoomRole.none;
  String roomName = '';
  bool micMuted = false;
  bool speakerOn = false; // false = الأذن، true = السماعة الخارجية
  List<String> hostIps = [];
  final List<Peer> peers = []; // أول عنصر دائماً هو أنت

  RoomServer? _server;
  RoomClient? _client;
  RoomAnnouncer? _announcer;
  AudioEngine? _audio;
  Timer? _uiTimer;

  static String _cleanName(String raw, String fallback) {
    final t = raw.trim();
    if (t.isEmpty) return fallback;
    return t.length > 20 ? t.substring(0, 20) : t;
  }

  Peer? _find(int id) {
    for (final p in peers) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _enterRoom(RoomRole r, String name, List<Peer> initial) {
    role = r;
    roomName = name;
    micMuted = false;
    speakerOn = false;
    peers
      ..clear()
      ..addAll(initial);
    _audio?.micMuted = false;
    _audio?.speakerOn = false;
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _decaySpeaking(),
    );
    notifyListeners();
  }

  void _addPeer(int id, String name) {
    if (_find(id) != null) return;
    peers.add(Peer(id, name));
    notifyListeners();
  }

  void _removePeer(int id) {
    final own = peers.isEmpty ? null : peers.first;
    peers.removeWhere((p) => p.id == id && !identical(p, own));
    _audio?.removeSender(id);
    notifyListeners();
  }

  void _setPeerMuted(int id, bool muted) {
    final p = _find(id);
    if (p == null) return;
    p.muted = muted;
    if (muted) p.speaking = false;
    notifyListeners();
  }

  void _onLevel(int id, bool loud) {
    if (!loud) return;
    final Peer? peer = id == -1
        ? (peers.isEmpty ? null : peers.first)
        : _find(id);
    if (peer == null) return;
    peer.lastLoud = DateTime.now();
    if (!peer.speaking) {
      peer.speaking = true;
      notifyListeners();
    }
  }

  void _decaySpeaking() {
    final now = DateTime.now();
    var changed = false;
    for (final p in peers) {
      if (p.speaking && now.difference(p.lastLoud).inMilliseconds > 350) {
        p.speaking = false;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _loadLocalIps() async {
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      hostIps = [
        for (final i in ifs)
          for (final a in i.addresses) a.address,
      ];
    } catch (_) {
      hostIps = [];
    }
  }

  Future<String?> startHost(
    String name,
    String password,
    String userName,
  ) async {
    await _teardown();
    final hostName = _cleanName(userName, 'Host');

    final server = RoomServer(
      roomName: name,
      password: password,
      hostName: hostName,
      onPeerJoined: _addPeer,
      onPeerLeft: _removePeer,
      onPeerMuted: _setPeerMuted,
      onAudio: (id, pcm) => _audio?.pushRemote(id, pcm),
      onError: (_) {},
    );
    if (!await server.start()) {
      return 'فشل تشغيل الهوست (ممكن البورت مشغول)';
    }
    _server = server;

    final announcer = RoomAnnouncer(roomName: name);
    await announcer.start();
    _announcer = announcer;

    final audio = AudioEngine(
      onMicData: (pcm) => _server?.broadcastAudio(pcm),
      onLevel: _onLevel,
    );
    _audio = audio;

    await _loadLocalIps();
    _enterRoom(RoomRole.host, name, [Peer(0, '$hostName (You)')]);

    final err = await audio.start();
    if (err != null) {
      await endCall();
      return err;
    }
    return null;
  }

  Future<String?> connectToHost(
    String ip,
    String name,
    String password,
    String userName,
  ) async {
    await _teardown();
    final myName = _cleanName(userName, 'Guest');

    final completer = Completer<String?>();
    var myId = 0;
    var others = <PeerInfo>[];

    final audio = AudioEngine(
      onMicData: (pcm) => _client?.sendAudio(pcm),
      onLevel: _onLevel,
    );

    final client = RoomClient(
      onAccepted: (id, infos) {
        myId = id;
        others = infos;
        if (!completer.isCompleted) completer.complete(null);
      },
      onRejected: (reason) {
        if (!completer.isCompleted) completer.complete(reason);
      },
      onPeerJoined: _addPeer,
      onPeerLeft: _removePeer,
      onPeerMuted: _setPeerMuted,
      onAudio: (id, pcm) => audio.pushRemote(id, pcm),
      onDisconnected: () {
        if (!completer.isCompleted) {
          completer.complete('انقطع الاتصال بالهوست');
        } else {
          endCall();
        }
      },
    );
    _client = client;

    final err = await client.connect(
      host: ip,
      room: name,
      password: password,
      name: myName,
    );
    if (err != null) {
      _client = null;
      return err;
    }

    final result = await completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () => 'ما جاوب الهوست',
    );
    if (result != null) {
      client.disconnect();
      _client = null;
      return result;
    }

    _audio = audio;
    _enterRoom(RoomRole.client, name, [
      Peer(myId, '$myName (You)'),
      for (final p in others) Peer(p.id, p.name, muted: p.muted),
    ]);

    final audioErr = await audio.start();
    if (audioErr != null) {
      await endCall();
      return audioErr;
    }
    return null;
  }

  void toggleMic() {
    micMuted = !micMuted;
    _audio?.micMuted = micMuted;
    _server?.setHostMuted(micMuted);
    _client?.sendMute(micMuted);
    if (peers.isNotEmpty) {
      peers.first.muted = micMuted;
      if (micMuted) peers.first.speaking = false;
    }
    notifyListeners();
  }

  void toggleSpeaker() {
    speakerOn = !speakerOn;
    _audio?.setSpeaker(speakerOn);
    notifyListeners();
  }

  Future<void> _teardown() async {
    _uiTimer?.cancel();
    _uiTimer = null;
    final audio = _audio;
    _audio = null;
    _announcer?.stop();
    _announcer = null;
    _server?.stop();
    _server = null;
    _client?.disconnect();
    _client = null;
    await audio?.stop();
  }

  Future<void> endCall() async {
    role = RoomRole.none;
    roomName = '';
    peers.clear();
    hostIps = [];
    micMuted = false;
    speakerOn = false;
    notifyListeners();
    await _teardown();
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class BlueTalkApp extends StatelessWidget {
  const BlueTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BlueTalk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kGreen, surface: kCard),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          elevation: 0,
          centerTitle: true,
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/create': (_) => const CreateRoomScreen(),
        '/join': (_) => const JoinRoomScreen(),
        '/call': (_) => const ActiveCallScreen(),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class AppButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final Color textColor;
  final VoidCallback onPressed;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = kGreen,
    this.textColor = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon ?? Icons.circle, size: icon == null ? 0 : 22),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textColor,
            letterSpacing: 1,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class AppInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;

  const AppInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, color: kGreen),
          filled: true,
          fillColor: kCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kGreen, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class CircleBadge extends StatelessWidget {
  final String label;
  final bool speaking;
  final double size;

  const CircleBadge({
    super.key,
    required this.label,
    this.speaking = false,
    this.size = 72,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF2C2C2C),
        border: Border.all(
          color: speaking ? kGreen : Colors.transparent,
          width: 3,
        ),
        boxShadow: speaking
            ? [BoxShadow(color: kGreen.withValues(alpha: 0.6), blurRadius: 18)]
            : [],
      ),
      child: Text(
        label.isEmpty ? '?' : label[0].toUpperCase(),
        style: TextStyle(fontSize: size * 0.39, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class RoundControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const RoundControl({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? kCard : Colors.white,
            ),
            child: Icon(icon, color: active ? kGreen : Colors.black, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              const Icon(Icons.graphic_eq, color: kGreen, size: 90),
              const SizedBox(height: 16),
              const Text(
                'BLUETALK',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: kGreen,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Offline voice rooms',
                style: TextStyle(color: Colors.white54),
              ),
              const Spacer(flex: 2),
              AppButton(
                label: 'Create Room',
                icon: Icons.add_circle_outline,
                onPressed: () => Navigator.pushNamed(context, '/create'),
              ),
              const SizedBox(height: 14),
              AppButton(
                label: 'Join Room',
                icon: Icons.login,
                color: kCard,
                textColor: Colors.white,
                onPressed: () => Navigator.pushNamed(context, '/join'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class CreateRoomScreen extends StatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  final _user = TextEditingController();
  final _name = TextEditingController();
  final _pass = TextEditingController();
  bool _starting = false;

  @override
  void dispose() {
    _user.dispose();
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a room name')));
      return;
    }

    final ok = await ensureCallPermissions(context);
    if (!ok || !mounted) return;

    setState(() => _starting = true);
    final error = await context.read<RoomState>().startHost(
      _name.text.trim(),
      _pass.text,
      _user.text,
    );
    if (!mounted) return;
    setState(() => _starting = false);

    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, '/call', (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: kGreen),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Create Room'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          AppInput(
            controller: _user,
            hint: 'Your Name',
            icon: Icons.person_outline,
          ),
          AppInput(
            controller: _name,
            hint: 'Room Name',
            icon: Icons.meeting_room_outlined,
          ),
          AppInput(
            controller: _pass,
            hint: 'Password',
            icon: Icons.lock_outline,
            obscure: true,
          ),
          const SizedBox(height: 24),
          AppButton(
            label: _starting ? 'STARTING...' : 'CREATE CHANNEL',
            onPressed: _starting ? () {} : _create,
          ),
        ],
      ),
    );
  }
}

class JoinRoomScreen extends StatefulWidget {
  const JoinRoomScreen({super.key});

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  final _user = TextEditingController();
  final _ip = TextEditingController();
  final _name = TextEditingController();
  final _pass = TextEditingController();
  bool _connecting = false;
  List<DiscoveredRoom> _rooms = [];
  late final RoomScanner _scanner;

  @override
  void initState() {
    super.initState();
    _scanner = RoomScanner(
      onChanged: (rooms) {
        if (mounted) setState(() => _rooms = rooms);
      },
    );
    _scanner.start();
  }

  @override
  void dispose() {
    _scanner.stop();
    _user.dispose();
    _ip.dispose();
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_ip.text.trim().isEmpty || _name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a room from the list or enter IP')),
      );
      return;
    }

    final ok = await ensureCallPermissions(context);
    if (!ok || !mounted) return;

    setState(() => _connecting = true);
    final error = await context.read<RoomState>().connectToHost(
      _ip.text.trim(),
      _name.text.trim(),
      _pass.text,
      _user.text,
    );
    if (!mounted) return;
    setState(() => _connecting = false);

    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, '/call', (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: kGreen),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Join Room'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Available rooms',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 8),
          if (_rooms.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kGreen,
                    ),
                  ),
                  SizedBox(width: 12),
                  Text('Searching...', style: TextStyle(color: Colors.white54)),
                ],
              ),
            )
          else
            for (final r in _rooms)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: kCard,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: CircleBadge(label: r.room, size: 40),
                  title: Text(r.room),
                  subtitle: Text(r.ip),
                  trailing: const Icon(Icons.wifi, color: kGreen),
                  onTap: () => setState(() {
                    _ip.text = r.ip;
                    _name.text = r.room;
                  }),
                ),
              ),
          const SizedBox(height: 8),
          AppInput(
            controller: _user,
            hint: 'Your Name',
            icon: Icons.person_outline,
          ),
          AppInput(
            controller: _ip,
            hint: 'Host IP (auto-filled, or type it)',
            icon: Icons.wifi,
          ),
          AppInput(
            controller: _name,
            hint: 'Room Name',
            icon: Icons.meeting_room_outlined,
          ),
          AppInput(
            controller: _pass,
            hint: 'Password',
            icon: Icons.lock_outline,
            obscure: true,
          ),
          const SizedBox(height: 24),
          if (_connecting)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Center(child: CircularProgressIndicator(color: kGreen)),
            ),
          AppButton(
            label: _connecting ? 'CONNECTING...' : 'CONNECT',
            onPressed: _connecting ? () {} : _connect,
          ),
        ],
      ),
    );
  }
}

class ActiveCallScreen extends StatelessWidget {
  const ActiveCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RoomState>();

    // إذا انتهت المكالمة (مثلاً المضيف سكّر) نرجع للرئيسية
    if (state.role == RoomRole.none) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.popUntil(context, (r) => r.isFirst);
        }
      });
    }

    return PopScope(
      canPop: false, // زر الرجوع ما يطلعك من المكالمة، استخدم END CALL
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(state.roomName),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Chip(
                label: Text(state.role == RoomRole.host ? 'HOST' : 'CLIENT'),
                backgroundColor: kCard,
                side: const BorderSide(color: kGreen),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (state.role == RoomRole.host && state.hostIps.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'IP: ${state.hostIps.join('   |   ')}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kGreen),
                  ),
                ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: state.peers.length,
                  itemBuilder: (_, i) {
                    final p = state.peers[i];
                    return Container(
                      decoration: BoxDecoration(
                        color: kCard,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleBadge(label: p.name, speaking: p.speaking),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (p.muted) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.mic_off,
                                    color: kRed,
                                    size: 16,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    RoundControl(
                      icon: state.micMuted ? Icons.mic_off : Icons.mic,
                      label: state.micMuted ? 'Unmute' : 'Mute',
                      active: !state.micMuted,
                      onTap: () => context.read<RoomState>().toggleMic(),
                    ),
                    RoundControl(
                      icon: state.speakerOn ? Icons.volume_up : Icons.hearing,
                      label: state.speakerOn ? 'Speaker' : 'Earpiece',
                      active: state.speakerOn,
                      onTap: () => context.read<RoomState>().toggleSpeaker(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: AppButton(
                  label: 'END CALL',
                  icon: Icons.call_end,
                  color: kRed,
                  textColor: Colors.white,
                  onPressed: () {
                    context.read<RoomState>().endCall();
                    Navigator.popUntil(context, (r) => r.isFirst);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
