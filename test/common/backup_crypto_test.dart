import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fl_clash/common/backup_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _makeZip() {
  final content = Uint8List.fromList(
    utf8.encode('{"network-ids":["b26bbded6b3d2f22"]}'),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('zerotier.json', content.length, content));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('encrypt/decrypt round trip', () {
    final zip = _makeZip();
    final enc = encryptZipBytes(zip, 'hunter2');
    expect(isEncryptedBackup(enc), isTrue);
    expect(isEncryptedBackup(zip), isFalse);
    expect(decryptBackupBytes(enc, 'hunter2'), equals(zip));
  });

  test('wrong password fails with FormatException', () {
    final zip = _makeZip();
    final enc = encryptZipBytes(zip, 'right-pw');
    expect(() => decryptBackupBytes(enc, 'wrong-pw'), throwsFormatException);
  });

  test('tampered ciphertext fails MAC', () {
    final zip = _makeZip();
    final enc = encryptZipBytes(zip, 'pw');
    enc[enc.length - 1] ^= 0x01;
    expect(() => decryptBackupBytes(enc, 'pw'), throwsFormatException);
  });

  test('truncated payload rejected', () {
    final zip = _makeZip();
    final enc = encryptZipBytes(zip, 'pw');
    expect(
      () => decryptBackupBytes(enc.sublist(0, 30), 'pw'),
      throwsFormatException,
    );
  });
}
