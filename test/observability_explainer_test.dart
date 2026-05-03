import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/observability/observability_explainer.dart';

void main() {
  test('ObservabilityExplainerException carries its message in toString', () {
    const e = ObservabilityExplainerException('local AI required');
    expect(e.toString(), contains('local AI required'));
  });
}
