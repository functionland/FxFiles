import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Build per-target URIs for bulk-send tasks (Automate feature, and the
/// hidden AI Automation feature when it's re-enabled).
///
/// Each target uses the documented, click-to-chat-style URL scheme the
/// platform supports. The recipient still has to tap Send inside the
/// target app — these URLs do not auto-send. That's the deliberate
/// compliance posture (WhatsApp ToS, App Store / Play Store policies).

class TargetUriResult {
  final Uri? uri;
  final String? failureReason;
  const TargetUriResult.ok(Uri this.uri) : failureReason = null;
  const TargetUriResult.fail(String reason)
      : uri = null,
        failureReason = reason;
}

class TargetUriBuilder {
  TargetUriBuilder._();

  /// Build the appropriate URI for [target], [recipient] (phone or email),
  /// and the rendered [message]. Returns a failure result with a
  /// human-readable reason when the input is unusable — callers mark the
  /// row as [SendStatus.failed] and surface the reason.
  static TargetUriResult build({
    required TargetApp target,
    required String recipient,
    required String message,
    String? subject, // email-only — defaults to first line of message
  }) {
    switch (target) {
      case TargetApp.whatsapp:
        return _whatsapp(recipient, message);
      case TargetApp.telegram:
        return _telegram(recipient, message);
      case TargetApp.sms:
        return _sms(recipient, message);
      case TargetApp.email:
        return _email(recipient, subject, message);
    }
  }

  /// WhatsApp click-to-chat. International phone number, digits only,
  /// no leading `+`, no separators. https://faq.whatsapp.com/5913398998672934
  static TargetUriResult _whatsapp(String phone, String message) {
    final normalized = normalizePhone(phone);
    if (normalized == null) {
      return const TargetUriResult.fail('Phone number is invalid');
    }
    return TargetUriResult.ok(Uri.parse(
        'https://wa.me/$normalized?text=${Uri.encodeComponent(message)}'));
  }

  /// Telegram supports both `@username` and a raw phone number via
  /// `tg://msg?to=...`. We pick the path that works without prior contact
  /// when possible.
  static TargetUriResult _telegram(String recipient, String message) {
    final encoded = Uri.encodeComponent(message);
    if (recipient.startsWith('@')) {
      final handle = recipient.substring(1);
      if (handle.isEmpty) {
        return const TargetUriResult.fail('Telegram handle is empty');
      }
      return TargetUriResult.ok(
          Uri.parse('https://t.me/$handle?text=$encoded'));
    }
    final normalized = normalizePhone(recipient);
    if (normalized == null) {
      return const TargetUriResult.fail(
          'Telegram needs an @handle or a phone number');
    }
    return TargetUriResult.ok(Uri.parse('tg://msg?to=$normalized&text=$encoded'));
  }

  /// SMS uses `?body=` on Android, `&body=` on iOS per Apple's docs.
  /// https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/SMSLinks/SMSLinks.html
  static TargetUriResult _sms(String phone, String message) {
    final normalized = normalizePhone(phone);
    if (normalized == null) {
      return const TargetUriResult.fail('Phone number is invalid');
    }
    final body = Uri.encodeComponent(message);
    // PlatformCapabilities (kIsWeb-safe) instead of dart:io Platform so
    // the web shell can import this builder.
    final separator = PlatformCapabilities.isIOS ? '&' : '?';
    return TargetUriResult.ok(Uri.parse('sms:$normalized${separator}body=$body'));
  }

  /// `mailto:` works on every platform with a default mail handler.
  static TargetUriResult _email(String address, String? subject, String body) {
    final trimmed = address.trim();
    if (!_looksLikeEmail(trimmed)) {
      return const TargetUriResult.fail('Email address is invalid');
    }
    final params = <String, String>{};
    final inferredSubject =
        subject ?? body.split('\n').first.trim();
    if (inferredSubject.isNotEmpty) params['subject'] = inferredSubject;
    if (body.isNotEmpty) params['body'] = body;
    final query =
        params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final uri = query.isEmpty ? 'mailto:$trimmed' : 'mailto:$trimmed?$query';
    return TargetUriResult.ok(Uri.parse(uri));
  }

  /// Strip every non-digit; validate length is 7-15 (the loosest sensible
  /// range — E.164 caps at 15, the shortest national format is ~7).
  /// Returns null when the input can't be turned into a usable phone.
  static String? normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7 || digits.length > 15) return null;
    return digits;
  }

  static bool _looksLikeEmail(String s) {
    // Deliberately loose; the OS does the real validation when it opens the
    // mail handler. We just want to reject obvious garbage like "abc".
    final at = s.indexOf('@');
    if (at <= 0 || at == s.length - 1) return false;
    if (s.indexOf('.', at) <= at + 1) return false;
    return true;
  }

  /// The URL scheme this target launches with — used by
  /// `InstalledAppsService.detect` to probe `canLaunchUrl`.
  static String probeScheme(TargetApp target) {
    switch (target) {
      case TargetApp.whatsapp:
        return 'whatsapp://send';
      case TargetApp.telegram:
        return 'tg://msg';
      case TargetApp.sms:
        return 'sms:';
      case TargetApp.email:
        return 'mailto:';
    }
  }

  static String label(TargetApp target) {
    switch (target) {
      case TargetApp.whatsapp:
        return 'WhatsApp';
      case TargetApp.telegram:
        return 'Telegram';
      case TargetApp.sms:
        return 'SMS / Messages';
      case TargetApp.email:
        return 'Email';
    }
  }
}
