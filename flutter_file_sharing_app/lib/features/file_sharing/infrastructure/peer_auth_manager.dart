import 'dart:math';

/// Manages per-peer authentication tokens.
/// A peer must first call /pair supplying a peerId; server returns a token.
/// Subsequent protected requests may use either global token (if enabled)
/// or X-Peer-Token header along with X-Peer-Id.
class PeerAuthManager {
  final Map<String, String> _peerTokens = {}; // peerId -> token
  final Random _rand = Random.secure();

  String issueToken(String peerId) {
    final token = _generate();
    _peerTokens[peerId] = token;
    return token;
  }

  bool validate(String peerId, String token) {
    final t = _peerTokens[peerId];
    return t != null && t == token;
  }

  String _generate() {
    final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, dynamic> debugSnapshot() => {
        'peers': _peerTokens.length,
      };
}
