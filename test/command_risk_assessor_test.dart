import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/ai/command_risk_assessor.dart';

void main() {
  const assessor = CommandRiskAssessor();

  test('classifies read-only commands as low risk', () {
    final result = assessor.assess('df -h');

    expect(result.riskLevel, CommandRiskLevel.low);
  });

  test('classifies service restart as moderate risk', () {
    final result = assessor.assess('sudo systemctl restart nginx');

    expect(result.riskLevel, CommandRiskLevel.moderate);
  });

  test('classifies dangerous patterns as critical risk', () {
    final result = assessor.assess('rm -rf /');

    expect(result.riskLevel, CommandRiskLevel.critical);
  });

  test('static assessFast works correctly', () {
    expect(CommandRiskAssessor.assessFast('rm -rf .'), CommandRiskLevel.critical);
    expect(CommandRiskAssessor.assessFast('ls'), isNull);
  });
}
