import 'package:shelf/shelf.dart';

import '../../core/utils/cipher.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/device.dart';
import 'api_responses.dart';

/// Attaches the authenticated [Device] to `request.context['device']`.
///
/// Protected routes reject requests that are missing a valid, unexpired
/// bearer token for a non-revoked device.
class AuthMiddleware {
  AuthMiddleware(this.vault);

  final Vault vault;

  Middleware requireAuth() {
    return (innerHandler) {
      return (Request request) async {
        final device = await _authenticate(request);
        if (device == null) {
          return ApiResponses.unauthorized();
        }
        return innerHandler(
          request.change(context: {...request.context, 'device': device}),
        );
      };
    };
  }

  Future<Device?> _authenticate(Request request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return null;
    final token = auth.substring(7).trim();
    if (token.isEmpty) return null;
    try {
      final device = vault.devices.findByAccessTokenHash(Cipher.sha256String(token));
      if (device == null) return null;
      vault.devices.updateLastSeen(device.id, DateTime.now());
      return device;
    } catch (e) {
      return null;
    }
  }

  Device? deviceFrom(Request request) =>
      request.context['device'] as Device?;
}