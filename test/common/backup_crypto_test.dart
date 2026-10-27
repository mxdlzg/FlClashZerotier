import 'dart:typed_data';

import 'package:fl_clash/common/backup_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _fakeZip() {
  return Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, ...List.filled(200, 7)]);
}

void main() {
  test('encrypt/decrypt round trip', () {
    final zip = _fakeZip();
    final enc = encryptZipBytes(zip, 'hunter2');
    expect(isEncryptedBackup(enc), isTrue);
    expect(isEncryptedBackup(zip), isFalse);
    expect(decryptBackupBytes(enc, 'hunter2'), equals(zip));
  });

  test('wrong password fails with FormatException', () {
    final zip = _fakeZip();
    final enc = encryptZipBytes(zip, 'right-pw');
    expect(() => decryptBackupBytes(enc, 'wrong-pw'), throwsFormatException);
  });

  test('tampered ciphertext fails MAC', () {
    final zip = _fakeZip();
    final enc = encryptZipBytes(zip, 'pw');
    enc[enc.length - 1] ^= 0x01;
    expect(() => decryptBackupBytes(enc, 'pw'), throwsFormatException);
  });

  test('truncated payload rejected', () {
    final zip = _fakeZip();
    final enc = encryptZipBytes(zip, 'pw');
    expect(
      () => decryptBackupBytes(enc.sublist(0, 30), 'pw'),
      throwsFormatException,
    );
  });
}
