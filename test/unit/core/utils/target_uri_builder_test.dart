// Unit tests for TargetUriBuilder — the per-target URI composer that
// turns (target, recipient, message) into the click-to-chat URL that
// the system handler opens. Pure function tests, no Flutter binding
// needed; one test for SMS that's platform-sensitive is marked
// accordingly.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/utils/target_uri_builder.dart';

void main() {
  group('TargetUriBuilder.normalizePhone', () {
    test('strips spaces, dashes, parens, plus signs — keeps digits', () {
      expect(TargetUriBuilder.normalizePhone('+1 (555) 123-4567'),
          '15551234567');
    });

    test('returns null on too-short input (< 7 digits)', () {
      expect(TargetUriBuilder.normalizePhone('12345'), isNull);
      expect(TargetUriBuilder.normalizePhone('12345-6'), isNull,
          reason: '6 digits after stripping non-digits — below floor');
    });

    test('returns null on too-long input (> 15 digits)', () {
      expect(TargetUriBuilder.normalizePhone('1234567890123456'), isNull);
    });

    test('accepts exactly 7 and exactly 15 digits (range edges)', () {
      expect(TargetUriBuilder.normalizePhone('1234567'), '1234567');
      expect(TargetUriBuilder.normalizePhone('123456789012345'),
          '123456789012345');
    });

    test('returns null on pure-letter input', () {
      expect(TargetUriBuilder.normalizePhone('abcdefgh'), isNull);
    });
  });

  group('TargetUriBuilder.build — WhatsApp', () {
    test('builds a wa.me URL with URL-encoded text', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.whatsapp,
        recipient: '+1 555-123-4567',
        message: 'Hi! How are you?',
      );
      expect(res.uri, isNotNull);
      expect(res.uri!.scheme, 'https');
      expect(res.uri!.host, 'wa.me');
      expect(res.uri!.path, '/15551234567');
      // queryParameters decodes once — we want the original message back.
      expect(res.uri!.queryParameters['text'], 'Hi! How are you?');
    });

    test('returns failure for invalid phone', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.whatsapp,
        recipient: 'abc',
        message: 'hi',
      );
      expect(res.uri, isNull);
      expect(res.failureReason, contains('Phone number'));
    });
  });

  group('TargetUriBuilder.build — Telegram', () {
    test('@handle goes to https://t.me/<handle>', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.telegram,
        recipient: '@alice',
        message: 'hi',
      );
      expect(res.uri, isNotNull);
      expect(res.uri!.scheme, 'https');
      expect(res.uri!.host, 't.me');
      expect(res.uri!.path, '/alice');
      expect(res.uri!.queryParameters['text'], 'hi');
    });

    test('bare phone falls through to tg://msg?to=...', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.telegram,
        recipient: '+1 555 123 4567',
        message: 'hi',
      );
      expect(res.uri, isNotNull);
      expect(res.uri!.scheme, 'tg');
      expect(res.uri!.host, 'msg');
      expect(res.uri!.queryParameters['to'], '15551234567');
      expect(res.uri!.queryParameters['text'], 'hi');
    });

    test('empty @ rejects', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.telegram,
        recipient: '@',
        message: 'hi',
      );
      expect(res.uri, isNull);
      expect(res.failureReason, contains('handle'));
    });

    test('non-handle, non-phone rejects with both-options reason', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.telegram,
        recipient: 'not_a_thing',
        message: 'hi',
      );
      expect(res.uri, isNull);
      expect(res.failureReason, contains('@handle'));
    });
  });

  group('TargetUriBuilder.build — SMS', () {
    test('produces sms:<digits>?body=... on Android / &body=... on iOS', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.sms,
        recipient: '+1 555 123 4567',
        message: 'hi sms',
      );
      expect(res.uri, isNotNull);
      // Use toString since query separator differs by platform — the
      // *prefix* (sms:15551234567) is constant across both.
      final s = res.uri.toString();
      expect(s, startsWith('sms:15551234567'));
      expect(s.contains('body=hi%20sms') || s.contains('body=hi+sms'), isTrue,
          reason: 'message must be URL-encoded into the body param');
      // Spot-check the iOS/Android separator behaviour.
      if (Platform.isIOS) {
        expect(s, contains('&body='));
      } else {
        expect(s, contains('?body='));
      }
    });

    test('rejects invalid phone', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.sms,
        recipient: 'abc',
        message: 'hi',
      );
      expect(res.uri, isNull);
    });
  });

  group('TargetUriBuilder.build — Email', () {
    test('builds mailto: with subject + body', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.email,
        recipient: 'bob@example.com',
        message: 'body line 1\nbody line 2',
        subject: 'Hello Bob',
      );
      expect(res.uri, isNotNull);
      expect(res.uri!.scheme, 'mailto');
      // Uri.parse on mailto: puts the address in `path`.
      expect(res.uri!.path, 'bob@example.com');
      expect(res.uri!.queryParameters['subject'], 'Hello Bob');
      expect(res.uri!.queryParameters['body'], 'body line 1\nbody line 2');
    });

    test('infers subject from first line of message when subject is null',
        () {
      final res = TargetUriBuilder.build(
        target: TargetApp.email,
        recipient: 'bob@example.com',
        message: 'Quick question\nDetails follow on this line.',
      );
      expect(res.uri, isNotNull);
      expect(res.uri!.queryParameters['subject'], 'Quick question');
    });

    test('rejects obviously-invalid email address', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.email,
        recipient: 'not-an-email',
        message: 'hi',
      );
      expect(res.uri, isNull);
      expect(res.failureReason, contains('Email'));
    });

    test('rejects email without a dot in the domain', () {
      final res = TargetUriBuilder.build(
        target: TargetApp.email,
        recipient: 'bob@localhost',
        message: 'hi',
      );
      expect(res.uri, isNull);
    });
  });

  group('TargetUriBuilder.label / probeScheme', () {
    test('label returns a human-readable string for every TargetApp', () {
      for (final t in TargetApp.values) {
        final l = TargetUriBuilder.label(t);
        expect(l, isNotEmpty,
            reason: 'label must not be empty for ${t.name}');
      }
    });

    test('probeScheme returns a non-empty scheme for every TargetApp', () {
      for (final t in TargetApp.values) {
        final s = TargetUriBuilder.probeScheme(t);
        expect(s, isNotEmpty);
        expect(s, contains(':'),
            reason: 'must be parseable by canLaunchUrl');
      }
    });

    test('SMS probeScheme is the bare `sms:` so canLaunchUrl resolves', () {
      // canLaunchUrl is fussy about query-strings — bare scheme is safest.
      expect(TargetUriBuilder.probeScheme(TargetApp.sms), 'sms:');
    });
  });
}
