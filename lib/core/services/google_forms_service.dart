import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fula_files/core/models/contact_form_config.dart';

/// Creates a Google Form in the signed-in user's own Drive and returns the
/// responder URI that a generated website embeds as an iframe.
///
/// A form is only answerable by an anonymous website visitor when THREE things
/// hold, and the API defaults get all three wrong for this use case:
///
///  1. `emailCollectionType` is not `VERIFIED`. It defaults to `VERIFIED` when
///     the form owner is on a Google Workspace account, and `VERIFIED` reads the
///     responder's address from their signed-in Google account — i.e. it forces
///     a sign-in even on an otherwise fully public form.
///  2. The form is published. API-created forms are born unpublished, and an
///     unpublished form's responder URI answers 401 to everyone but its editors
///     — which is exactly the "visitors are asked to sign in" symptom.
///  3. A Drive permission of `{type: anyone, view: published, role: reader}`
///     exists. Publishing alone does NOT grant anyone-with-the-link access;
///     that permission is what Google's own publish guide checks for.
///
/// All three are reachable with the `drive.file` scope the app already requests
/// (see `AuthService.requestFormsScope`), so no extra OAuth consent is needed.
///
/// Every step fails loudly rather than degrading. A form that silently ends up
/// private produces a website whose contact form is broken for every visitor,
/// and the creator would only find out when enquiries stop arriving — so an
/// aborted generation the user can retry is strictly better than a quiet one.
/// Thrown messages carry the form id, since a failure part-way through leaves
/// a half-built form in the user's Drive.
class GoogleFormsService {
  GoogleFormsService({
    http.Client? client,
    Duration retryBackoff = const Duration(milliseconds: 400),
  })  : _client = client ?? http.Client(),
        _retryBackoff = retryBackoff;

  final http.Client _client;

  /// Base delay between retries; scaled by attempt number. Zero in tests.
  final Duration _retryBackoff;

  static final instance = GoogleFormsService();

  static const _maxAttempts = 4;

  Future<String> createForm({
    required String title,
    required List<ContactFormField> fields,
    required String accessToken,
  }) async {
    final formTitle = title.isEmpty ? 'Contact Form' : title;

    // 1. Create the empty form.
    final createRes = await _client.post(
      Uri.parse('https://forms.googleapis.com/v1/forms'),
      headers: _headers(accessToken),
      body: jsonEncode({
        'info': {'title': formTitle, 'documentTitle': formTitle},
      }),
    );

    if (createRes.statusCode != 200) {
      throw Exception('Failed to create Google Form: ${createRes.body}');
    }

    final created = _tryDecodeMap(createRes.body);
    if (created == null ||
        created['formId'] is! String ||
        created['responderUri'] is! String) {
      throw Exception(
          'Unexpected Google Form create response: ${createRes.body}');
    }
    final formId = created['formId'] as String;

    // 2. Add the questions and turn off verified-email collection.
    await _applyBody(formId: formId, fields: fields, accessToken: accessToken);

    // 3. Publish, then 4. share with anyone holding the link. Both are needed;
    //    neither substitutes for the other.
    await _publish(formId: formId, accessToken: accessToken);
    await _shareWithAnyone(formId: formId, accessToken: accessToken);

    // 5. Confirm, and take the responder URI from the confirmed read.
    return _confirmedResponderUri(formId: formId, accessToken: accessToken);
  }

  /// Questions + email-collection setting, in one batch so the form is never
  /// briefly live with `VERIFIED` collection. `updateSettings` goes first; it
  /// mutates form-level settings and neither consumes nor shifts item indices,
  /// so the `createItem` entries still address positions 0..n-1 of an initially
  /// empty form.
  Future<void> _applyBody({
    required String formId,
    required List<ContactFormField> fields,
    required String accessToken,
  }) async {
    final requests = <Map<String, dynamic>>[
      {
        'updateSettings': {
          'settings': {'emailCollectionType': 'DO_NOT_COLLECT'},
          'updateMask': 'emailCollectionType',
        }
      },
    ];

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];

      Map<String, dynamic> item = {
        'title': field.label,
      };

      if (field.type == ContactFormFieldType.text ||
          field.type == ContactFormFieldType.email ||
          field.type == ContactFormFieldType.number) {
        item['questionItem'] = {
          'question': {
            'required': field.required,
            'textQuestion': {'paragraph': false}
          }
        };
      } else if (field.type == ContactFormFieldType.multiline) {
        item['questionItem'] = {
          'question': {
            'required': field.required,
            'textQuestion': {'paragraph': true}
          }
        };
      } else if (field.type == ContactFormFieldType.multiSelect) {
        item['questionItem'] = {
          'question': {
            'required': field.required,
            'choiceQuestion': {
              'type': 'CHECKBOX', // allows multiple selections
              'options': field.options.map((opt) => {'value': opt}).toList(),
            }
          }
        };
      }

