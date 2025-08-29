import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';
import '../domain/entities/peer.dart';
import 'package:flutter/services.dart';
import 'heartbeat_service.dart';

/// mDNS based peer discovery service.
///
/// Advertises a _fileshare._tcp service with TXT records:
/// name=<deviceName>;port=<port>;id=<randomId>;enc=aes-gcm-chunked;ver=1
/// Discovers peers advertising the same service and emits a de-duplicated list.
class PeerDiscoveryService extends ChangeNotifier {
  static const String serviceType = '_fileshare._tcp';
  static const String domain = 'local';
  final _controller = StreamController<List<Peer>>.broadcast();
  final MDnsClient _mDns = MDnsClient();
  Timer? _pollTimer;
  final Map<String, Peer> _peerMap = {}; // key: peer id
  late final String _selfId; // assigned once
  late final String _deviceName; // assigned once
  bool _identityInitialized = false;
  bool _started = false;
  String? _fingerprint; // server certificate fingerprint (sha256)
  late int _port;
  RawDatagramSocket? _mdnsSocket;
  bool _disabled = false; // set true if multicast fails so we stop retrying
  bool get isDisabled => _disabled;
  bool get isRunning => _started && !_disabled;
  bool _verbose = true; // can later expose toggle
  int _announceCount = 0;
  int _discoverCycles = 0;
  HeartbeatService? _heartbeat;
  bool _heartbeatEnabled = false;
  final List<String> _recentLogs = <String>[]; // circular buffer
  static const int _maxRecentLogs = 200;
  static const MethodChannel _platform =
      MethodChannel('lan.discovery/platform');

  void setVerbose(bool v) => _verbose = v;

  void _log(String msg) {
    final stamped = '${DateTime.now().toIso8601String()} $msg';
    _recentLogs.add(stamped);
    if (_recentLogs.length > _maxRecentLogs) {
      _recentLogs.removeAt(0);
    }
    if (_verbose) debugPrint('[PeerDiscovery] $stamped');
  }

  Stream<List<Peer>> get peersStream => _controller.stream;

  List<String> get recentLogs => List.unmodifiable(_recentLogs);

  String get statusLabel {
    if (_disabled) return 'Disabled';
    final mdns = _mdnsSocket != null;
    final hb = _heartbeatEnabled && (_heartbeat?.isRunning ?? false);
    if (mdns && hb) return 'mDNS+HB';
    if (mdns) return 'mDNS';
    if (hb) return 'Heartbeat';
    if (_started) return 'Starting';
    return 'Idle';
  }

