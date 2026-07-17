import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fula_files/core/models/contact_form_config.dart';

class GoogleFormsService {
  GoogleFormsService._();
  static final instance = GoogleFormsService._();

  Future<String> createForm({
    required String title,
    required List<ContactFormField> fields,
    required String accessToken,
  }) async {
    // 1. Create the empty form
    final createRes = await http.post(
      Uri.parse('https://forms.googleapis.com/v1/forms'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'info': {
          'title': title.isEmpty ? 'Contact Form' : title,
          'documentTitle': title.isEmpty ? 'Contact Form' : title,
        },
      }),
    );

    if (createRes.statusCode != 200) {
      throw Exception('Failed to create Google Form: ${createRes.body}');
    }

    final formData = jsonDecode(createRes.body);
    final formId = formData['formId'];
    final responderUri = formData['responderUri'];

    // 2. Update the form with fields
    if (fields.isNotEmpty) {
      final requests = <Map<String, dynamic>>[];
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

      final updateRes = await http.post(
        Uri.parse('https://forms.googleapis.com/v1/forms/$formId:batchUpdate'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'requests': requests,
        }),
      );

      if (updateRes.statusCode != 200) {
        throw Exception('Failed to update Google Form fields: ${updateRes.body}');
      }
    }

    return responderUri as String;
  }
}
