import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Lightweight UDP broadcast heartbeat fallback when mDNS blocked.
/// Broadcasts JSON {"t":"fs_heartbeat","id":<id>,"p":<port>} every interval.
/// Listens on same socket for packets; invokes onPeer with id -> address mapping.
class HeartbeatService {
  final String selfId;
  final int port;
  final void Function(String id, InternetAddress addr, int port) onPeer;
  RawDatagramSocket? _socket;
  Timer? _timer;
  bool _running = false;
  bool get isRunning => _running;
  int sentCount = 0;
  int receivedCount = 0;

  HeartbeatService(
      {required this.selfId, required this.port, required this.onPeer});

  Future<void> start() async {
    if (_running) return;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
          reuseAddress: true, reusePort: false);
      _socket!.broadcastEnabled = true;
      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket!.receive();
          if (dg == null) return;
          try {
            final txt = utf8.decode(dg.data, allowMalformed: true);
            if (!txt.contains('fs_heartbeat')) return;
            final map = jsonDecode(txt);
            if (map is Map && map['t'] == 'fs_heartbeat') {
              final id = map['id'] as String?;
              final p = map['p'] as int?;
              if (id != null && id != selfId && p != null) {
                receivedCount++;
                onPeer(id, dg.address, p);
              }
            }
          } catch (_) {}
        }
      });
      _timer = Timer.periodic(const Duration(seconds: 7), (_) => _broadcast());
      _broadcast();
      _running = true;
    } catch (e) {
      debugPrint('[Heartbeat] start failed: $e');
    }
  }

  void _broadcast() {
    if (_socket == null) return;
    final msg = jsonEncode({'t': 'fs_heartbeat', 'id': selfId, 'p': port});
    final data = utf8.encode(msg);
    try {
      _socket!.send(data, InternetAddress('255.255.255.255'), 54321);
  sentCount++;
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _running = false;
  }
}
