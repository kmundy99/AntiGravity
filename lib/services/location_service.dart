import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  Map<String, Map<String, double>> _zipCoordinates = {};
  bool _isLoaded = false;

  /// Loads the zip code mapping from assets. Should be called early, e.g., in main.dart
  Future<void> loadZipData() async {
    if (_isLoaded) return;
    try {
      final String jsonString = await rootBundle.loadString('assets/us_zip_codes.json');
      final Map<String, dynamic> rawMap = jsonDecode(jsonString);
      
      rawMap.forEach((key, value) {
        final lat = value['lat'];
        final lon = value['lon'];
        if (lat is num && lon is num) {
          _zipCoordinates[key] = {
            'lat': lat.toDouble(),
            'lon': lon.toDouble(),
          };
        }
      });
      _isLoaded = true;
    } catch (e) {
      // It's acceptable for this to fail if the asset isn't present or bad JSON
      print('Error loading zip code data: $e');
    }
  }

  /// Extracts the first 5-digit zip code from a generic address string.
  /// Returns null if no valid 5-digit sequence is found.
  String? extractZipCode(String address) {
    if (address.isEmpty) return null;
    final regex = RegExp(r'\b\d{5}\b');
    final match = regex.firstMatch(address);
    return match?.group(0);
  }

  /// Retrieves lat/lon for a given 5-digit zip code.
  Map<String, double>? getCoordinates(String zipCode) {
    return _zipCoordinates[zipCode];
  }

  /// Calculates the Haversine distance in miles between two coordinates.
  double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const double r = 3958.8; // Earth's radius in miles
    final double dLat = _toRadians(lat2 - lat1);
    final double dLon = _toRadians(lon2 - lon1);

    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final double c = 2 * math.asin(math.sqrt(a));
    return r * c;
  }

  double _toRadians(double degree) {
    return degree * math.pi / 180;
  }

  /// Calls the Google Places Details API to get a formatted address (including zip code)
  /// for the given placeId. Returns null on error or if the field is missing.
  static Future<String?> fetchFormattedAddress(String placeId, String apiKey) async {
    try {
      final response = await http.get(
        Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
        headers: {
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'formattedAddress',
        },
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return json['formattedAddress'] as String?;
      }
    } catch (e) {
      // Fall back to the autocomplete text
    }
    return null;
  }

  /// Calculates the distance in miles between two address strings by extracting their zip codes.
  /// Returns null if either address doesn't contain a zip code, or if the zip code isn't in our database.
  double? getDistanceBetweenAddresses(String address1, String address2) {
    final zip1 = extractZipCode(address1);
    final zip2 = extractZipCode(address2);

    if (zip1 == null || zip2 == null) return null;

    final coords1 = getCoordinates(zip1);
    final coords2 = getCoordinates(zip2);

    if (coords1 == null || coords2 == null) return null;

    return _haversineDistance(
      coords1['lat']!,
      coords1['lon']!,
      coords2['lat']!,
      coords2['lon']!,
    );
  }
}