      requests.add({
        'createItem': {
          'item': item,
          'location': {'index': i}
        }
      });
    }

    final res = await _client.post(
      Uri.parse('https://forms.googleapis.com/v1/forms/$formId:batchUpdate'),
      headers: _headers(accessToken),
      body: jsonEncode({'requests': requests}),
    );

    if (res.statusCode != 200) {
      throw Exception(
          'Failed to update Google Form ($formId) fields: ${res.body}');
    }
  }

  /// Publish the form so responders can reach it at all.
  ///
  /// Any non-2xx throws — including 400. A 400 would mean this form does not
  /// support the publishing model, which cannot happen for a form created
  /// seconds earlier; in practice it would mean this request body is wrong, and
  /// swallowing that would silently ship the private-form bug this method
  /// exists to prevent.
  Future<void> _publish({
    required String formId,
    required String accessToken,
  }) async {
    final res = await _postWithRetry(
      Uri.parse(
          'https://forms.googleapis.com/v1/forms/$formId:setPublishSettings'),
      accessToken: accessToken,
      body: {
        'publishSettings': {
          'publishState': {'isPublished': true, 'isAcceptingResponses': true}
        },
        'updateMask': 'publishState',
      },
    );

    if (res.statusCode != 200) {
      throw Exception(_accessError('publish the Google Form', formId, res));
    }
  }

  /// Grant anyone-with-the-link responder access. Drive v3 answers 200 with the
  /// created Permission resource. `supportsAllDrives` is set because a Workspace
  /// policy can land the form on a shared drive, where the call 404s without it.
  Future<void> _shareWithAnyone({
    required String formId,
    required String accessToken,
  }) async {
    final res = await _postWithRetry(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$formId/permissions'
          '?supportsAllDrives=true'),
      accessToken: accessToken,
      body: {
        'type': 'anyone',
        'view': 'published',
        'role': 'reader',
      },
    );

    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception(_accessError(
          'make the Google Form answerable by anyone', formId, res));
    }
  }

  /// Re-read the form until it confirms a publicly answerable state, and return
  /// the responder URI from that confirmed read.
  ///
  /// This is load-bearing on purpose. The create-time `responderUri` is issued
  /// before the form has publish settings, and Google documents `responderUri`
  /// as the published URI only "for forms that have publishSettings value set"
  /// — so falling back to the pre-publish value would bake an unverified URL
  /// into a website. Failing is the safer half of that trade.
  ///
  /// Retried because `setPublishSettings` is not guaranteed to be read-after-
  /// write consistent: a GET issued milliseconds later can still report the
  /// previous state, and aborting on that would be a false negative.
  Future<String> _confirmedResponderUri({
    required String formId,
    required String accessToken,
  }) async {
    Object? lastProblem;

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryBackoff * attempt);
      }

      final http.Response res;
      try {
        res = await _client.get(
          Uri.parse('https://forms.googleapis.com/v1/forms/$formId'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
      } catch (e) {
        lastProblem = e;
        continue;
      }
      if (res.statusCode != 200) {
        lastProblem = 'read back ${res.statusCode}: ${res.body}';
        continue;
      }

      final body = _tryDecodeMap(res.body);
      if (body == null) {
        lastProblem = 'unreadable read-back response';
        continue;
      }

      // Not retryable: a form that still collects verified emails will demand a
      // sign-in no matter how long we wait.
      final settings = body['settings'];
      if (settings is Map && settings['emailCollectionType'] == 'VERIFIED') {
        throw Exception(
            'The Google Form ($formId) is set to collect verified email '
            'addresses, which forces every visitor to sign in. Please try '
            'again, or turn off email collection in Google Forms.');
      }

      // Only an explicit `false` is a failure. Forms predating the publishing
      // model omit `publishSettings` entirely and are responder-visible once
      // shared, so treat absent as acceptable.
      final publishSettings = body['publishSettings'];
      final publishState =
          publishSettings is Map ? publishSettings['publishState'] : null;
      if (publishState is Map && publishState['isPublished'] == false) {
        lastProblem = 'form still reports isPublished=false';
        continue;
      }

      final uri = body['responderUri'];
      if (uri is String && uri.isNotEmpty) return uri;
      lastProblem = 'read-back had no responderUri';
    }

    throw Exception(
        'Could not confirm the Google Form ($formId) is publicly answerable, '
        'so it was not added to the website. Please try again. ($lastProblem)');
  }

  /// POST with retries for transient failures. 5xx and network errors are
  /// retried; 4xx is returned as-is, since those are contract errors that
  /// retrying only delays. Both callers are idempotent — re-publishing the same
  /// state and re-granting the same anyone-with-link permission are no-ops.
  Future<http.Response> _postWithRetry(
    Uri url, {
    required String accessToken,
    required Object body,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryBackoff * attempt);
      }
      try {
        final res = await _client.post(
          url,
          headers: _headers(accessToken),
          body: jsonEncode(body),
        );
        if (res.statusCode < 500) return res;
        lastError = '${res.statusCode}: ${res.body}';
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception('Google API request to $url kept failing after '
        '$_maxAttempts attempts. ($lastError)');
  }

  Map<String, dynamic>? _tryDecodeMap(String source) {
    try {
      final decoded = jsonDecode(source);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers(String accessToken) => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  /// 403 here is usually a Workspace admin policy blocking external sharing —
  /// worth naming, because no amount of retrying will clear it.
  String _accessError(String action, String formId, http.Response res) {
    if (res.statusCode == 403) {
      return 'Could not $action ($formId). If you signed in with a Google '
          'Workspace account, your administrator may block sharing files '
          'outside your organization — try a personal Google account or ask '
          'your admin. (403: ${res.body})';
    }
    return 'Could not $action ($formId) — ${res.statusCode}: ${res.body}';
  }
}
