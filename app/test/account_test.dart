import 'package:flutter_test/flutter_test.dart';
import 'package:wreckbox/account.dart';

void main() {
  test('password key matches the reference PBKDF2-HMAC-SHA256', () async {
    // python3 -c "import hashlib;print(hashlib.pbkdf2_hmac('sha256',b'correct horse',b'wreckbox:dj@example.com',200000).hex())"
    final k = await Account.deriveKey(' DJ@Example.com ', 'correct horse');
    expect(k, '3f68bba26091f8b763d6e574c5502e0be4dc5151df52e35a98ada590224f5755'); // same value Swift's CommonCrypto gives
  });
}
