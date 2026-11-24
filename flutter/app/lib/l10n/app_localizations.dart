import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// No description provided for @record.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get record;

  /// No description provided for @openFile.
  ///
  /// In en, this message translates to:
  /// **'Open a file'**
  String get openFile;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get deleteEllipsis;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recordings'**
  String get libraryTitle;

  /// No description provided for @libraryRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Look again for recordings on disk.'**
  String get libraryRefreshTooltip;

  /// No description provided for @libraryOpenTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open an audio file you already have.'**
  String get libraryOpenTooltip;

  /// No description provided for @libraryRecordTooltip.
  ///
  /// In en, this message translates to:
  /// **'Record something now.'**
  String get libraryRecordTooltip;

  /// No description provided for @librarySettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Silence detection, language, clean and polish.'**
  String get librarySettingsTooltip;

  /// No description provided for @libraryUnreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'The library could not be read'**
  String get libraryUnreadableTitle;

  /// No description provided for @libraryEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No recordings yet'**
  String get libraryEmptyTitle;

  /// No description provided for @libraryEmptyDetail.
  ///
  /// In en, this message translates to:
  /// **'Record something, or open a file.\n\n{directory}'**
  String libraryEmptyDetail(String directory);

  /// No description provided for @projectCannotOpen.
  ///
  /// In en, this message translates to:
  /// **'{name} cannot be opened here.'**
  String projectCannotOpen(String name);

  /// No description provided for @couldNotOpenFileManager.
  ///
  /// In en, this message translates to:
  /// **'Could not open {manager}.'**
  String couldNotOpenFileManager(String manager);

  /// No description provided for @deleteProjectTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String deleteProjectTitle(String name);

  /// No description provided for @deleteExplainTrash.
  ///
  /// In en, this message translates to:
  /// **'The project moves to the Trash. Your original audio file is not touched.'**
  String get deleteExplainTrash;

  /// No description provided for @deleteExplainFolder.
  ///
  /// In en, this message translates to:
  /// **'The project moves to a Deleted folder beside the library. Your original audio file is not touched.'**
  String get deleteExplainFolder;

  /// No description provided for @deletedProject.
  ///
  /// In en, this message translates to:
  /// **'Deleted {name}.'**
  String deletedProject(String name);

  /// No description provided for @movedProjectTo.
  ///
  /// In en, this message translates to:
  /// **'Moved {name} to {path}'**
  String movedProjectTo(String name, String path);

  /// No description provided for @projectTileTooltip.
  ///
  /// In en, this message translates to:
  /// **'{name} · {duration}. Click to open its transcript.'**
  String projectTileTooltip(String name, String duration);

  /// No description provided for @showInFileManager.
  ///
  /// In en, this message translates to:
  /// **'Show in {manager}'**
  String showInFileManager(String manager);

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min ago'**
  String minutesAgo(int minutes);

  /// No description provided for @hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{1 hour ago} other{{hours} hours ago}}'**
  String hoursAgo(int hours);

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{1 day ago} other{{days} days ago}}'**
  String daysAgo(int days);

  /// No description provided for @subscribe.
  ///
  /// In en, this message translates to:
  /// **'Subscribe'**
  String get subscribe;

  /// No description provided for @seePlans.
  ///
  /// In en, this message translates to:
  /// **'See plans'**
  String get seePlans;

  /// No description provided for @trialLastDay.
  ///
  /// In en, this message translates to:
  /// **'Last day of your free trial.'**
  String get trialLastDay;

  /// No description provided for @trialDaysLeft.
  ///
  /// In en, this message translates to:
  /// **'{days} days left in your free trial.'**
  String trialDaysLeft(int days);

  /// No description provided for @trialEnded.
  ///
  /// In en, this message translates to:
  /// **'Your {days}-day trial has ended. Everything already transcribed stays yours.'**
  String trialEnded(int days);

  /// No description provided for @subscriptionLapsed.
  ///
  /// In en, this message translates to:
  /// **'Your subscription has lapsed. Everything already transcribed stays yours.'**
  String get subscriptionLapsed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
