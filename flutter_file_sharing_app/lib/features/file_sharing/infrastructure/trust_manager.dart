import 'dart:collection';
import 'package:hive/hive.dart';

/// Trust / certificate fingerprint pinning manager with Hive persistence.
class TrustManager {
  final Map<String, String> _pinned = {};
  UnmodifiableMapView<String, String> get pinned =>
      UnmodifiableMapView(_pinned);
  Box<String>? _box;
  static const _boxName = 'trusted_fingerprints';
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> init() async {
    if (_loaded) return;
    _box = await Hive.openBox<String>(_boxName);
    for (final key in _box!.keys) {
      final val = _box!.get(key);
      if (val != null) _pinned[key] = val;
    }
    _loaded = true;
  }

  Future<void> clear() async {
    _pinned.clear();
    await _box?.clear();
  }

  /// Record or validate fingerprint for peer; persist if newly pinned.
  bool record(String peerId, String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) return true;
    final existing = _pinned[peerId];
    if (existing == null) {
      _pinned[peerId] = fingerprint;
      _box?.put(peerId, fingerprint);
      return true;
    }
    return existing == fingerprint;
  }

  Future<void> remove(String peerId) async {
    _pinned.remove(peerId);
    await _box?.delete(peerId);
  }

  String? fingerprintFor(String peerId) => _pinned[peerId];
  bool isPinned(String peerId) => _pinned.containsKey(peerId);

  Future<void> repin(String peerId, String fingerprint) async {
    _pinned[peerId] = fingerprint;
    await _box?.put(peerId, fingerprint);
  }

  Map<String, String> exportAll() => Map<String, String>.from(_pinned);

  Future<void> importAll(Map<String, String> entries,
      {bool overwrite = false}) async {
    for (final e in entries.entries) {
      if (overwrite || !_pinned.containsKey(e.key)) {
        _pinned[e.key] = e.value;
        await _box?.put(e.key, e.value);
      }
    }
  }
}
