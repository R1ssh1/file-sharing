import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'package:pointycastle/export.dart';

/// Simple AES-CTR encryption service (stream friendly) for file chunks.
class EncryptionService {
  final _random = Random.secure();

  Uint8List generateKey({int bits = 256}) {
    final bytes = bits ~/ 8;
    return Uint8List.fromList(
        List<int>.generate(bytes, (_) => _random.nextInt(256)));
  }

  Uint8List generateIv() =>
      Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));

  Stream<List<int>> encryptStream(
      Stream<List<int>> input, Uint8List key, Uint8List iv) {
    // Use constant-time AESEngine instead of deprecated AESFastEngine
    final cipher = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    return input.map((chunk) => cipher.process(Uint8List.fromList(chunk)));
  }

  Stream<List<int>> decryptStream(
      Stream<List<int>> input, Uint8List key, Uint8List iv) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    return input.map((chunk) => cipher.process(Uint8List.fromList(chunk)));
  }

  String encodeKey(Uint8List key) => base64Encode(key);
  Uint8List decodeKey(String b64) => base64Decode(b64);

  /// Convenience helper to compute SHA-256 hex of given bytes (used in tests)
  String sha256Hex(Uint8List data) {
    final d = SHA256Digest().process(data);
    final sb = StringBuffer();
    for (final b in d) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Derive a footer HMAC key from the main AES key (simple KDF: SHA256(key || 'footer')).
  Uint8List deriveFooterHmacKey(Uint8List key) {
    final footerSalt = utf8.encode('footer');
    final buf = Uint8List(key.length + footerSalt.length)
      ..setRange(0, key.length, key)
      ..setRange(key.length, key.length + footerSalt.length, footerSalt);
    final out = SHA256Digest().process(buf);
    return out; // 32 bytes
  }

  /// Compute HMAC-SHA256 returning hex string.
  String hmacSha256Hex(Uint8List hmacKey, List<int> message) {
    final mac = HMac(SHA256Digest(), 64);
    mac.init(KeyParameter(hmacKey));
    mac.update(message as Uint8List? ?? Uint8List.fromList(message), 0,
        message.length);
    final out = Uint8List(mac.macSize);
    mac.doFinal(out, 0);
    final sb = StringBuffer();
    for (final b in out) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  // AES-GCM encryption streaming helper: emits ciphertext chunks; returns a controller.
  // Produces a header-level authentication tag (returned via onTag callback).
  Stream<List<int>> encryptStreamGcm(Stream<List<int>> input, Uint8List key,
      Uint8List iv, void Function(Uint8List tag) onTag) {
    final cipher = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(true, aeadParams);
    final controller = StreamController<List<int>>();
    input.listen((chunk) {
      final processed = cipher.process(Uint8List.fromList(chunk));
      if (processed.isNotEmpty) controller.add(processed);
    }, onError: (e, st) {
      controller.addError(e, st);
      controller.close();
    }, onDone: () {
      try {
        final buf = Uint8List(cipher.getOutputSize(0));
        final len = cipher.doFinal(buf, 0);
        if (len > 0) {
          // In GCM final bytes = tag (len == tagLen/8 bytes) appended.
          onTag(buf.sublist(0, len));
        }
      } catch (e, _) {
        controller.addError(e);
      } finally {
        controller.close();
      }
    }, cancelOnError: true);
    return controller.stream;
  }

  Stream<List<int>> decryptStreamGcm(
      Stream<List<int>> input, Uint8List key, Uint8List iv, Uint8List tag) {
    final cipher = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(false, aeadParams);
    final controller = StreamController<List<int>>();
    final collected = <List<int>>[];
    input.listen((chunk) {
      collected.add(List<int>.from(chunk));
      final processed = cipher.process(Uint8List.fromList(chunk));
      if (processed.isNotEmpty) controller.add(processed);
    }, onError: (e, st) {
      controller.addError(e, st);
      controller.close();
    }, onDone: () {
      try {
        // Feed tag at end.
        cipher.process(tag);
        final buf = Uint8List(cipher.getOutputSize(0));
        final len = cipher.doFinal(buf, 0);
        if (len > 0) controller.add(buf.sublist(0, len));
      } catch (e, _) {
        controller.addError(e);
      } finally {
        controller.close();
      }
    }, cancelOnError: true);
    return controller.stream;
  }

  /// Detached mode helper: returns ciphertext stream (without tag) and a future
  /// completing with the auth tag (16 bytes) after encryption finishes.
  GcmDetachedResult encryptStreamGcmDetached(
      Stream<List<int>> input, Uint8List key, Uint8List iv) {
    final cipher = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(true, aeadParams);
    final controller = StreamController<List<int>>();
    final tagCompleter = Completer<Uint8List>();
    input.listen((chunk) {
      final processed = cipher.process(Uint8List.fromList(chunk));
      if (processed.isNotEmpty) controller.add(processed);
    }, onError: (e, st) {
      if (!tagCompleter.isCompleted) {
        tagCompleter.completeError(e, st);
      }
      controller.addError(e, st);
      controller.close();
    }, onDone: () {
      try {
        final buf = Uint8List(cipher.getOutputSize(0));
        final len = cipher.doFinal(buf, 0);
        tagCompleter.complete(buf.sublist(0, len));
      } catch (e, st) {
        if (!tagCompleter.isCompleted) {
          tagCompleter.completeError(e, st);
        }
      } finally {
        controller.close();
      }
    }, cancelOnError: true);
    return GcmDetachedResult(controller.stream, tagCompleter.future);
  }

  /// One-shot AES-GCM encryption returning (ciphertext, tag).
  GcmBytesResult encryptBytesGcm(Uint8List plain, Uint8List key, Uint8List iv) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = Uint8List(cipher.getOutputSize(plain.length));
    var off = cipher.processBytes(plain, 0, plain.length, out, 0);
    off += cipher.doFinal(out, off);
    // Tag is last 16 bytes
    final tag = out.sublist(off - 16, off);
    final cipherText = out.sublist(0, off - 16);
    return GcmBytesResult(cipherText, tag);
  }

  /// Streaming chunked GCM: splits plaintext stream into fixed chunks, each
  /// encrypted independently with a derived nonce (baseNonce[0..7] + 4-byte counter).
  /// Emits frames serialized as: [4-byte BE cipher length][cipher bytes][16-byte tag].
  Stream<List<int>> encryptChunkedGcm(
      Stream<List<int>> input, Uint8List key, Uint8List baseNonce,
      {int chunkSize = 64 * 1024, int startCounter = 0}) async* {
    if (baseNonce.length < 12) {
      throw ArgumentError('baseNonce must be at least 12 bytes');
    }
    final counterNonce = Uint8List.fromList(baseNonce.sublist(0, 12));
    int counter = startCounter;
    final carry = <int>[];
    await for (final chunk in input) {
      carry.addAll(chunk);
      while (carry.length >= chunkSize) {
        final plainChunk = Uint8List.fromList(carry.sublist(0, chunkSize));
        // remove consumed bytes
        carry.removeRange(0, chunkSize);
        final frame =
            _encryptOneChunkGcm(plainChunk, key, counterNonce, counter);
        counter++;
        yield frame;
      }
    }
    if (carry.isNotEmpty) {
      final frame = _encryptOneChunkGcm(
          Uint8List.fromList(carry), key, counterNonce, counter);
      yield frame;
    }
  }

  List<int> _encryptOneChunkGcm(
      Uint8List plain, Uint8List key, Uint8List nonceBase, int counter) {
    // Derive 12-byte nonce: first 8 bytes from nonceBase[0..7], last 4 bytes = counter big-endian.
    final nonce = Uint8List(12)
      ..setRange(0, 8, nonceBase.sublist(0, 8))
      ..setRange(8, 12,
          Uint8List(4)..buffer.asByteData().setUint32(0, counter, Endian.big));
    final gcm = GCMBlockCipher(AESEngine());
    gcm.init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final out = Uint8List(gcm.getOutputSize(plain.length));
    var off = gcm.processBytes(plain, 0, plain.length, out, 0);
    off += gcm.doFinal(out, off);
    final tag = out.sublist(off - 16, off);
    final cipherText = out.sublist(0, off - 16);
    final frame = BytesBuilder();
    final lenBuf = Uint8List(4)
      ..buffer.asByteData().setUint32(0, cipherText.length, Endian.big);
    frame.add(lenBuf);
    frame.add(cipherText);
    frame.add(tag);
    return frame.takeBytes();
  }

  /// Decrypts a stream of framed AES-GCM chunks produced by [encryptChunkedGcm].
  /// Each input frame layout: [4-byte BE cipherLen][cipher][16-byte tag].
  /// Nonce derivation mirrors encryption (base first 8 bytes + 4-byte counter).
  Stream<List<int>> decryptChunkedGcm(
      Stream<List<int>> frames, Uint8List key, Uint8List baseNonce) async* {
    if (baseNonce.length < 12) {
      throw ArgumentError('baseNonce must be at least 12 bytes');
    }
    final nonceBase = Uint8List.fromList(baseNonce.sublist(0, 12));
    int counter = 0;
    final buffer = <int>[];
    await for (final chunk in frames) {
      buffer.addAll(chunk);
      while (true) {
        if (buffer.length < 4) break; // need length prefix
        final view =
            ByteData.view(Uint8List.fromList(buffer.sublist(0, 4)).buffer);
        final cipherLen = view.getUint32(0, Endian.big);
        final frameTotal = 4 + cipherLen + 16;
        if (buffer.length < frameTotal) break; // wait for more
        final cipherText = Uint8List.fromList(buffer.sublist(4, 4 + cipherLen));
        final tag =
            Uint8List.fromList(buffer.sublist(4 + cipherLen, frameTotal));
        // remove consumed
        buffer.removeRange(0, frameTotal);
        // derive nonce
        final nonce = Uint8List(12)
          ..setRange(0, 8, nonceBase.sublist(0, 8))
          ..setRange(
              8,
              12,
              Uint8List(4)
                ..buffer.asByteData().setUint32(0, counter, Endian.big));
        counter++;
        final gcm = GCMBlockCipher(AESEngine());
        gcm.init(
            false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
        final combined = Uint8List(cipherText.length + tag.length)
          ..setRange(0, cipherText.length, cipherText)
          ..setRange(cipherText.length, cipherText.length + tag.length, tag);
        final out = Uint8List(gcm.getOutputSize(combined.length));
        var off = gcm.processBytes(combined, 0, combined.length, out, 0);
        off += gcm.doFinal(out, off);
        yield out.sublist(0, off);
      }
    }
    if (buffer.isNotEmpty) {
      throw StateError('Trailing incomplete frame (${buffer.length} bytes)');
    }
  }
}

class GcmDetachedResult {
  final Stream<List<int>> stream;
  final Future<Uint8List> tagFuture;
  GcmDetachedResult(this.stream, this.tagFuture);
}

class GcmBytesResult {
  final Uint8List cipherText;
  final Uint8List tag;
  GcmBytesResult(this.cipherText, this.tag);
}

/// Manages per-request ephemeral symmetric keys.
class TransferKeyManager {
  final Map<String, Uint8List> _keys = {}; // requestId -> key
  final EncryptionService _svc;
  TransferKeyManager(this._svc);

  Uint8List keyFor(String requestId) =>
      _keys.putIfAbsent(requestId, () => _svc.generateKey());
  Uint8List? takeKey(String requestId) => _keys.remove(requestId);
  bool hasKey(String requestId) => _keys.containsKey(requestId);
}
