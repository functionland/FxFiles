import 'dart:convert';

import 'package:fula_files/core/models/contact_form_config.dart';

/// Build a self-contained, **client-side-only** `<form>` + `<script>` block
/// that a generated website embeds. On submit it composes a `wa.me` /
/// `mailto:` deep link from the visitor's answers and navigates to it, so the
/// visitor only taps Send in WhatsApp / their mail app. No server receives the
/// data and there is no `action` attribute.
///
/// Composed message shape: an optional `#Title: <header>` line first (from
/// [ContactFormConfig.title]), then one `Label: value` line per answered
/// field, then a `#Ref: <page URL>` line capturing `location.href` of the
/// page the visitor submitted from.
///
/// Mirrors `lib/core/utils/target_uri_builder.dart` exactly: WhatsApp numbers
/// are reduced to digits only and must be 7–15 long; every message component is
/// `encodeURIComponent`-escaped at send time so user input can never break the
/// URL.
///
/// Kept compact (~1–1.5 KB) so the verbatim snippet stays a small share of
/// the generated output.
/// Stable tokens the post-generation verifier checks for: `id="cf"`,
/// `encodeURIComponent`, and `wa.me/` (WhatsApp) or `mailto:` (Email).
String buildContactFormSnippet(ContactFormConfig cfg) {
  final rows = StringBuffer();
  for (final field in cfg.usableFields) {
    rows.write(_fieldMarkup(field, field.label.trim()));
  }

  // Injected as JS string literals via `_jsString` (jsonEncode + `</script>`
  // hardening) so quotes/specials/`</script>` in the creator's
  // destination/subject can't break out of the JS string or the <script> block.
  final dest = _jsString(cfg.destination.trim());
  final subject = _jsString(cfg.emailSubject.trim());
  // Optional message header (creator-set, UI-defaulted to the website name).
  // Newlines are collapsed so the header can't split the `#Title:` line, and
  // it's `</script>`-hardened/escaped like the other creator-controlled strings.
  final title =
      _jsString(cfg.title.trim().replaceAll(RegExp(r'[\r\n]+'), ' '));

  // Only the chosen channel's URL logic is emitted — smaller, and no dead
  // branch for the AI to "simplify" away.
  final String sendLogic;
  if (cfg.channel == ContactFormChannel.email) {
    // Strip anything from the first `?`/`#`/`&`/whitespace in the address so a
    // creator can't smuggle extra mailto headers (cc/bcc/subject).
    sendLogic = "    var subj=$subject||'New website enquiry';\n"
        "    var to=DEST.split(/[?#&\\s]/)[0];\n"
        "    var url='mailto:'+to+'?subject='+encodeURIComponent(subj)"
        "+'&body='+encodeURIComponent(body);";
  } else {
    // Digits only; drop a leading `00` international-access prefix — wa.me wants
    // country code + number (e.g. 4479…), never 004479….
    sendLogic = "    var d=DEST.replace(/\\D/g,'');\n"
        "    if(d.slice(0,2)==='00')d=d.slice(2);\n"
        "    if(d.length<7||d.length>15){"
        "alert('This site has an invalid contact number.');return;}\n"
        "    var url='https://wa.me/'+d+'?text='+encodeURIComponent(body);";
  }

  return '''
<form id="cf" class="cf-form" novalidate>
$rows  <button type="submit" class="cf-send">Send</button>
</form>
<script>
(function(){
  var f=document.getElementById('cf');
  if(!f)return;
  var DEST=$dest;
  var TITLE=$title;
  f.addEventListener('submit',function(e){
    e.preventDefault();
    var lines=[],ok=true,g=f.querySelectorAll('[data-label]');
    for(var i=0;i<g.length;i++){
      var el=g[i],lbl=el.getAttribute('data-label'),val='';
      if(el.getAttribute('data-multi')){
        var pk=[],bx=el.querySelectorAll('input[type=checkbox]:checked');
        for(var j=0;j<bx.length;j++){pk.push(bx[j].value);}
        val=pk.join(', ');
      }else{
        var inp=el.querySelector('input,textarea');
        val=inp?(''+inp.value).trim():'';
      }
      if(el.getAttribute('data-req')&&!val){ok=false;el.classList.add('cf-err');}
      else{el.classList.remove('cf-err');}
      if(val)lines.push(lbl+': '+val);
    }
    if(!ok){alert('Please fill in the required fields.');return;}
    if(!lines.length){alert('Please fill in the form before sending.');return;}
    if(TITLE)lines.unshift('#Title: '+TITLE);
    lines.push('#Ref: '+location.href);
    var body=lines.join('\\n');
$sendLogic
    window.location.href=url;
    setTimeout(function(){if(document.visibilityState==='visible'){var a=document.createElement('a');a.href=url;a.className='cf-fb';a.style.display='block';a.textContent='Tap here if nothing opened';f.appendChild(a);}},1500);
  });
})();
</script>''';
}

/// Markup for one field. Each carries `data-label` (used to build the
/// "Label: value" line) and `data-req` when required; multi-selects also carry
/// `data-multi`.
String _fieldMarkup(ContactFormField field, String label) {
  final req = field.required ? ' data-req="1"' : '';
  final star = field.required ? ' *' : '';
  final text = _escapeHtml(label);
  final attr = _escapeAttr(label);
  switch (field.type) {
    case ContactFormFieldType.multiline:
      return '  <label class="cf-row" data-label="$attr"$req>'
          '<span>$text$star</span>'
          '<textarea rows="4" maxlength="2000"></textarea></label>\n';
    case ContactFormFieldType.number:
      return '  <label class="cf-row" data-label="$attr"$req>'
          '<span>$text$star</span><input type="number"></label>\n';
    case ContactFormFieldType.email:
      return '  <label class="cf-row" data-label="$attr"$req>'
          '<span>$text$star</span>'
          '<input type="email" maxlength="200"></label>\n';
    case ContactFormFieldType.multiSelect:
      final opts = StringBuffer();
      for (final o in field.options) {
        final ov = o.trim();
        if (ov.isEmpty) continue;
        opts.write('<label class="cf-opt"><input type="checkbox" '
            'value="${_escapeAttr(ov)}">${_escapeHtml(ov)}</label>');
      }
      return '  <fieldset class="cf-row" data-label="$attr" data-multi="1"$req>'
          '<legend>$text$star</legend>$opts</fieldset>\n';
    case ContactFormFieldType.text:
      return '  <label class="cf-row" data-label="$attr"$req>'
          '<span>$text$star</span>'
          '<input type="text" maxlength="200"></label>\n';
  }
}

/// Emit [s] as a JS string literal that is safe inside a `<script>` block:
/// jsonEncode handles quotes/backslashes/control chars, and rewriting `</` to
/// `<\/` stops a creator-typed `</script>` from terminating the block early.
String _jsString(String s) => jsonEncode(s).replaceAll('</', r'<\/');

String _escapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
