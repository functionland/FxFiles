// Tests for GoogleFormsService — the seam that decides whether a generated
// website's embedded Google Form is answerable by an anonymous visitor.
//
// The bug these guard against: the service used to create + populate a form and
// stop, which leaves the form (a) unpublished and (b) unshared, and on Workspace
// accounts (c) collecting VERIFIED emails. Any one of those makes the form's
// responder URI answer 401 to a website visitor, i.e. "please sign in".
//
// The through-line of the assertions below is that the service must never hand
// back a URI it has not confirmed is publicly answerable — failing the whole
// generation is the intended behaviour, because the alternative is a website
// whose contact form is silently broken for everyone.
//
// All requests are captured through MockClient; nothing here talks to Google.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/services/google_forms_service.dart';

const _formId = 'form-123';
const _createdUri = 'https://docs.google.com/forms/d/e/CREATED/viewform';
const _publishedUri = 'https://docs.google.com/forms/d/e/PUBLISHED/viewform';

String _formJson({
  bool? isPublished = true,
  String? responderUri = _publishedUri,
  String? emailCollectionType,
}) =>
    jsonEncode({
      'formId': _formId,
      if (responderUri != null) 'responderUri': responderUri,
      if (emailCollectionType != null)
        'settings': {'emailCollectionType': emailCollectionType},
      if (isPublished != null)
        'publishSettings': {
          'publishState': {'isPublished': isPublished}
        },
    });

/// A MockClient answering every step happily, recording each request, with
/// per-endpoint overrides. `onGet` receives the 0-based GET attempt number so
/// tests can model read-after-write lag.
({http.Client client, List<http.Request> log}) _mock({
  http.Response Function()? onPublish,
  http.Response Function()? onShare,
  http.Response Function(int attempt)? onGet,
}) {
  final log = <http.Request>[];
  var gets = 0;
  final client = MockClient((req) async {
    log.add(req);
    final path = req.url.path;

    if (req.method == 'GET') {
      final attempt = gets++;
      return onGet?.call(attempt) ?? http.Response(_formJson(), 200);
    }
    if (path.endsWith(':setPublishSettings')) {
      return onPublish?.call() ?? http.Response('{}', 200);
    }
    if (path.endsWith(':batchUpdate')) {
      return http.Response('{}', 200);
    }
    if (path.contains('/drive/v3/files/')) {
      return onShare?.call() ??
          http.Response(jsonEncode({'id': 'anyoneWithLink'}), 200);
    }
    // forms.create
    return http.Response(
      jsonEncode({'formId': _formId, 'responderUri': _createdUri}),
      200,
    );
  });
  return (client: client, log: log);
}

Future<String> _run(
  http.Client client, {
  List<ContactFormField> fields = const [],
}) =>
    GoogleFormsService(client: client, retryBackoff: Duration.zero).createForm(
      title: 'Enquiries',
      fields: fields,
      accessToken: 'tok',
    );

Map<String, dynamic> _bodyOf(http.Request req) =>
    jsonDecode(req.body) as Map<String, dynamic>;

http.Request _find(List<http.Request> log, bool Function(http.Request) p) =>
    log.firstWhere(p);

