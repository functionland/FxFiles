import 'dart:convert';

/// Configuration for the optional contact form embedded in a generated
/// "AI website". When enabled, the website generator embeds a small
/// client-side form; on submit it composes a `wa.me` / `mailto:` deep link
/// from the visitor's answers and navigates to it, so the visitor only taps
/// Send in WhatsApp / their mail app. No server ever receives the data.
///
/// NOT a Hive type on purpose: this project has no `build_runner` /
/// `hive_generator`, so a new `@HiveType` would force hand-editing generated
/// adapters. Instead the config is serialized to a single-line JSON string and
/// carried inside the generation's stored prompt as a `ContactForm:` header
/// line (see `WebsiteService` / `_composeEnrichedPrompt`). That makes it
/// round-trip through retry/Recreate with zero schema change. [toJson] is the
/// single source of truth, so a future deterministic backend-injection path can
/// send the same JSON as a `contact_form` request field instead.

/// Channel the contact form routes the visitor's message to.
enum ContactFormChannel { whatsapp, email }

/// Input type for a single contact-form field.
enum ContactFormFieldType { text, multiline, number, email, multiSelect }

ContactFormChannel _channelFromName(String? name) {
  for (final c in ContactFormChannel.values) {
    if (c.name == name) return c;
  }
  return ContactFormChannel.whatsapp;
}

ContactFormFieldType _fieldTypeFromName(String? name) {
  for (final t in ContactFormFieldType.values) {
    if (t.name == name) return t;
  }
  return ContactFormFieldType.text;
}

/// A single field in a website contact form.
class ContactFormField {
  final String label;
  final ContactFormFieldType type;
  final bool required;

  /// Choices for [ContactFormFieldType.multiSelect]; empty for other types.
  final List<String> options;

  const ContactFormField({
    required this.label,
    this.type = ContactFormFieldType.text,
    this.required = false,
    this.options = const [],
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'type': type.name,
        if (required) 'required': true,
        if (type == ContactFormFieldType.multiSelect && options.isNotEmpty)
          'options': options,
      };

  factory ContactFormField.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return ContactFormField(
      label: (json['label'] as String?)?.trim() ?? '',
      type: _fieldTypeFromName(json['type'] as String?),
      required: json['required'] as bool? ?? false,
      options: rawOptions is List
          ? rawOptions
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList(growable: false)
          : const [],
    );
  }
}

/// Configuration for an optional contact form embedded in a generated website.
class ContactFormConfig {
  final bool enabled;
  final ContactFormChannel channel;

  /// Phone number (WhatsApp) or email address (Email), as typed by the creator.
  final String destination;

  /// Optional email subject; ignored for WhatsApp. Empty when unset.
  final String emailSubject;

  final List<ContactFormField> fields;

  const ContactFormConfig({
    this.enabled = false,
    this.channel = ContactFormChannel.whatsapp,
    this.destination = '',
    this.emailSubject = '',
    this.fields = const [],
  });

  /// The default "no contact form" value.
  static const ContactFormConfig disabled = ContactFormConfig();

  /// Fields whose label is non-empty — the only ones worth rendering.
  List<ContactFormField> get usableFields => fields
      .where((f) => f.label.trim().isNotEmpty)
      .toList(growable: false);

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'channel': channel.name,
        'destination': destination,
        if (emailSubject.trim().isNotEmpty) 'emailSubject': emailSubject,
        'fields': fields.map((f) => f.toJson()).toList(),
      };

  factory ContactFormConfig.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'];
    return ContactFormConfig(
      enabled: json['enabled'] as bool? ?? false,
      channel: _channelFromName(json['channel'] as String?),
      destination: (json['destination'] as String?)?.trim() ?? '',
      emailSubject: (json['emailSubject'] as String?) ?? '',
      fields: rawFields is List
          ? rawFields
              .whereType<Map>()
              .map((e) =>
                  ContactFormField.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const [],
    );
  }

  /// Encode to a single-line JSON string for the `ContactForm:` prompt header.
  /// `jsonEncode` never emits raw newlines (any newline inside a label/option
  /// is escaped), keeping the value on one line for the header-line regex.
  String encode() => jsonEncode(toJson());

  /// Parse from a JSON string (e.g. a `ContactForm:` header value). Returns
  /// null on empty/invalid input so callers can treat it as "no form".
  static ContactFormConfig? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return ContactFormConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Malformed header — treat as no form rather than throwing.
    }
    return null;
  }
}
