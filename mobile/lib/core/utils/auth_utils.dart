import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Generates the HMAC-SHA256 authentication token for the signaling server.
///
/// Token formula: HMAC-SHA256(key=authSecret, message="reporterId:timestamp")
///
/// The result is a hex string matching what AuthService.ts on the server expects.
String computeAuthToken({
  required String reporterId,
  required int timestamp,
  required String authSecret,
}) {
  final key = utf8.encode(authSecret);
  final message = utf8.encode('$reporterId:$timestamp');
  final hmac = Hmac(sha256, key);
  final digest = hmac.convert(message);
  return digest.toString(); // hex string
}
