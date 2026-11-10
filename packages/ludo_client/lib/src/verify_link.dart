import 'dart:ui' show Locale;

/// The verify page speaks the language it is asked for with `?lang=`, and the
/// app's own language choice can differ from the phone's. Every place the app
/// opens a verify URL runs it through here so the page matches what the player
/// is reading. Only `ar` and `en` are added; any other language leaves the URL
/// as the server sent it. Other query parameters are kept and an existing
/// `lang` is replaced.
Uri verifyUriFor(Uri base, Locale locale) {
  final String code = locale.languageCode;
  if (code != 'ar' && code != 'en') {
    return base;
  }
  final Map<String, dynamic> query = <String, dynamic>{
    ...base.queryParametersAll,
  };
  query['lang'] = code;
  return base.replace(queryParameters: query);
}
