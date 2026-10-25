import 'dart:typed_data';

/// "7b ff 07 …" — lowercase, space separated, easy to compare with the docs.
String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
