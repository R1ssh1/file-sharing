import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';
import 'package:basic_utils/basic_utils.dart';

/// Generates a minimal X.509 v3 self-signed certificate (RSA, SHA256) and returns
/// the certificate PEM plus the associated private key PEM.
class SelfSignedCertificate {
  final String certificatePem;
  final String privateKeyPem;
  final RSAPrivateKey privateKey;
  final RSAPublicKey publicKey;
  SelfSignedCertificate(
      this.certificatePem, this.privateKeyPem, this.privateKey, this.publicKey);
}

class CertificateGenerator {
  final Random _rng = Random.secure();

  Future<SelfSignedCertificate> generate(
      {int rsaBits = 2048,
      int daysValid = 365,
      Map<String, String>? subject}) async {
    final pair = CryptoUtils.generateRSAKeyPair();
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;

    final sub = subject ??
        {
          'CN': 'FileSharingLocal',
          'O': 'LocalDev',
          'L': 'Local',
          'OU': 'Dev',
          'C': 'US'
        };

    final notBefore =
        DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final notAfter = notBefore.add(Duration(days: daysValid));

    final tbs = _buildTbsCertificate(pub, sub, notBefore, notAfter);
    final tbsDer = tbs.encodedBytes;
    final signature = _sign(priv, tbsDer);
    final certSeq = ASN1Sequence();
    certSeq.add(tbs);
    certSeq.add(_algorithmIdentifier());
    final sigBits = ASN1BitString(Uint8List.fromList(signature));
    certSeq.add(sigBits);
    final certDer = certSeq.encodedBytes;
    final certPem = _pemEncode('CERTIFICATE', certDer);
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(priv);
    return SelfSignedCertificate(certPem, keyPem, priv, pub);
  }

  ASN1Sequence _buildTbsCertificate(RSAPublicKey pub,
      Map<String, String> subject, DateTime notBefore, DateTime notAfter) {
    final tbs = ASN1Sequence();
    final version = ASN1Integer(BigInt.from(2));
    final versionWrapper = ASN1Sequence(tag: 0xA0);
    versionWrapper.add(version);
    tbs.add(versionWrapper);
    final serial = BigInt.from(_rng.nextInt(1 << 31));
    tbs.add(ASN1Integer(serial));
    tbs.add(_algorithmIdentifier());
    tbs.add(_distinguishedName(subject));
    final validity = ASN1Sequence();
    validity.add(_time(notBefore));
    validity.add(_time(notAfter));
    tbs.add(validity);
    tbs.add(_distinguishedName(subject));
    tbs.add(_subjectPublicKeyInfo(pub));
    return tbs;
  }

  ASN1Object _time(DateTime dt) {
    if (dt.year < 2050) {
      return ASN1UtcTime(dt);
    }
    return ASN1GeneralizedTime(dt);
  }

  ASN1Sequence _algorithmIdentifier() {
    final alg = ASN1Sequence();
    alg.add(ASN1ObjectIdentifier.fromName('sha256WithRSAEncryption'));
    alg.add(ASN1Null());
    return alg;
  }

  ASN1Sequence _distinguishedName(Map<String, String> dn) {
    final seq = ASN1Sequence();
    dn.forEach((k, v) {
      final set = ASN1Set();
      final inner = ASN1Sequence();
      inner.add(_oidForAttribute(k));
      inner.add(ASN1PrintableString(v));
      set.add(inner);
      seq.add(set);
    });
    return seq;
  }

  ASN1ObjectIdentifier _oidForAttribute(String shortName) {
    switch (shortName) {
      case 'CN':
        return ASN1ObjectIdentifier.fromName('commonName');
      case 'O':
        return ASN1ObjectIdentifier.fromName('organizationName');
      case 'OU':
        return ASN1ObjectIdentifier.fromName('organizationalUnitName');
      case 'L':
        return ASN1ObjectIdentifier.fromName('localityName');
      case 'C':
        return ASN1ObjectIdentifier.fromName('countryName');
      default:
        return ASN1ObjectIdentifier.fromName('commonName');
    }
  }

  ASN1Sequence _subjectPublicKeyInfo(RSAPublicKey pub) {
    final spki = ASN1Sequence();
    final alg = ASN1Sequence();
    alg.add(ASN1ObjectIdentifier.fromName('rsaEncryption'));
    alg.add(ASN1Null());
    spki.add(alg);
    final pubSeq = ASN1Sequence();
    pubSeq.add(ASN1Integer(pub.modulus!));
    pubSeq.add(ASN1Integer(pub.exponent!));
    final pubSeqDer = pubSeq.encodedBytes;
    final bitString = ASN1BitString(Uint8List.fromList(pubSeqDer));
    spki.add(bitString);
    return spki;
  }

  Uint8List _sign(RSAPrivateKey priv, Uint8List data) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
    final params = PrivateKeyParameter<RSAPrivateKey>(priv);
    signer.init(true, params);
    return signer.generateSignature(data).bytes;
  }

  String _pemEncode(String label, Uint8List der) {
    final b64 = base64Encode(der);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----';
  }
}
