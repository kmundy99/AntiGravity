import 'package:flutter/foundation.dart';

class LinkUtils {
  /// Returns the base URL for generating deep links or shareable links.
  /// When running on the web, this dynamically determines the origin (e.g., localhost vs production).
  /// For mobile, it defaults to the production domain.
  static String getBaseUrl() {
    if (kIsWeb) {
      String base = Uri.base.toString().split('#').first;
      if (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      return base;
    }
    return 'https://www.adhoc-local.com';
  }
}
