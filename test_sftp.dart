import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';

Future<void> test(SftpFile file) async {
  file.read();
  await file.write(Stream.empty());
  await file.writeBytes(Uint8List(0));
}
