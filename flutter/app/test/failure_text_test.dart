import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/l10n/app_localizations.dart';
import 'package:voxscripta/src/failure_text.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The engine reports a code and its values; the sentence is written here.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  EngineFailure failure(String code,
          [Map<String, String> details = const {}, String message = 'engine words']) =>
      EngineFailure(code: code, message: message, details: details);

  test('a known code is worded in the reader\'s language', () {
    final f = failure('sourceChanged', {'path': '/a.wav'});
    expect(failureText(en, f, fallback: 'x'),
        'The audio file at /a.wav has changed since it was imported.');
    expect(failureText(es, f, fallback: 'x'),
        'El archivo de audio en /a.wav ha cambiado desde que se importó.');
  });

  test('an unknown code shows the engine\'s own sentence, not nothing', () {
    expect(failureText(es, failure('brandNewCase', {}, 'something new'), fallback: 'x'),
        'something new');
    expect(failureText(es, failure('brandNewCase', {}, ''), fallback: 'fallback'),
        'fallback');
  });

  test('no structured failure falls back to the plain message', () {
    expect(failureText(es, null, fallback: 'plain'), 'plain');
  });

  test('invalidArgument is never made friendly', () {
    expect(failureText(es, failure('invalidArgument', {}, 'null path'), fallback: 'x'),
        'null path');
  });

  test('numbers are formatted by the reader\'s locale, not the engine\'s', () {
    final f = failure('contextWindowExceeded', {'tokens': '9000', 'limit': '4096'});
    expect(failureText(en, f, fallback: 'x'),
        'Input of 9,000 tokens exceeds the 4,096-token limit.');
    expect(failureText(es, f, fallback: 'x'),
        contains('9.000'));
  });

  test('a code whose numbers did not arrive as numbers falls back', () {
    final f = failure('schemaTooNew', {'found': 'many'}, 'engine words');
    expect(failureText(en, f, fallback: 'x'), 'engine words');
  });

  test('disk space is shown as sizes', () {
    final f = failure('insufficientDiskSpace',
        {'needed': '1400000000', 'available': '480000000'});
    expect(failureText(en, f, fallback: 'x'),
        'Needs 1.4 GB of free space; 480 MB available.');
  });

  test('a file name is taken from the path', () {
    expect(
        failureText(en, failure('noAudioTrack', {'path': '/home/me/clip.mp4'}),
            fallback: 'x'),
        startsWith('“clip.mp4” has no audio track'));
  });

  test('formatBytes', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1500), '1.5 KB');
    expect(formatBytes(250000000), '250 MB');
  });

  test('password rules follow the language and carry the engine\'s number', () {
    const length = PasswordRule(
        id: 'length',
        demand: 'engine words',
        satisfied: false,
        details: {'minimum': '8'});
    expect(passwordRuleText(en, length), 'At least 8 characters');
    expect(passwordRuleText(es, length), 'Al menos 8 caracteres');
    // The minimum is the engine's, so a change there changes the text here.
    expect(
        passwordRuleText(
            en,
            const PasswordRule(
                id: 'length',
                demand: 'x',
                satisfied: false,
                details: {'minimum': '12'})),
        'At least 12 characters');
    expect(
        passwordRuleText(
            es,
            const PasswordRule(id: 'uppercase', demand: 'x', satisfied: true)),
        'Una letra mayúscula');
    // An id this build has no wording for shows the engine's own.
    expect(
        passwordRuleText(
            es, const PasswordRule(id: 'emoji', demand: 'One emoji', satisfied: false)),
        'One emoji');
    // The length rule without its number cannot be worded, so it falls back.
    expect(
        passwordRuleText(
            es, const PasswordRule(id: 'length', demand: 'At least 8 characters', satisfied: false)),
        'At least 8 characters');
  });

  test('every error code the engine can send has wording', () {
    // The codes are the engine's wire contract (ErrorCode.swift). One missing
    // here would silently fall back to English in a Spanish interface.
    final source = File('../../Sources/VoxScriptaCore/Diagnostics/ErrorCode.swift');
    if (!source.existsSync()) return;
    final codes = RegExp(r': "(\w+)"$', multiLine: true)
        .allMatches(source.readAsStringSync().split('var details').first)
        .map((m) => m.group(1)!)
        .toSet();
    // Deliberately not worded: a refused argument is a bug, not a message, and
    // these two carry the engine's own sentence as their whole content.
    const unworded = {'notEntitled', 'notImplemented'};
    const details = {
      'sourceUnavailable': {'path': '/a'},
      'sourceChanged': {'path': '/a'},
      'unsupportedFormat': {'description': 'd'},
      'noAudioTrack': {'path': '/a.mp4'},
      'unsupportedContainer': {'fileExtension': 'x'},
      'decodingFailed': {'reason': 'r'},
      'noWordsRecognized': {'locale': 'en'},
      'recordingFailed': {'reason': 'r'},
      'analysisFailed': {'stage': 's', 'reason': 'r'},
      'engineUnavailable': {'engine': 'e', 'reason': 'r'},
      'localeUnsupported': {'engine': 'e', 'locale': 'l'},
      'transcriptionFailed': {'chunk': 'c', 'reason': 'r'},
      'modelAssetMissing': {'description': 'd'},
      'modelUnavailable': {'model': 'm', 'reason': 'r'},
      'contextWindowExceeded': {'tokens': '1', 'limit': '2'},
      'validationRejected': {'reasons': 'a; b'},
      'projectCorrupt': {'reason': 'r'},
      'schemaTooNew': {'found': '2', 'supported': '1'},
      'insufficientDiskSpace': {'needed': '10', 'available': '5'},
      'ioFailure': {'path': '/a', 'reason': 'r'},
    };
    expect(codes, isNotEmpty);
    for (final code in codes.difference(unworded)) {
      final f = failure(code, details[code] ?? const {}, 'ENGINE SENTENCE');
      expect(failureText(en, f, fallback: 'x'), isNot('ENGINE SENTENCE'),
          reason: '$code has no English wording');
      expect(failureText(es, f, fallback: 'x'), isNot('ENGINE SENTENCE'),
          reason: '$code has no Spanish wording');
    }
  });

  test('the engine failure parses the wire shape', () {
    final parsed = EngineFailure.parse(jsonEncode({
      'code': 'sourceChanged',
      'details': {'path': '/a.wav'},
      'message': 'm',
    }));
    expect(parsed!.code, 'sourceChanged');
    expect(parsed.details['path'], '/a.wav');
  });
}
