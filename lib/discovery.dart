import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'network.dart';

const int kDiscoveryPort = 7891;

class DiscoveredRoom {
  final String ip;
  final String room;
  final int port;
  DateTime lastSeen;

  DiscoveredRoom({
    required this.ip,
    required this.room,
    required this.port,
    required this.lastSeen,
  });
}

/// المضيف: يعلن عن الغرفة كل ثانية بالبث (UDP). طريقة إضافية بس.
class RoomAnnouncer {
  final String roomName;
  final int tcpPort;
  RawDatagramSocket? _socket;
  Timer? _timer;

  RoomAnnouncer({required this.roomName, this.tcpPort = kTcpPort});

  Future<void> start() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      _socket = s;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _announce());
      _announce();
    } catch (_) {}
  }

  Future<void> _announce() async {
    final s = _socket;
    if (s == null) return;

    final data = utf8.encode(
      jsonEncode({'app': 'bluetalk', 'room': roomName, 'port': tcpPort}),
    );

    final targets = <String>{'255.255.255.255'};
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifs) {
        for (final a in i.addresses) {
          final p = a.address.split('.');
          if (p.length == 4) targets.add('${p[0]}.${p[1]}.${p[2]}.255');
        }
      }
    } catch (_) {}

    for (final t in targets) {
      try {
        s.send(data, InternetAddress(t), kDiscoveryPort);
      } catch (_) {}
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}

/// الجهاز الثاني: يلاقي الغرف بطريقتين
/// 1) يسمع إعلانات UDP
/// 2) يفحص الشبكة المحلية باتصال TCP (هذي الأضمن)
class RoomScanner {
  final void Function(List<DiscoveredRoom> rooms) onChanged;
  RawDatagramSocket? _socket;
  Timer? _cleanupTimer;
  bool _stopped = false;
  final Map<String, DiscoveredRoom> _rooms = {};

  RoomScanner({required this.onChanged});

  Future<void> start() async {
    _stopped = false;
    await _startUdpListener();

    _cleanupTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      final before = _rooms.length;
      _rooms.removeWhere((_, r) => now.difference(r.lastSeen).inSeconds > 12);
      if (_rooms.length != before) _emit();
    });

    unawaited(_scanLoop());
  }

  Future<void> _startUdpListener() async {
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
      );
      _socket = s;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg == null) return;
        try {
          final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (msg['app'] != 'bluetalk') return;
          _addRoom(dg.address.address, msg['room'] as String, kTcpPort);
        } catch (_) {}
      });
    } catch (_) {}
  }

  // ---------------- فحص الشبكة باتصال TCP ----------------

  Future<void> _scanLoop() async {
    while (!_stopped) {
      await _scanOnce();
      for (var i = 0; i < 10 && !_stopped; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<List<String>> _targets() async {
    final result = <String>{};
    try {
      final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifs) {
        final n = i.name.toLowerCase();
        // نتجاهل شبكة بيانات الجوال والواجهات الوهمية
        if (n.startsWith('rmnet') ||
            n.startsWith('ccmni') ||
            n.startsWith('tun') ||
            n.startsWith('dummy') ||
            n.startsWith('v4-') ||
            n.startsWith('clat')) {
          continue;
        }
        for (final a in i.addresses) {
          final p = a.address.split('.');
          if (p.length != 4) continue;
          for (var h = 1; h <= 254; h++) {
            final ip = '${p[0]}.${p[1]}.${p[2]}.$h';
            if (ip != a.address) result.add(ip);
          }
        }
      }
    } catch (_) {}

    // عناوين .1 أول شي (غالباً هو الهوتسبوت)
    final list = result.toList();
    list.sort((a, b) {
      final aFirst = a.endsWith('.1') ? 0 : 1;
      final bFirst = b.endsWith('.1') ? 0 : 1;
      return aFirst.compareTo(bFirst);
    });
    return list;
  }

  Future<void> _scanOnce() async {
    final targets = await _targets();
    for (var i = 0; i < targets.length; i += 40) {
      if (_stopped) return;
      final batch = targets.skip(i).take(40);
      await Future.wait(batch.map(_probe));
    }
  }

  Future<void> _probe(String ip) async {
    Socket? s;
    try {
      s = await Socket.connect(
        ip,
        kTcpPort,
        timeout: const Duration(milliseconds: 400),
      );
      s.setOption(SocketOption.tcpNoDelay, true);

      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      final parser = FrameParser((type, payload) {
        if (type == kFrameJson) {
          try {
            final msg =
                jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
            if (msg['type'] == 'room-info' && msg['app'] == 'bluetalk') {
              _addRoom(ip, msg['room'] as String, kTcpPort);
            }
          } catch (_) {}
        }
        finish();
      });

      s.listen(
        (data) {
          try {
            parser.add(data);
          } catch (_) {
            finish();
          }
        },
        onDone: finish,
        onError: (_) => finish(),
        cancelOnError: true,
      );

      s.add(jsonFrame({'type': 'probe'}));
      await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    } catch (_) {
      // العنوان ما فيه مضيف، نكمل
    } finally {
      s?.destroy();
    }
  }

  // ---------------- مشترك ----------------

  void _addRoom(String ip, String room, int port) {
    if (_stopped) return;
    final existing = _rooms[ip];
    if (existing != null && existing.room == room) {
      existing.lastSeen = DateTime.now();
      return;
    }
    _rooms[ip] = DiscoveredRoom(
      ip: ip,
      room: room,
      port: port,
      lastSeen: DateTime.now(),
    );
    _emit();
  }

  void _emit() {
    if (_stopped) return;
    final list = _rooms.values.toList()
      ..sort((a, b) => a.room.compareTo(b.room));
    onChanged(list);
  }

  void stop() {
    _stopped = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _socket?.close();
    _socket = null;
  }
}