void main() {
  group('createForm makes the form publicly answerable', () {
    test('publishes the form after populating it', () async {
      final m = _mock();
      await _run(m.client);

      final publish =
          _find(m.log, (r) => r.url.path.endsWith(':setPublishSettings'));
      expect(_bodyOf(publish), {
        'publishSettings': {
          'publishState': {'isPublished': true, 'isAcceptingResponses': true}
        },
        'updateMask': 'publishState',
      });

      // Questions must exist before the form goes live.
      final order = m.log.map((r) => r.url.path).toList();
      expect(order.indexWhere((p) => p.endsWith(':batchUpdate')),
          lessThan(order.indexWhere((p) => p.endsWith(':setPublishSettings'))));
    });

    test('grants anyone-with-the-link responder access via Drive', () async {
      final m = _mock();
      await _run(m.client);

      final share = _find(m.log, (r) => r.url.path.contains('/drive/v3/files/'));
      expect(share.url.path, '/drive/v3/files/$_formId/permissions');
      // These three fields together are what Google's publish guide checks for.
      expect(_bodyOf(share),
          {'type': 'anyone', 'view': 'published', 'role': 'reader'});
      // Without this a form living on a shared drive 404s.
      expect(share.url.queryParameters['supportsAllDrives'], 'true');
    });

    test('disables VERIFIED email collection, which would force a sign-in',
        () async {
      final m = _mock();
      await _run(m.client);

      final batch = _find(m.log, (r) => r.url.path.endsWith(':batchUpdate'));
      final requests = _bodyOf(batch)['requests'] as List;
      expect(requests.first, {
        'updateSettings': {
          'settings': {'emailCollectionType': 'DO_NOT_COLLECT'},
          'updateMask': 'emailCollectionType',
        }
      });
    });

    test('sets the email-collection setting even with no fields', () async {
      final m = _mock();
      await _run(m.client, fields: const []);

      // The old code skipped batchUpdate entirely when there were no fields,
      // which would have skipped the setting too.
      final batch = _find(m.log, (r) => r.url.path.endsWith(':batchUpdate'));
      expect((_bodyOf(batch)['requests'] as List), hasLength(1));
    });

    test('still sends the questions alongside the settings request', () async {
      final m = _mock();
      await _run(m.client, fields: const [
        ContactFormField(label: 'Name', required: true),
        ContactFormField(label: 'Notes', type: ContactFormFieldType.multiline),
        ContactFormField(
            label: 'Interest',
            type: ContactFormFieldType.multiSelect,
            options: ['A', 'B']),
      ]);

      final requests = _bodyOf(
              _find(m.log, (r) => r.url.path.endsWith(':batchUpdate')))['requests']
          as List;
      expect(requests, hasLength(4)); // 1 settings + 3 items

      final first = requests[1]['createItem']['item'];
      expect(first['title'], 'Name');
      expect(first['questionItem']['question']['required'], true);
      expect(
          first['questionItem']['question']['textQuestion']['paragraph'], false);

      expect(
          requests[2]['createItem']['item']['questionItem']['question']
              ['textQuestion']['paragraph'],
          true);

      final choice = requests[3]['createItem']['item']['questionItem']
          ['question']['choiceQuestion'];
      expect(choice['type'], 'CHECKBOX');
      expect(choice['options'], [
        {'value': 'A'},
        {'value': 'B'}
      ]);
      // Item indices address an initially-empty form; updateSettings must not
      // occupy one of those positions.
      expect(requests[1]['createItem']['location']['index'], 0);
      expect(requests[3]['createItem']['location']['index'], 2);
    });
  });

  group('responder URI comes only from a confirmed read', () {
    test('returns the published URI, not the create-time one', () async {
      final m = _mock();
      expect(await _run(m.client), _publishedUri);
    });

    test('accepts forms that omit publishSettings entirely', () async {
      // Pre-publishing-model forms are responder-visible once shared.
      final m = _mock(
          onGet: (_) => http.Response(_formJson(isPublished: null), 200));
      expect(await _run(m.client), _publishedUri);
    });

    test('retries through read-after-write lag on isPublished', () async {
      final m = _mock(
        onGet: (attempt) => http.Response(
            _formJson(isPublished: attempt >= 2 ? true : false), 200),
      );
      expect(await _run(m.client), _publishedUri);
    });

    test('retries a transient failure of the confirming read', () async {
      final m = _mock(
        onGet: (attempt) => attempt == 0
            ? http.Response('boom', 500)
            : http.Response(_formJson(), 200),
      );
      expect(await _run(m.client), _publishedUri);
    });
  });

  group('fails loudly rather than embedding a form that demands a sign-in', () {
    test('throws when publishing fails', () async {
      final m = _mock(onPublish: () => http.Response('bad request', 400));
      await expectLater(_run(m.client), throwsA(isA<Exception>()));
    });

    test('throws when the anyone-with-link permission fails', () async {
      final m = _mock(onShare: () => http.Response('denied', 403));
      await expectLater(_run(m.client), throwsA(isA<Exception>()));
    });

    test('names the Workspace admin policy on a 403', () async {
      final m = _mock(onShare: () => http.Response('denied', 403));
      await expectLater(
        _run(m.client),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('Workspace'))),
      );
    });

    test('does NOT fall back to the unconfirmed create-time URI', () async {
      // The regression this guards: falling back here would embed a URI whose
      // published-ness was never verified — the original bug, silently.
      final m = _mock(onGet: (_) => http.Response('nope', 500));
      await expectLater(
        _run(m.client),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            allOf(contains('Could not confirm'), isNot(contains(_createdUri))))),
      );
    });

    test('throws when the form stays unpublished across every retry', () async {
      final m =
          _mock(onGet: (_) => http.Response(_formJson(isPublished: false), 200));
      await expectLater(
        _run(m.client),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('Could not confirm'))),
      );
    });

    test('throws immediately when the form collects VERIFIED emails', () async {
      final m = _mock(
        onGet: (_) => http.Response(
            _formJson(emailCollectionType: 'VERIFIED'), 200),
      );
      await expectLater(
        _run(m.client),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('sign in'))),
      );
    });

    test('surfaces the form id so the orphaned form can be found', () async {
      final m = _mock(onShare: () => http.Response('denied', 403));
      await expectLater(
        _run(m.client),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains(_formId))),
      );
    });

    test('throws on a malformed create response instead of a type error',
        () async {
      final client = MockClient((_) async => http.Response('{"ok":true}', 200));
      await expectLater(
        GoogleFormsService(client: client, retryBackoff: Duration.zero)
            .createForm(title: 't', fields: const [], accessToken: 'tok'),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('Unexpected'))),
      );
    });
  });

  group('transient server errors', () {
    test('retries a 5xx on publish and succeeds', () async {
      var calls = 0;
      final m = _mock(onPublish: () {
        calls++;
        return calls == 1
            ? http.Response('upstream', 503)
            : http.Response('{}', 200);
      });
      expect(await _run(m.client), _publishedUri);
      expect(calls, 2);
    });

    test('does not retry a 4xx', () async {
      var calls = 0;
      final m = _mock(onShare: () {
        calls++;
        return http.Response('denied', 403);
      });
      await expectLater(_run(m.client), throwsA(isA<Exception>()));
      expect(calls, 1);
    });
  });
}
