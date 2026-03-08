import 'dart:convert';
import 'package:http/http.dart' as http;
import '../secrets.dart';

class CloudFunctionsService {
  /// Generates fully-rendered email drafts for all pending scheduled messages
  /// on [sessionDate] (YYYY-MM-DD). Deletes existing pending_approval drafts
  /// for that date first, then stores new ones as pending_approval.
  static Future<int> generateSessionMessages({
    required String contractId,
    required String sessionDate,
    String? messageType,
  }) async {
    final payload = {'contractId': contractId, 'sessionDate': sessionDate};
    if (messageType != null) payload['messageType'] = messageType;
    final response = await http.post(
      Uri.parse(generateSessionMessagesUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Generation failed');
    }
    return body['count'] as int? ?? 0;
  }

  /// Sends all pending_approval messages for [sessionDate] (YYYY-MM-DD).
  /// For lineup_publish: also publishes the session assignment.
  static Future<int> sendApprovedMessages({
    required String contractId,
    required String sessionDate,
    String? messageType,
  }) async {
    final payload = {'contractId': contractId, 'sessionDate': sessionDate};
    if (messageType != null) payload['messageType'] = messageType;
    final response = await http.post(
      Uri.parse(sendApprovedMessagesUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Send failed');
    }
    return body['count'] as int? ?? 0;
  }
}
