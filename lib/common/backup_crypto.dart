import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

const _encMagic = 'FCTBKP1\0';
const _kdfIterations = 100000;
const _saltLen = 16;
const _ivLen = 16;

Uint8List _pbkdf2(String password, Uint8List salt, int keyLen) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, _kdfIterations, keyLen));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _pkcs7Pad(Uint8List data) {
  final pad = 16 - (data.length % 16);
  return Uint8List.fromList([...data, ...List.filled(pad, pad)]);
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) {
    throw const FormatException('empty ciphertext');
  }
  final pad = data.last;
  if (pad < 1 || pad > 16 || data.length < pad) {
    throw const FormatException('bad padding');
  }
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) {
      throw const FormatException('bad padding');
    }
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

CbcBlockCipher _aesCbc(Uint8List key, Uint8List iv, bool forEncryption) {
  return CbcBlockCipher(AESEngine())
    ..init(
      forEncryption,
      ParametersWithIV(KeyParameter(key), iv),
    );
}

bool isEncryptedBackup(List<int> bytes) {
  if (bytes.length < _encMagic.length) return false;
  for (var i = 0; i < _encMagic.length; i++) {
    if (bytes[i] != _encMagic.codeUnitAt(i)) return false;
  }
  return true;
}

Future<Uint8List> encryptZipBytesAsync(List<int> zipBytes, String password) {
  return compute(_encryptTask, (zipBytes, password));
}

Uint8List _encryptTask((List<int>, String) args) {
  return encryptZipBytes(args.$1, args.$2);
}

Future<Uint8List> decryptBackupBytesAsync(List<int> data, String password) {
  return compute(_decryptTask, (data, password));
}

Uint8List _decryptTask((List<int>, String) args) {
  return decryptBackupBytes(args.$1, args.$2);
}

Uint8List encryptZipBytes(List<int> zipBytes, String password) {
  final rnd = Random.secure();
  final salt = Uint8List.fromList(
    List.generate(_saltLen, (_) => rnd.nextInt(256)),
  );
  final iv = Uint8List.fromList(
    List.generate(_ivLen, (_) => rnd.nextInt(256)),
  );
  final keys = _pbkdf2(password, salt, 48);
  final encKey = Uint8List.sublistView(keys, 0, 32);
  final macKey = Uint8List.sublistView(keys, 32, 48);
  final cipher = _aesCbc(encKey, iv, true);
  final padded = _pkcs7Pad(Uint8List.fromList(zipBytes));
  final cipherText = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cipher.processBlock(padded, off, cipherText, off);
  }
  final mac = Hmac(SHA256Digest(), 64)
      .process([...macKey, ...salt, ...iv, ...cipherText]);
  final out = BytesBuilder(copy: false);
  out.add(utf8.encode(_encMagic));
  out.add(salt);
  out.add(iv);
  out.add(mac);
  out.add(cipherText);
  return out.toBytes();
}

Uint8List decryptBackupBytes(List<int> data, String password) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  if (!isEncryptedBackup(bytes)) {
    throw const FormatException('not an encrypted backup');
  }
  final headerLen = _encMagic.length + _saltLen + _ivLen + 32;
  if (bytes.length < headerLen + 16) {
    throw const FormatException('truncated encrypted backup');
  }
  var off = _encMagic.length;
  final salt = Uint8List.sublistView(bytes, off, off + _saltLen);
  off += _saltLen;
  final iv = Uint8List.sublistView(bytes, off, off + _ivLen);
  off += _ivLen;
  final mac = Uint8List.sublistView(bytes, off, off + 32);
  off += 32;
  final cipherText = Uint8List.sublistView(bytes, off);
  final keys = _pbkdf2(password, salt, 48);
  final encKey = Uint8List.sublistView(keys, 0, 32);
  final macKey = Uint8List.sublistView(keys, 32, 48);
  final expectMac = Hmac(SHA256Digest(), 64)
      .process([...macKey, ...salt, ...iv, ...cipherText]);
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= expectMac[i] ^ mac[i];
  }
  if (diff != 0) {
    throw const FormatException('wrong password or corrupted backup');
  }
  final cipher = _aesCbc(encKey, iv, false);
  final plain = Uint8List(cipherText.length);
  for (var i = 0; i < cipherText.length; i += 16) {
    cipher.processBlock(cipherText, i, plain, i);
  }
  final zip = _pkcs7Unpad(plain);
  if (!(zip.length > 4 && zip[0] == 0x50 && zip[1] == 0x4b)) {
    throw const FormatException('wrong password or corrupted backup');
  }
  return zip;
}
