import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';

Future<void> test(SftpFile file) async {
  Stream<Uint8List> s = file.read();
  await file.write(Stream.empty());
  await file.writeBytes(Uint8List(0));
}
