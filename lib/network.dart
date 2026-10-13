import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kTcpPort = 7890;
const int kFrameJson = 1;
const int kFrameAudio = 2;
const int kMaxFrameBytes = 1 << 20;

class PeerInfo {
  final int id;
  final String name;
  final bool muted;
  const PeerInfo(this.id, this.name, this.muted);
}

Uint8List _buildFrame(int type, List<int> payload) {
  final out = Uint8List(5 + payload.length);
  out[0] = type;
  ByteData.sublistView(out).setUint32(1, payload.length, Endian.big);
  out.setRange(5, out.length, payload);
  return out;
}

Uint8List jsonFrame(Map<String, dynamic> msg) =>
    _buildFrame(kFrameJson, utf8.encode(jsonEncode(msg)));

/// payload = [senderId: 2 bytes][PCM16 little-endian]
Uint8List audioFrame(int senderId, Uint8List pcm) {
  final payloadLen = 2 + pcm.length;
  final out = Uint8List(5 + payloadLen);
  out[0] = kFrameAudio;
  final bd = ByteData.sublistView(out);
  bd.setUint32(1, payloadLen, Endian.big);
  bd.setUint16(5, senderId, Endian.big);
  out.setRange(7, out.length, pcm);
  return out;
}

class FrameParser {
  final void Function(int type, Uint8List payload) onFrame;
  Uint8List _pending = Uint8List(0);

  FrameParser(this.onFrame);

  void add(List<int> data) {
    final incoming = data is Uint8List ? data : Uint8List.fromList(data);
    if (_pending.isEmpty) {
      _pending = incoming;
    } else {
      final merged = Uint8List(_pending.length + incoming.length);
      merged.setRange(0, _pending.length, _pending);
      merged.setRange(_pending.length, merged.length, incoming);
      _pending = merged;
    }

    var offset = 0;
    while (_pending.length - offset >= 5) {
      final header = ByteData.sublistView(_pending, offset, offset + 5);
      final type = header.getUint8(0);
      final len = header.getUint32(1, Endian.big);
      if (len > kMaxFrameBytes) {
        throw const FormatException('frame too large');
      }
      if (_pending.length - offset - 5 < len) break;
      final payload = Uint8List.sublistView(
        _pending,
        offset + 5,
        offset + 5 + len,
      );
      offset += 5 + len;
      onFrame(type, payload);
    }

    _pending = offset >= _pending.length
        ? Uint8List(0)
        : Uint8List.sublistView(_pending, offset);
  }
}

