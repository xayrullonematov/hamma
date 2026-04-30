import 'package:flutter/widgets.dart';

class Breakpoints {
  Breakpoints._();

  static const double mobile = 700;
  static const double tablet = 1100;

  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < mobile;

  static bool isTablet(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= mobile && w < tablet;
  }

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tablet;

  static T value<T>(
    BuildContext context, {
    required T mobile,
    T? tablet,
    required T desktop,
  }) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < Breakpoints.mobile) return mobile;
    if (w < Breakpoints.tablet) return tablet ?? desktop;
    return desktop;
  }
}
