import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/models/server_profile.dart';
import 'package:hamma/features/servers/server_list_screen.dart';

ServerProfile _server(String id) => ServerProfile(
  id: id,
  name: 'Server $id',
  host: '$id.example.test',
  port: 22,
  username: 'ubuntu',
  password: 'pw',
);

void main() {
  test('sortServersByFrecency ranks touched servers first', () {
    final sorted = sortServersByFrecency(
      [_server('a'), _server('b'), _server('c')],
      const {'c': 0.5, 'a': 2.0},
    );

    expect(sorted.map((server) => server.id), ['a', 'c', 'b']);
  });

  test('sortServersByFrecency preserves saved order for ties', () {
    final sorted = sortServersByFrecency(
      [_server('a'), _server('b'), _server('c')],
      const {'a': 1.0, 'b': 1.0},
    );

    expect(sorted.map((server) => server.id), ['a', 'b', 'c']);
  });
}