void _safeAdd(Socket s, Uint8List data) {
  try {
    s.add(data);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------------

class RoomServer {
  ServerSocket? _server;
  final Map<int, Socket> _clients = {};
  final Map<int, String> _names = {};
  final Map<int, bool> _muted = {};
  bool _hostMuted = false;
  int _nextId = 1;

  final String roomName;
  final String password;
  final String hostName;
  final void Function(int id, String name) onPeerJoined;
  final void Function(int id) onPeerLeft;
  final void Function(int id, bool muted) onPeerMuted;
  final void Function(int senderId, Uint8List pcm) onAudio;
  final void Function(String error) onError;

  RoomServer({
    required this.roomName,
    required this.password,
    required this.hostName,
    required this.onPeerJoined,
    required this.onPeerLeft,
    required this.onPeerMuted,
    required this.onAudio,
    required this.onError,
  });

  Future<bool> start({int port = kTcpPort}) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    } catch (e) {
      onError('فشل تشغيل السيرفر: $e');
      return false;
    }
    _server!.listen(_handleConnection, onError: (_) {});
    return true;
  }

  void _handleConnection(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    int? id;
    var closed = false;

    void cleanup() {
      if (closed) return;
      closed = true;
      final myId = id;
      if (myId != null && _clients.remove(myId) != null) {
        _names.remove(myId);
        _muted.remove(myId);
        _broadcastJson({'type': 'peer-left', 'id': myId});
        onPeerLeft(myId);
      }
      socket.destroy();
    }

    final parser = FrameParser((type, payload) {
      if (type == kFrameJson) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
        } catch (_) {
          cleanup();
          return;
        }

        final myId = id;
        if (myId == null) {
          // فحص من جهاز يدور على غرف: نرد باسم الغرفة ونسكّر
          if (msg['type'] == 'probe') {
            _safeAdd(
              socket,
              jsonFrame({
                'type': 'room-info',
                'app': 'bluetalk',
                'room': roomName,
              }),
            );
            socket.flush().catchError((_) {}).whenComplete(cleanup);
            return;
          }

          // لسه ما سجّل دخول: نتوقع رسالة join فقط
          if (msg['type'] != 'join') return;

          if (msg['room'] != roomName || msg['password'] != password) {
            _safeAdd(
              socket,
              jsonFrame({
                'type': 'rejected',
                'reason': 'اسم الغرفة أو الباسورد غلط',
              }),
            );
            socket.flush().catchError((_) {}).whenComplete(cleanup);
            return;
          }

          final rawName = ((msg['name'] as String?) ?? '').trim();
          final name = rawName.isEmpty
              ? 'Guest'
              : (rawName.length > 20 ? rawName.substring(0, 20) : rawName);

          final newId = _nextId++;
          final existing = <Map<String, dynamic>>[
            <String, dynamic>{'id': 0, 'name': hostName, 'muted': _hostMuted},
            for (final cid in _clients.keys)
              <String, dynamic>{
                'id': cid,
                'name': _names[cid] ?? 'Guest',
                'muted': _muted[cid] ?? false,
              },
          ];

          _clients[newId] = socket;
          _names[newId] = name;
          _muted[newId] = false;
          id = newId;

          _safeAdd(
            socket,
            jsonFrame({'type': 'accepted', 'id': newId, 'peers': existing}),
          );
          _broadcastJson({
            'type': 'peer-joined',
            'id': newId,
            'name': name,
          }, except: newId);
          onPeerJoined(newId, name);
        } else if (msg['type'] == 'mute') {
          final m = msg['muted'] == true;
          _muted[myId] = m;
          _broadcastJson({
            'type': 'mute',
            'id': myId,
            'muted': m,
          }, except: myId);
          onPeerMuted(myId, m);
        }
      } else if (type == kFrameAudio) {
        final myId = id;
        if (myId == null || payload.length <= 2) return;
        final pcm = Uint8List.sublistView(payload, 2);
        onAudio(myId, pcm);
        final frame = audioFrame(myId, pcm);
        _clients.forEach((cid, s) {
          if (cid != myId) _safeAdd(s, frame);
        });
      }
    });

    socket.listen(
      (data) {
        try {
          parser.add(data);
        } catch (_) {
          cleanup();
        }
      },
      onDone: cleanup,
      onError: (_) => cleanup(),
      cancelOnError: true,
    );
  }

  void broadcastAudio(Uint8List pcm) {
    if (_clients.isEmpty) return;
    final frame = audioFrame(0, pcm);
    for (final s in _clients.values) {
      _safeAdd(s, frame);
    }
  }

  void setHostMuted(bool muted) {
    _hostMuted = muted;
    _broadcastJson({'type': 'mute', 'id': 0, 'muted': muted});
  }

  void _broadcastJson(Map<String, dynamic> msg, {int? except}) {
    final frame = jsonFrame(msg);
    _clients.forEach((id, s) {
      if (id != except) _safeAdd(s, frame);
    });
  }

  void stop() {
    for (final s in _clients.values) {
      s.destroy();
    }
    _clients.clear();
    _names.clear();
    _muted.clear();
    _server?.close();
    _server = null;
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

class RoomClient {
  Socket? _socket;
  bool _closed = false;

  final void Function(int myId, List<PeerInfo> peers) onAccepted;
  final void Function(String reason) onRejected;
  final void Function(int id, String name) onPeerJoined;
  final void Function(int id) onPeerLeft;
  final void Function(int id, bool muted) onPeerMuted;
  final void Function(int senderId, Uint8List pcm) onAudio;
  final void Function() onDisconnected;

  RoomClient({
    required this.onAccepted,
    required this.onRejected,
    required this.onPeerJoined,
    required this.onPeerLeft,
    required this.onPeerMuted,
    required this.onAudio,
    required this.onDisconnected,
  });

  Future<String?> connect({
    required String host,
    required String room,
    required String password,
    required String name,
    int port = kTcpPort,
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 6),
      );
    } catch (e) {
      return 'ما كدرت اوصل للهوست: $e';
    }
    _socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    final parser = FrameParser((type, payload) {
      if (type == kFrameJson) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        switch (msg['type']) {
          case 'accepted':
            {
              final list = (msg['peers'] as List).map((e) {
                final m = e as Map;
                return PeerInfo(
                  m['id'] as int,
                  (m['name'] as String?) ?? 'Guest',
                  (m['muted'] as bool?) ?? false,
                );
              }).toList();
              onAccepted(msg['id'] as int, list);
              break;
            }
          case 'rejected':
            onRejected((msg['reason'] as String?) ?? 'انرفض الاتصال');
            break;
          case 'peer-joined':
            onPeerJoined(msg['id'] as int, (msg['name'] as String?) ?? 'Guest');
            break;
          case 'peer-left':
            onPeerLeft(msg['id'] as int);
            break;
          case 'mute':
            onPeerMuted(msg['id'] as int, msg['muted'] == true);
            break;
        }
      } else if (type == kFrameAudio) {
        if (payload.length <= 2) return;
        final senderId = ByteData.sublistView(payload).getUint16(0, Endian.big);
        onAudio(senderId, Uint8List.sublistView(payload, 2));
      }
    });

    socket.listen(
      (data) {
        try {
          parser.add(data);
        } catch (_) {
          _handleClosed();
        }
      },
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: true,
    );

    _safeAdd(
      socket,
      jsonFrame({
        'type': 'join',
        'room': room,
        'password': password,
        'name': name,
      }),
    );
    return null;
  }

  void sendAudio(Uint8List pcm) {
    final s = _socket;
    if (s == null || _closed) return;
    _safeAdd(s, audioFrame(0, pcm));
  }

  void sendMute(bool muted) {
    final s = _socket;
    if (s == null || _closed) return;
    _safeAdd(s, jsonFrame({'type': 'mute', 'muted': muted}));
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
    _socket?.destroy();
    onDisconnected();
  }

  void disconnect() {
    _closed = true;
    _socket?.destroy();
    _socket = null;
  }
}
