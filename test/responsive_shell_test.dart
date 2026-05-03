import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hamma/core/responsive/breakpoints.dart';

void main() {
  group('Breakpoints', () {
    Widget probe(double width, ValueSetter<BuildContext> capture) {
      return MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Builder(builder: (ctx) {
          capture(ctx);
          return const SizedBox.shrink();
        }),
      );
    }

    testWidgets('classifies mobile widths under 700', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(probe(420, (c) => ctx = c));
      expect(Breakpoints.isMobile(ctx), true);
      expect(Breakpoints.isTablet(ctx), false);
      expect(Breakpoints.isDesktop(ctx), false);
    });

    testWidgets('classifies tablet widths between 700 and 1100',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(probe(900, (c) => ctx = c));
      expect(Breakpoints.isMobile(ctx), false);
      expect(Breakpoints.isTablet(ctx), true);
      expect(Breakpoints.isDesktop(ctx), false);
    });

    testWidgets('classifies desktop widths at or above 1100', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(probe(1400, (c) => ctx = c));
      expect(Breakpoints.isDesktop(ctx), true);
      expect(Breakpoints.isTablet(ctx), false);
    });

    testWidgets('value picks tablet slot in tablet range with fallback to '
        'desktop when omitted', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(probe(900, (c) => ctx = c));
      final picked = Breakpoints.value<String>(
        ctx,
        mobile: 'm',
        tablet: 't',
        desktop: 'd',
      );
      expect(picked, 't');

      final fallbackPicked = Breakpoints.value<String>(
        ctx,
        mobile: 'm',
        desktop: 'd',
      );
      expect(fallbackPicked, 'd');
    });
  });
}
