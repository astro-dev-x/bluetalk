import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

class _SenderBuffer {
  final List<int> samples = [];
  int pos = 0;
  bool primed = false;

  int get available => samples.length - pos;

  void compact() {
    if (pos > 8000) {
      samples.removeRange(0, pos);
      pos = 0;
    }
  }
}

class AudioEngine {
  static const int sampleRate = 16000;
  static const int _frameSamples = sampleRate ~/ 50; // 20ms
  static const int _maxBufferedSamples = sampleRate * 3 ~/ 10; // 300ms
  static const double _speakThreshold = 600;

  static const MethodChannel _method = MethodChannel('wavetalk/audio');
  static const EventChannel _mic = EventChannel('wavetalk/mic');

  final void Function(Uint8List pcm) onMicData;
  final void Function(int senderId, bool loud) onLevel;

  bool micMuted = false;
  bool speakerOn = false;

  StreamSubscription<dynamic>? _micSub;
  Timer? _mixTimer;
  final Map<int, _SenderBuffer> _senders = {};
  bool _running = false;
  bool _wasPlaying = false;

  AudioEngine({required this.onMicData, required this.onLevel});

  Future<String?> start() async {
    try {
      _micSub = _mic.receiveBroadcastStream().listen(_onMic, onError: (_) {});
      final err = await _method.invokeMethod<String>('start');
      if (err != null) {
        await _micSub?.cancel();
        _micSub = null;
        return err;
      }
      await _method.invokeMethod('setSpeaker', speakerOn);
      _mixTimer = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _mixTick(),
      );
      _running = true;
      return null;
    } on PlatformException catch (e) {
      return e.message ?? 'خطأ بالصوت';
    } catch (e) {
      return 'خطأ بالصوت: $e';
    }
  }

  Future<void> setSpeaker(bool on) async {
    speakerOn = on;
    if (!_running) return;
    try {
      await _method.invokeMethod('setSpeaker', on);
    } catch (_) {}
  }

  void _onMic(dynamic data) {
    if (data is! Uint8List || data.length < 2) return;
    final loud = !micMuted && _rms(data) > _speakThreshold;
    onLevel(-1, loud);
    if (!micMuted) onMicData(data);
  }

  void pushRemote(int senderId, Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return;
    final buf = _senders.putIfAbsent(senderId, () => _SenderBuffer());
    final bd = ByteData.sublistView(pcm);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      buf.samples.add(s);
      sum += s * s;
    }
    onLevel(senderId, math.sqrt(sum / n) > _speakThreshold);

    final excess = buf.available - _maxBufferedSamples;
    if (excess > 0) buf.pos += excess;
  }

  void removeSender(int senderId) {
    _senders.remove(senderId);
  }

  void _mixTick() {
    List<int>? mix;
    for (final b in _senders.values) {
      b.compact();
      if (!b.primed) {
        if (b.available >= _frameSamples * 2) {
          b.primed = true;
        } else {
          continue;
        }
      }
      final take = math.min(b.available, _frameSamples);
      if (take <= 0) {
        b.primed = false;
        continue;
      }
      mix ??= List<int>.filled(_frameSamples, 0);
      for (var i = 0; i < take; i++) {
        mix[i] += b.samples[b.pos + i];
      }
      b.pos += take;
      if (b.available == 0) b.primed = false;
    }

    if (mix == null) {
      _wasPlaying = false;
      return;
    }

    final out = Uint8List(_frameSamples * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < _frameSamples; i++) {
      bd.setInt16(i * 2, mix[i].clamp(-32768, 32767).toInt(), Endian.little);
    }

    if (!_wasPlaying) {
      // وسادة صغيرة (40ms) حتى ما يتقطع الصوت بأول الكلام
      _method
          .invokeMethod('play', Uint8List(_frameSamples * 4))
          .catchError((_) {});
      _wasPlaying = true;
    }
    _method.invokeMethod('play', out).catchError((_) {});
  }

  static double _rms(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(pcm);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }

  Future<void> stop() async {
    _running = false;
    _mixTimer?.cancel();
    _mixTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    _senders.clear();
  }
}