  Future<void> start(
      {required int port, String? deviceName, bool heartbeat = false}) async {
    if (_started) return;
    _started = true;
    _heartbeatEnabled = heartbeat;
    if (!_identityInitialized) {
      _selfId = _randomId();
      _deviceName = deviceName ?? _generateDeviceName(_selfId);
      _identityInitialized = true;
    }
    _port = port;
    try {
      _log('Starting mDNS client + binding announce socket...');
      // Try to acquire multicast lock (Android only; ignore failures on other platforms)
      try {
        await _platform.invokeMethod('acquireMulticast');
      } catch (_) {}
      await _mDns.start();
      await _bindSocket();
      if (_mdnsSocket == null) throw Exception('socket_bind_failed');
      _log('Started with id=$_selfId name=$_deviceName port=$_port');
      if (_heartbeatEnabled) {
        _heartbeat = HeartbeatService(
            selfId: _selfId,
            port: _port,
            onPeer: (id, addr, port) {
              // Merge heartbeat liveness without clobbering richer mDNS metadata if already present.
              final now = DateTime.now();
              final existing = _peerMap[id];
              if (existing != null) {
                _peerMap[id] = Peer(
                    id: existing.id,
                    name: existing.name,
                    address: '${addr.address}:$port',
                    lastSeen: now,
                    encryption: existing.encryption,
                    version: existing.version,
                    fingerprint: existing.fingerprint);
              } else {
                _peerMap[id] = Peer(
                    id: id,
                    name: 'Peer-$id',
                    address: '${addr.address}:$port',
                    lastSeen: now);
              }
              _log('Heartbeat peer $id @ ${addr.address}:$port');
              _emit();
            });
        unawaited(_heartbeat!.start());
      }
    } catch (e) {
      _log('Start failed: $e (disabling discovery)');
      _disabled = true; // disable discovery on failure
      notifyListeners();
      return;
    }
    _pollTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _discover());
    unawaited(_discover());
    Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_announce()));
    unawaited(_announce());
    notifyListeners();
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      _mDns.stop();
    } catch (_) {}
    try {
      await _heartbeat?.stop();
    } catch (_) {}
    try {
      _mdnsSocket?.close();
    } catch (_) {}
    _mdnsSocket = null;
    final wasRunning = _started;
    _started = false;
    try {
      await _platform.invokeMethod('releaseMulticast');
    } catch (_) {}
    if (wasRunning) notifyListeners();
  }

  Future<void> restart({bool? heartbeat}) async {
    await stop();
    _disabled = false;
    // reuse existing identity; don't regenerate _selfId/_deviceName
    unawaited(start(
        port: _port,
        deviceName: _deviceName,
        heartbeat: heartbeat ?? _heartbeatEnabled));
    notifyListeners();
  }

  void setFingerprint(String? fp) {
    _fingerprint = fp;
    // trigger immediate announce with new TXT data
    unawaited(_announce());
  }

  Future<void> _discover() async {
    if (_disabled) return;
    try {
      _discoverCycles++;
      _log('Discover cycle #$_discoverCycles');
      final ptrRecords = _mDns.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(serviceType));
      await for (final ptr in ptrRecords) {
        final srvRecords = _mDns.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName));
        await for (final srv in srvRecords) {
          final txtRecords = _mDns.lookup<TxtResourceRecord>(
              ResourceRecordQuery.text(ptr.domainName));
          Map<String, String> meta = {};
          await for (final txt in txtRecords) {
            for (final raw in txt.text.split('\n')) {
              if (raw.isEmpty) continue;
              final parts = raw.split('=');
              if (parts.length == 2) meta[parts[0]] = parts[1];
            }
          }
          final id = meta['id'];
          if (id == null || id == _selfId) continue;
          final name = meta['name'] ?? 'Peer';
          final advertisedPort = int.tryParse(meta['port'] ?? '') ?? srv.port;
          final host = srv.target;
          final now = DateTime.now();
          _peerMap[id] = Peer(
              id: id,
              name: name,
              address: '$host:$advertisedPort',
              lastSeen: now,
              encryption: meta['enc'],
              version: meta['ver'],
              fingerprint: meta['fp']);
          _log('Discovered peer id=$id name=$name host=$host:$advertisedPort');
        }
      }
      _emit();
    } catch (e) {
      _log('Discover error: $e');
    }
  }

  void _emit() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _peerMap.removeWhere((_, p) =>
        (p.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
            .isBefore(cutoff));
    _controller.add(_peerMap.values.toList());
  }

  Future<void> _announce() async {
    if (_disabled || _mdnsSocket == null) return;
    try {
      final serviceInstance =
          '$_deviceName-${_selfId.substring(0, 5)}.$serviceType.$domain';
      final ptrName = '$serviceType.$domain';
      final hostname = Platform.localHostname.endsWith('.local')
          ? Platform.localHostname
          : '${Platform.localHostname}.$domain';
      final target = '$hostname.';
      final ipv4 =
          (await _firstNonLoopbackIPv4()) ?? InternetAddress.loopbackIPv4;
      final ipv6 = await _firstNonLoopbackIPv6();
      final fpShort = (_fingerprint != null && _fingerprint!.length >= 12)
          ? _fingerprint!.substring(0, 12)
          : _selfId.substring(0, 6);
      // Hardened TXT: ver, id, name, port, encryption, chunk size, resume capability, fingerprint prefix
      final txtRecords = [
        'ver=1',
        'id=$_selfId',
        'name=$_deviceName',
        'port=$_port',
        'enc=aes-gcm-chunked',
        'chunk=65536',
        'resume=1',
        'fp=$fpShort'
      ].join('\n');
      final packet = _buildMdnsAnnouncement(
        instance: serviceInstance,
        ptrName: ptrName,
        hostname: hostname,
        target: target,
        port: _port,
        txt: txtRecords,
        ipv4: ipv4,
        ipv6: ipv6,
      );
      _mdnsSocket!.send(packet, InternetAddress('224.0.0.251'), 5353);
      _announceCount++;
      _log(
          'Announce #$_announceCount sent (${packet.length} bytes) srcPort=${_mdnsSocket!.port}');
    } catch (_) {}
  }

  Future<InternetAddress?> _firstNonLoopbackIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4)
            return addr;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<InternetAddress?> _firstNonLoopbackIPv6() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv6)
            return addr;
        }
      }
    } catch (_) {}
    return null;
  }

  Uint8List _buildMdnsAnnouncement({
    required String instance,
    required String ptrName,
    required String hostname,
    required String target,
    required int port,
    required String txt,
    InternetAddress? ipv4,
    InternetAddress? ipv6,
  }) {
    final bytes = BytesBuilder();
    final recordBytes = BytesBuilder();

    void writeName(BytesBuilder b, String name) {
      for (final part in name.split('.')) {
        if (part.isEmpty) continue;
        final p = part.codeUnits;
        b.add([p.length]);
        b.add(p);
      }
      b.add([0]);
    }

    void writeRecord(String name, int type, int cls, int ttl, List<int> rdata) {
      writeName(recordBytes, name);
      recordBytes.add(_u16(type));
      recordBytes.add(_u16(cls));
      recordBytes.add(_u32(ttl));
      recordBytes.add(_u16(rdata.length));
      recordBytes.add(rdata);
    }

    List<int> encodeDomain(String d) {
      final b = BytesBuilder();
      for (final part in d.split('.')) {
        if (part.isEmpty) continue;
        b.add([part.length]);
        b.add(part.codeUnits);
      }
      b.add([0]);
      return b.takeBytes();
    }

    List<int> ptrRdata() => encodeDomain(instance);

    List<int> srvRdata() {
      final b = BytesBuilder();
      b.add(_u16(0)); // priority
      b.add(_u16(0)); // weight
      b.add(_u16(port));
      b.add(encodeDomain(hostname));
      return b.takeBytes();
    }

    List<int> txtRdata() {
      final segments = txt.split('\n');
      final b = BytesBuilder();
      for (final seg in segments) {
        final u = seg.codeUnits;
        b.add([u.length]);
        b.add(u);
      }
      return b.takeBytes();
    }

    List<int> aRdata() {
      try {
        return (ipv4 ?? InternetAddress.loopbackIPv4).rawAddress;
      } catch (_) {
        return [127, 0, 0, 1];
      }
    }

    List<int>? aaaaRdata() {
      try {
        if (ipv6 == null) return null;
        return ipv6.rawAddress; // 16 bytes
      } catch (_) {
        return null;
      }
    }

    // Build records list: keep PTR answer separate then others as additionals (similar to prior structure).
    writeRecord(ptrName, 12, 1, 120, ptrRdata()); // PTR
    final ptrSectionLength = recordBytes.length; // mark after PTR
    writeRecord(instance, 33, 1, 120, srvRdata()); // SRV
    writeRecord(instance, 16, 1, 120, txtRdata()); // TXT
    writeRecord(hostname, 1, 1, 120, aRdata()); // A
    final aaaa = aaaaRdata();
    if (aaaa != null) {
      writeRecord(hostname, 28, 1, 120, aaaa); // AAAA
    }

    final afterAll = recordBytes.takeBytes();
    final ptrPart = afterAll.sublist(0, ptrSectionLength);
    final additionalPart = afterAll.sublist(ptrSectionLength);
    final additionalCount = 3 + (aaaa != null ? 2 : 1); // SRV, TXT, A, (+AAAA)

    // Header
    bytes.add(_u16(0)); // ID
    bytes.add(_u16(0x8400)); // Flags
    bytes.add(_u16(0)); // QDCOUNT
    bytes.add(_u16(1)); // ANCOUNT (PTR)
    bytes.add(
        _u16(additionalCount)); // NSCOUNT used as additional count (simplified)
    bytes.add(_u16(0)); // ARCOUNT
    bytes.add(ptrPart);
    bytes.add(additionalPart);

    return bytes.takeBytes();
  }

  List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  List<int> _u32(int v) => [
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ];

  Future<void> _bindSocket() async {
    // Try binding to the standard mDNS port 5353 first (better interoperability)
    for (final candidate in [5353, 0]) {
      try {
        _log('Attempting bind to port $candidate');
        final s = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          candidate,
          reuseAddress: true,
          reusePort: false,
        );
        s.joinMulticast(InternetAddress('224.0.0.251'));
        _mdnsSocket = s;
        _log('Bind success on port ${s.port}');
        return;
      } catch (e) {
        _log('Bind failed on $candidate: $e');
      }
    }
    _disabled = true;
    try {
      _mdnsSocket?.close();
    } catch (_) {}
    _mdnsSocket = null;
    notifyListeners();
  }

  Future<Map<String, dynamic>> diagnostics() async {
    final interfaces = <Map<String, dynamic>>[];
    try {
      final list = await NetworkInterface.list(includeLoopback: true);
      for (final iface in list) {
        interfaces.add({
          'name': iface.name,
          'addresses': iface.addresses.map((a) => a.address).toList(),
        });
      }
    } catch (e) {
      interfaces.add({'error': e.toString()});
    }
    return {
      'running': isRunning,
      'disabled': _disabled,
      'status': statusLabel,
      'announceCount': _announceCount,
      'discoverCycles': _discoverCycles,
      'socketPort': _mdnsSocket?.port,
      'peersCached': _peerMap.length,
      'heartbeatEnabled': _heartbeatEnabled,
      'heartbeatRunning': _heartbeat?.isRunning ?? false,
      if (_heartbeat != null)
        'heartbeat': {
          'sent': _heartbeat!.sentCount,
          'received': _heartbeat!.receivedCount,
        },
      'interfaces': interfaces,
      'recentLogs': _recentLogs.take(30).toList(),
    };
  }

  String _generateDeviceName(String id) => 'Device-${id.substring(0, 5)}';
  String _randomId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      _mDns.stop();
    } catch (_) {}
    try {
      _mdnsSocket?.close();
    } catch (_) {}
    _controller.close();
    super.dispose();
  }
}
