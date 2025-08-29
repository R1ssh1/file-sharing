import '../../domain/entities/peer.dart';

class PeerConnectionDataSource {
  final List<Peer> _peers = const [
    Peer(
        id: 'peer1',
        name: 'Peer One',
        encryption: 'aes-gcm-chunked',
        version: '1'),
    Peer(
        id: 'peer2',
        name: 'Peer Two',
        encryption: 'aes-gcm-chunked',
        version: '1'),
  ];

  Future<List<Peer>> getPeers() async => List.unmodifiable(_peers);
}
