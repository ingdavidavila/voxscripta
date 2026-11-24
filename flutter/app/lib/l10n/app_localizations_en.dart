// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get tryAgain => 'Try again';

  @override
  String get record => 'Record';

  @override
  String get openFile => 'Open a file';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get deleteEllipsis => 'Delete…';

  @override
  String get libraryTitle => 'Recordings';

  @override
  String get libraryRefreshTooltip => 'Look again for recordings on disk.';

  @override
  String get libraryOpenTooltip => 'Open an audio file you already have.';

  @override
  String get libraryRecordTooltip => 'Record something now.';

  @override
  String get librarySettingsTooltip =>
      'Silence detection, language, clean and polish.';

  @override
  String get libraryUnreadableTitle => 'The library could not be read';

  @override
  String get libraryEmptyTitle => 'No recordings yet';

  @override
  String libraryEmptyDetail(String directory) {
    return 'Record something, or open a file.\n\n$directory';
  }

  @override
  String projectCannotOpen(String name) {
    return '$name cannot be opened here.';
  }

  @override
  String couldNotOpenFileManager(String manager) {
    return 'Could not open $manager.';
  }

  @override
  String deleteProjectTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get deleteExplainTrash =>
      'The project moves to the Trash. Your original audio file is not touched.';

  @override
  String get deleteExplainFolder =>
      'The project moves to a Deleted folder beside the library. Your original audio file is not touched.';

  @override
  String deletedProject(String name) {
    return 'Deleted $name.';
  }

  @override
  String movedProjectTo(String name, String path) {
    return 'Moved $name to $path';
  }

  @override
  String projectTileTooltip(String name, String duration) {
    return '$name · $duration. Click to open its transcript.';
  }

  @override
  String showInFileManager(String manager) {
    return 'Show in $manager';
  }

  @override
  String get justNow => 'just now';

  @override
  String minutesAgo(int minutes) {
    return '$minutes min ago';
  }

  @override
  String hoursAgo(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String daysAgo(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get subscribe => 'Subscribe';

  @override
  String get seePlans => 'See plans';

  @override
  String get trialLastDay => 'Last day of your free trial.';

  @override
  String trialDaysLeft(int days) {
    return '$days days left in your free trial.';
  }

  @override
  String trialEnded(int days) {
    return 'Your $days-day trial has ended. Everything already transcribed stays yours.';
  }

  @override
  String get subscriptionLapsed =>
      'Your subscription has lapsed. Everything already transcribed stays yours.';
}
