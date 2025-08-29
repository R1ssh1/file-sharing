import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'encryption_service.dart';
import 'package:pointycastle/digests/sha256.dart';

class ClientDownloadResult {
  final File file;
  final int bytes;
  final String? hashHex; // computed client-side
  final String? expectedHash; // from server header
  final String? transferState; // completed|failed|canceled|null
  final bool footerSignatureValid;
  bool get hashMismatch =>
      hashHex != null && expectedHash != null && hashHex != expectedHash;
  ClientDownloadResult(this.file, this.bytes,
      {this.hashHex,
      this.expectedHash,
      this.transferState,
      this.footerSignatureValid = true});
}

typedef ProgressCallback = void Function(int received, int? total);

/// Downloads an encrypted chunked AES-GCM stream from server and decrypts on the fly.
class ClientDownloadService {
  final EncryptionService encryptionService;
  ClientDownloadService(this.encryptionService);

  Future<ClientDownloadResult> download(
    Uri url,
    File destination, {
    Map<String, String>? headers,
    ProgressCallback? onProgress,
    bool computeHash = false,
    bool resume = true,
    int? maxBytes, // testing: stop after this many plaintext bytes
    Duration hashPollInterval = const Duration(milliseconds: 400),
    int hashPollAttempts = 10,
  }) async {
    int existing = 0;
    if (resume && await destination.exists()) {
      existing = await destination.length();
    }
    final req = http.Request('GET', url);
    if (headers != null) req.headers.addAll(headers);
    if (existing > 0) {
      req.headers['Range'] = 'bytes=$existing-';
    }
    final streamed = await req.send();
    if (streamed.statusCode != 200) {
      throw HttpException('Download failed: ${streamed.statusCode}');
    }
    final encMode = streamed.headers['x-file-encrypted'];
    // Plain hash may now arrive in a synthetic final footer frame; header may be absent initially.
    String? expectedPlainHash = streamed.headers['x-file-plain-hash'];
    if (encMode != 'aes-gcm-chunked') {
      throw StateError('Unsupported encryption: $encMode');
    }
    final b64Key = streamed.headers['x-file-key'];
    final b64NonceBase = streamed.headers['x-file-nonce-base'];
    final totalStr = streamed.headers['x-file-length'];
    final total = totalStr != null ? int.tryParse(totalStr) : null;
    if (b64Key == null || b64NonceBase == null) {
      throw StateError('Missing key/nonce headers');
    }
    final key = encryptionService.decodeKey(b64Key);
    final nonceBase = encryptionService.decodeKey(b64NonceBase);
    // If resuming but server ignored range (returns 200 with start-chunk 0), overwrite.
    final reportedStart =
        int.tryParse(streamed.headers['x-file-start-chunk'] ?? '0') ?? 0;
    if (existing > 0 && (streamed.statusCode != 206 || reportedStart == 0)) {
      // Server didn't honor resume; reset existing.
      existing = 0;
    }
    final sink = destination.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write);
    int written = existing;
    final digest = SHA256Digest();
    // Buffer raw tail to inspect potential final metadata footer.
    final rawBuffer = <int>[];
    final framesStream = streamed.stream.map((c) {
      final u = Uint8List.fromList(c);
      rawBuffer.addAll(u);
      return u;
    });
    final decryptedStream =
        encryptionService.decryptChunkedGcm(framesStream, key, nonceBase);
    try {
      await for (final chunk in decryptedStream) {
        // Heuristic: footer frame was appended as a separate encrypted chunk of JSON? In current server impl footer added AFTER encryption (raw frame) so it will cause GCM decrypt failure if passed through decryptChunkedGcm.
        // We still consume decrypted chunks; any trailing plaintext footer bytes will cause a trailing incomplete frame error that we swallow below.
        sink.add(chunk);
        written += chunk.length;
        if (computeHash) {
          final u = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          digest.update(u, 0, u.length);
        }
        onProgress?.call(written, total);
        if (maxBytes != null && written >= maxBytes) {
          if (written > maxBytes) {
            await sink.close();
            await destination.writeAsBytes(
                await destination
                    .readAsBytes()
                    .then((b) => b.sublist(0, maxBytes)),
                flush: true);
            written = maxBytes;
          }
          break;
        }
      }
    } catch (e) {
      // Swallow trailing incomplete frame error which occurs when plaintext footer appended after encrypted frames.
      if (!(e is StateError &&
          e.toString().startsWith('StateError: Trailing incomplete frame'))) {
        rethrow;
      }
    }
    await sink.close();
    // Attempt to parse footer: last (4 + N) bytes where first 4 bytes big-endian length, followed by JSON with type:final.
    String? transferState;
    bool signatureValid = true;
    try {
      if (rawBuffer.length >= 8) {
        for (int offset = rawBuffer.length - 8;
            offset >= 0 && rawBuffer.length - offset <= 4096 + 4;
            offset--) {
          final lenBytes = rawBuffer.sublist(offset, offset + 4);
          final bd = ByteData.view(Uint8List.fromList(lenBytes).buffer);
          final metaLen = bd.getUint32(0, Endian.big);
          if (metaLen > 0 &&
              metaLen <= 4096 &&
              offset + 4 + metaLen <= rawBuffer.length) {
            final cand = rawBuffer.sublist(offset + 4, offset + 4 + metaLen);
            final txt = utf8.decode(cand, allowMalformed: true);
            if (txt.contains('"type"')) {
              if (txt.contains('"state"')) {
                final stateMatch =
                    RegExp('"state"\s*:\s*"([a-z]+)"').firstMatch(txt);
                if (stateMatch != null) {
                  transferState = stateMatch.group(1);
                }
              }
              if (txt.contains('"hash"')) {
                final match =
                    RegExp('"hash"\s*:\s*"([0-9a-fA-F]{64})"').firstMatch(txt);
                if (match != null) {
                  expectedPlainHash ??= match.group(1);
                }
              }
              // HMAC signature verification: expect 'sig' as last property.
              try {
                final sigMatch =
                    RegExp('"sig"\s*:\s*"([0-9a-fA-F]{64})"').firstMatch(txt);
                if (sigMatch != null) {
                  final provided = sigMatch.group(1)!;
                  // Reconstruct noSig string by removing ,"sig":"..." from end
                  final idx = txt.lastIndexOf(',"sig"');
                  if (idx != -1 && txt.endsWith('}')) {
                    final noSig = txt.substring(0, idx) + '}';
                    // derive key and compute expected sig
                    final key = encryptionService.decodeKey(b64Key);
                    final hmacKey = encryptionService.deriveFooterHmacKey(key);
                    final expected = encryptionService.hmacSha256Hex(
                        hmacKey, utf8.encode(noSig));
                    if (expected.toLowerCase() != provided.toLowerCase()) {
                      signatureValid = false;
                      // mark transfer failed locally if signature bad
                      transferState ??= 'failed';
                    }
                  }
                }
              } catch (_) {
                signatureValid = false;
                transferState ??= 'failed';
              }
              break; // footer located
            }
          }
        }
      }
    } catch (_) {}
    String? hashHex;
    if (computeHash) {
      final out = Uint8List(digest.digestSize);
      digest.doFinal(out, 0);
      final sb = StringBuffer();
      for (final b in out) {
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      hashHex = sb.toString();
    }
    // If server omitted expected hash header, attempt to poll companion hash endpoint: /requests/<id>/hash
    if (expectedPlainHash == null) {
      final segments = url.pathSegments;
      if (segments.length >= 2 && segments[segments.length - 2] == 'download') {
        final requestId = segments.last;
        final hashUrl =
            url.replace(path: '/requests/$requestId/hash', query: '');
        Duration interval = hashPollInterval;
        bool pendingAcknowledged = false;
        for (int attempt = 0; attempt < hashPollAttempts; attempt++) {
          try {
            final resp = await http.get(hashUrl, headers: headers);
            if (resp.statusCode == 200) {
              final match = RegExp('"hash"\\s*:\\s*"([0-9a-fA-F]{64})"')
                  .firstMatch(resp.body);
              if (match != null) {
                expectedPlainHash = match.group(1);
                break;
              }
              break; // malformed success; stop
            } else if (resp.statusCode == 404) {
              // Distinguish between structured pending vs not-found route.
              if (resp.body.contains('hash_pending')) {
                pendingAcknowledged = true;
                // exponential backoff after acknowledging pending
                await Future.delayed(interval);
                final nextMs = (interval.inMilliseconds * 1.5).toInt();
                final bounded = nextMs.clamp(100, 2000);
                interval = Duration(milliseconds: bounded);
                continue;
              } else {
                // Route not found or different 404 -> abort further polling.
                if (!pendingAcknowledged) {
                  break;
                }
              }
            } else {
              break; // other status abort
            }
          } catch (_) {
            break; // network error abort
          }
        }
      }
    }
    return ClientDownloadResult(destination, written,
        hashHex: hashHex,
        expectedHash: expectedPlainHash,
        transferState: transferState,
        footerSignatureValid: signatureValid);
  }
}
