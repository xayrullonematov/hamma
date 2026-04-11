import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';

void main() {
  const assessor = CommandRiskAssessor();

  test('classifies read-only commands as safe', () {
    final result = assessor.assess('df -h');

    expect(result.level, CommandRiskLevel.safe);
  });

  test('classifies service restart as warning', () {
    final result = assessor.assess('sudo systemctl restart nginx');

    expect(result.level, CommandRiskLevel.warning);
  });

  test('classifies destructive database command as dangerous', () {
    final result = assessor.assess('psql -c "DROP DATABASE app;"');

    expect(result.level, CommandRiskLevel.dangerous);
  });
}
