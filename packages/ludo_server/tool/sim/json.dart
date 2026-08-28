// Small, explicit accessors for pulling typed values out of a decoded JSON
// `d` payload. `jsonDecode` hands back `dynamic` everywhere; every one of
// these does the cast explicitly and names the field and the frame it came
// from in the failure, rather than letting a bad field surface as a bare
// Dart type error somewhere downstream.

import 'scenario.dart';

int requireInt(Map<String, Object?> d, String field, {required String frame}) {
  final Object? value = d[field];
  if (value is! int) {
    throw ScenarioFailure(
      '$frame frame: expected an integer field "$field", got $value',
    );
  }
  return value;
}

String requireString(
  Map<String, Object?> d,
  String field, {
  required String frame,
}) {
  final Object? value = d[field];
  if (value is! String) {
    throw ScenarioFailure(
      '$frame frame: expected a string field "$field", got $value',
    );
  }
  return value;
}

bool requireBool(
  Map<String, Object?> d,
  String field, {
  required String frame,
}) {
  final Object? value = d[field];
  if (value is! bool) {
    throw ScenarioFailure(
      '$frame frame: expected a boolean field "$field", got $value',
    );
  }
  return value;
}

List<int> requireIntList(
  Map<String, Object?> d,
  String field, {
  required String frame,
}) {
  final Object? value = d[field];
  if (value is! List<Object?>) {
    throw ScenarioFailure(
      '$frame frame: expected a list field "$field", got $value',
    );
  }
  return <int>[
    for (final Object? element in value)
      if (element is int)
        element
      else
        throw ScenarioFailure(
          '$frame frame: field "$field" has a non-integer element $element',
        ),
  ];
}

List<Map<String, Object?>> requireMapList(
  Map<String, Object?> d,
  String field, {
  required String frame,
}) {
  final Object? value = d[field];
  if (value is! List<Object?>) {
    throw ScenarioFailure(
      '$frame frame: expected a list field "$field", got $value',
    );
  }
  return <Map<String, Object?>>[
    for (final Object? element in value)
      if (element is Map<String, Object?>)
        element
      else
        throw ScenarioFailure(
          '$frame frame: field "$field" has a non-object element $element',
        ),
  ];
}
