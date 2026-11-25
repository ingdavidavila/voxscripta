import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

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

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

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

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @finish.
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get finish;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @or.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get or;

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

  /// No description provided for @paywallPrivacyPromise.
  ///
  /// In en, this message translates to:
  /// **'Vox Scripta transcribes on this machine. Nothing is uploaded, nothing is sent to a service, and none of that changes with a subscription — what it pays for is the work of making it.'**
  String get paywallPrivacyPromise;

  /// No description provided for @noPlans.
  ///
  /// In en, this message translates to:
  /// **'No plans came back from the store.'**
  String get noPlans;

  /// No description provided for @paywallHeadlineTrialing.
  ///
  /// In en, this message translates to:
  /// **'Keep going after your trial'**
  String get paywallHeadlineTrialing;

  /// No description provided for @paywallHeadlineExpired.
  ///
  /// In en, this message translates to:
  /// **'Your {days}-day trial has ended'**
  String paywallHeadlineExpired(int days);

  /// No description provided for @paywallHeadlineLapsed.
  ///
  /// In en, this message translates to:
  /// **'Your subscription has lapsed'**
  String get paywallHeadlineLapsed;

  /// No description provided for @paywallHeadlineSubscribed.
  ///
  /// In en, this message translates to:
  /// **'You are subscribed'**
  String get paywallHeadlineSubscribed;

  /// No description provided for @staysYoursTitle.
  ///
  /// In en, this message translates to:
  /// **'What stays yours either way'**
  String get staysYoursTitle;

  /// No description provided for @staysYoursRecordings.
  ///
  /// In en, this message translates to:
  /// **'Every recording you imported — untouched, where you put it.'**
  String get staysYoursRecordings;

  /// No description provided for @staysYoursTranscripts.
  ///
  /// In en, this message translates to:
  /// **'Every transcript already made — readable, copyable, exportable.'**
  String get staysYoursTranscripts;

  /// No description provided for @staysYoursExports.
  ///
  /// In en, this message translates to:
  /// **'Every export format: txt, md, docx, srt, vtt.'**
  String get staysYoursExports;

  /// No description provided for @staysYoursFolder.
  ///
  /// In en, this message translates to:
  /// **'Your projects folder, on your own disk.'**
  String get staysYoursFolder;

  /// No description provided for @subscriptionUnlocks.
  ///
  /// In en, this message translates to:
  /// **'A subscription unlocks new transcriptions and recording.'**
  String get subscriptionUnlocks;

  /// No description provided for @subscriptionDisclosure.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions renew automatically at the price shown until cancelled. Cancel any time; the subscription runs to the end of the period already paid for.'**
  String get subscriptionDisclosure;

  /// No description provided for @termsOfUse.
  ///
  /// In en, this message translates to:
  /// **'Terms of Use'**
  String get termsOfUse;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @manageSubscription.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription'**
  String get manageSubscription;

  /// No description provided for @noStoreTitle.
  ///
  /// In en, this message translates to:
  /// **'No store is connected in this build'**
  String get noStoreTitle;

  /// No description provided for @noStoreBody.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions are sold through the App Store on Apple devices and Google Play on Android, and neither is wired up yet, so there is nothing to buy here. This build cannot start new transcriptions once the trial ends.'**
  String get noStoreBody;

  /// No description provided for @importTitle.
  ///
  /// In en, this message translates to:
  /// **'Open audio'**
  String get importTitle;

  /// No description provided for @importChooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose a file…'**
  String get importChooseFile;

  /// No description provided for @importOrTypePath.
  ///
  /// In en, this message translates to:
  /// **'or type a path'**
  String get importOrTypePath;

  /// No description provided for @importStaysPut.
  ///
  /// In en, this message translates to:
  /// **'The file stays where it is. Vox Scripta reads it and never modifies it.'**
  String get importStaysPut;

  /// No description provided for @importChooseOrType.
  ///
  /// In en, this message translates to:
  /// **'Choose a file, or type its path.'**
  String get importChooseOrType;

  /// No description provided for @importNoFile.
  ///
  /// In en, this message translates to:
  /// **'There is no file at that path.'**
  String get importNoFile;

  /// No description provided for @importUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Vox Scripta cannot read .{extension} files. It reads {formats} and more.'**
  String importUnsupported(String extension, String formats);

  /// No description provided for @recordingTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recordingTitle;

  /// No description provided for @recordingOpeningMic.
  ///
  /// In en, this message translates to:
  /// **'Opening the microphone…'**
  String get recordingOpeningMic;

  /// No description provided for @recordingRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording…'**
  String get recordingRecording;

  /// No description provided for @recordingPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get recordingPaused;

  /// No description provided for @audioNeverLeavesDevice.
  ///
  /// In en, this message translates to:
  /// **'Your audio never leaves this device'**
  String get audioNeverLeavesDevice;

  /// No description provided for @discardRecordingTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard this recording?'**
  String get discardRecordingTitle;

  /// No description provided for @discardRecordingBody.
  ///
  /// In en, this message translates to:
  /// **'The audio recorded so far will be deleted. This cannot be undone.'**
  String get discardRecordingBody;

  /// No description provided for @keepRecording.
  ///
  /// In en, this message translates to:
  /// **'Keep recording'**
  String get keepRecording;

  /// No description provided for @discardRecordingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete this recording without keeping it.'**
  String get discardRecordingTooltip;

  /// No description provided for @resumeRecordingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Carry on recording into the same file.'**
  String get resumeRecordingTooltip;

  /// No description provided for @pauseRecordingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop capturing without ending the recording.'**
  String get pauseRecordingTooltip;

  /// No description provided for @micCouldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'The microphone could not be opened'**
  String get micCouldNotOpen;

  /// No description provided for @writingStopped.
  ///
  /// In en, this message translates to:
  /// **'Writing stopped'**
  String get writingStopped;

  /// No description provided for @writingStoppedDetail.
  ///
  /// In en, this message translates to:
  /// **'{message}\n\nWhat was recorded before this is still on disk.'**
  String writingStoppedDetail(String message);

  /// No description provided for @silentInputTitle.
  ///
  /// In en, this message translates to:
  /// **'No sound is reaching the microphone'**
  String get silentInputTitle;

  /// No description provided for @silentInputBody.
  ///
  /// In en, this message translates to:
  /// **'Recording is still running and will be kept. Check that the right input is selected and that it is not muted.'**
  String get silentInputBody;

  /// No description provided for @micAccessBlocked.
  ///
  /// In en, this message translates to:
  /// **'Microphone access is off. Vox Scripta does not have permission to use the microphone. Turn it on in Settings, under Apps, Vox Scripta, Permissions, then try recording again.'**
  String get micAccessBlocked;

  /// No description provided for @micAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access was not granted, so nothing was recorded. Go back and try again, and allow the microphone when asked.'**
  String get micAccessDenied;

  /// No description provided for @jobCouldNotStart.
  ///
  /// In en, this message translates to:
  /// **'This job could not start'**
  String get jobCouldNotStart;

  /// No description provided for @jobStopped.
  ///
  /// In en, this message translates to:
  /// **'This job stopped'**
  String get jobStopped;

  /// No description provided for @jobStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get jobStarting;

  /// No description provided for @speechSummary.
  ///
  /// In en, this message translates to:
  /// **'{regions} speech regions · {percent}% of the recording is speech'**
  String speechSummary(int regions, int percent);

  /// No description provided for @durationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} minutes'**
  String durationMinutes(int minutes);

  /// No description provided for @durationHours.
  ///
  /// In en, this message translates to:
  /// **'{hours} hours'**
  String durationHours(String hours);

  /// No description provided for @polishNotice.
  ///
  /// In en, this message translates to:
  /// **'Polishing will take about {duration} — it makes one request to the language model for every sentence. Transcription finishes long before that, and you can read it while polishing continues.'**
  String polishNotice(String duration);

  /// No description provided for @readingAudio.
  ///
  /// In en, this message translates to:
  /// **'Reading audio…'**
  String get readingAudio;

  /// No description provided for @modelPreparingTitle.
  ///
  /// In en, this message translates to:
  /// **'Preparing the speech model'**
  String get modelPreparingTitle;

  /// No description provided for @modelNoSpace.
  ///
  /// In en, this message translates to:
  /// **'There is not enough free space to prepare the speech model. About {megabytes} MB is needed on this device.'**
  String modelNoSpace(int megabytes);

  /// No description provided for @modelNotInPlace.
  ///
  /// In en, this message translates to:
  /// **'The speech model could not be put in place.'**
  String get modelNotInPlace;

  /// No description provided for @modelCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'The speech model could not be prepared: {detail}'**
  String modelCopyFailed(String detail);

  /// No description provided for @modelPreparingBody.
  ///
  /// In en, this message translates to:
  /// **'This happens once, the first time, and uses no network. Transcription starts when it finishes.'**
  String get modelPreparingBody;

  /// No description provided for @phaseAnalyze.
  ///
  /// In en, this message translates to:
  /// **'Analyze audio'**
  String get phaseAnalyze;

  /// No description provided for @phaseSilence.
  ///
  /// In en, this message translates to:
  /// **'Detect silence'**
  String get phaseSilence;

  /// No description provided for @phasePlan.
  ///
  /// In en, this message translates to:
  /// **'Plan segments'**
  String get phasePlan;

  /// No description provided for @phaseTranscribe.
  ///
  /// In en, this message translates to:
  /// **'Transcribe'**
  String get phaseTranscribe;

  /// No description provided for @phaseAssemble.
  ///
  /// In en, this message translates to:
  /// **'Assemble transcript'**
  String get phaseAssemble;

  /// No description provided for @phaseClean.
  ///
  /// In en, this message translates to:
  /// **'Clean'**
  String get phaseClean;

  /// No description provided for @phasePolish.
  ///
  /// In en, this message translates to:
  /// **'Polish'**
  String get phasePolish;

  /// No description provided for @variantVerbatim.
  ///
  /// In en, this message translates to:
  /// **'Verbatim'**
  String get variantVerbatim;

  /// No description provided for @variantClean.
  ///
  /// In en, this message translates to:
  /// **'Clean'**
  String get variantClean;

  /// No description provided for @variantPolished.
  ///
  /// In en, this message translates to:
  /// **'Polished'**
  String get variantPolished;

  /// No description provided for @variantVerbatimExplained.
  ///
  /// In en, this message translates to:
  /// **'Exactly what was said, including hesitations.'**
  String get variantVerbatimExplained;

  /// No description provided for @variantCleanExplained.
  ///
  /// In en, this message translates to:
  /// **'Tidied by fixed rules. No language model was involved.'**
  String get variantCleanExplained;

  /// No description provided for @variantPolishedExplained.
  ///
  /// In en, this message translates to:
  /// **'Rewritten for readability, checked against the original.'**
  String get variantPolishedExplained;

  /// No description provided for @formatPlainText.
  ///
  /// In en, this message translates to:
  /// **'Plain Text (.txt)'**
  String get formatPlainText;

  /// No description provided for @formatMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Markdown (.md)'**
  String get formatMarkdown;

  /// No description provided for @formatWord.
  ///
  /// In en, this message translates to:
  /// **'Word (.docx)'**
  String get formatWord;

  /// No description provided for @formatSubRip.
  ///
  /// In en, this message translates to:
  /// **'Subtitles (.srt)'**
  String get formatSubRip;

  /// No description provided for @formatWebVTT.
  ///
  /// In en, this message translates to:
  /// **'Web Captions (.vtt)'**
  String get formatWebVTT;

  /// No description provided for @formatPlainTextExplained.
  ///
  /// In en, this message translates to:
  /// **'Just the words, in a file any editor can open.'**
  String get formatPlainTextExplained;

  /// No description provided for @formatMarkdownExplained.
  ///
  /// In en, this message translates to:
  /// **'Words with light formatting, for notes and documentation.'**
  String get formatMarkdownExplained;

  /// No description provided for @formatWordExplained.
  ///
  /// In en, this message translates to:
  /// **'A Word document, for sharing and further editing.'**
  String get formatWordExplained;

  /// No description provided for @formatSubRipExplained.
  ///
  /// In en, this message translates to:
  /// **'Timed subtitles, the format most video editors expect.'**
  String get formatSubRipExplained;

  /// No description provided for @formatWebVTTExplained.
  ///
  /// In en, this message translates to:
  /// **'Timed captions for the web.'**
  String get formatWebVTTExplained;

  /// No description provided for @dispositionAccepted.
  ///
  /// In en, this message translates to:
  /// **'Accepted'**
  String get dispositionAccepted;

  /// No description provided for @dispositionAcceptedAfterRetry.
  ///
  /// In en, this message translates to:
  /// **'Accepted after a retry'**
  String get dispositionAcceptedAfterRetry;

  /// No description provided for @dispositionFellBackToClean.
  ///
  /// In en, this message translates to:
  /// **'Kept the clean text'**
  String get dispositionFellBackToClean;

  /// No description provided for @dispositionModelFailed.
  ///
  /// In en, this message translates to:
  /// **'Model failed — kept the clean text'**
  String get dispositionModelFailed;

  /// No description provided for @dispositionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get dispositionUnknown;

  /// No description provided for @reviewToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show what polish changed, and what it refused.'**
  String get reviewToggleTooltip;

  /// No description provided for @nothingToCopy.
  ///
  /// In en, this message translates to:
  /// **'Nothing to copy yet.'**
  String get nothingToCopy;

  /// No description provided for @copyTranscriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy the whole {variant} transcript to the clipboard.'**
  String copyTranscriptTooltip(String variant);

  /// No description provided for @projectUnreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'This project could not be read'**
  String get projectUnreadableTitle;

  /// No description provided for @noTranscriptTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing transcribed yet'**
  String get noTranscriptTitle;

  /// No description provided for @noTranscriptDetail.
  ///
  /// In en, this message translates to:
  /// **'This project has no finished transcript.'**
  String get noTranscriptDetail;

  /// No description provided for @transcribeIt.
  ///
  /// In en, this message translates to:
  /// **'Transcribe it'**
  String get transcribeIt;

  /// No description provided for @copiedTranscript.
  ///
  /// In en, this message translates to:
  /// **'Copied the {variant} transcript.'**
  String copiedTranscript(String variant);

  /// No description provided for @transcriptUnreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'That transcript could not be read'**
  String get transcriptUnreadableTitle;

  /// No description provided for @includeTimestamps.
  ///
  /// In en, this message translates to:
  /// **'Include timestamps'**
  String get includeTimestamps;

  /// No description provided for @saveTranscriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'Save this transcript. Formats and timestamps are in the menu.'**
  String get saveTranscriptTooltip;

  /// No description provided for @saveDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Save transcript'**
  String get saveDialogTitle;

  /// No description provided for @savedTo.
  ///
  /// In en, this message translates to:
  /// **'Saved to {where}'**
  String savedTo(String where);

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the file: {reason}'**
  String saveFailed(String reason);

  /// No description provided for @nothingToSave.
  ///
  /// In en, this message translates to:
  /// **'Nothing to save yet.'**
  String get nothingToSave;

  /// No description provided for @wordsAndSegments.
  ///
  /// In en, this message translates to:
  /// **'{words} words · {segments} segments'**
  String wordsAndSegments(int words, int segments);

  /// No description provided for @polishDidNotRun.
  ///
  /// In en, this message translates to:
  /// **'Polish did not run'**
  String get polishDidNotRun;

  /// No description provided for @noReasonRecorded.
  ///
  /// In en, this message translates to:
  /// **'No reason was recorded.'**
  String get noReasonRecorded;

  /// No description provided for @polishReview.
  ///
  /// In en, this message translates to:
  /// **'Polish review'**
  String get polishReview;

  /// No description provided for @everySentencePassed.
  ///
  /// In en, this message translates to:
  /// **'Every sentence passed.'**
  String get everySentencePassed;

  /// No description provided for @reviewModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get reviewModelLabel;

  /// No description provided for @engineUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'The engine could not be loaded'**
  String get engineUnavailableTitle;

  /// No description provided for @noReasonReported.
  ///
  /// In en, this message translates to:
  /// **'No reason was reported.'**
  String get noReasonReported;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @resetToDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetToDefaults;

  /// No description provided for @sectionSilence.
  ///
  /// In en, this message translates to:
  /// **'Silence detection'**
  String get sectionSilence;

  /// No description provided for @silenceThreshold.
  ///
  /// In en, this message translates to:
  /// **'Threshold above noise'**
  String get silenceThreshold;

  /// No description provided for @silenceThresholdHelp.
  ///
  /// In en, this message translates to:
  /// **'How far above the measured background noise a sound must be to count as speech. Raise it for a noisy recording.'**
  String get silenceThresholdHelp;

  /// No description provided for @shortestPause.
  ///
  /// In en, this message translates to:
  /// **'Shortest pause'**
  String get shortestPause;

  /// No description provided for @shortestPauseHelp.
  ///
  /// In en, this message translates to:
  /// **'A quiet stretch shorter than this is treated as part of the speech, not as a pause.'**
  String get shortestPauseHelp;

  /// No description provided for @paddingAfterSpeech.
  ///
  /// In en, this message translates to:
  /// **'Padding after speech'**
  String get paddingAfterSpeech;

  /// No description provided for @paddingAfterSpeechHelp.
  ///
  /// In en, this message translates to:
  /// **'Silence kept after each phrase, so word endings are not clipped when silence is removed.'**
  String get paddingAfterSpeechHelp;

  /// No description provided for @sectionSegmentation.
  ///
  /// In en, this message translates to:
  /// **'Segmentation'**
  String get sectionSegmentation;

  /// No description provided for @segmentationFooter.
  ///
  /// In en, this message translates to:
  /// **'Segments are internal. They set how often work is saved, not how the transcript reads.'**
  String get segmentationFooter;

  /// No description provided for @maxSegmentLength.
  ///
  /// In en, this message translates to:
  /// **'Maximum segment length'**
  String get maxSegmentLength;

  /// No description provided for @maxSegmentLengthHelp.
  ///
  /// In en, this message translates to:
  /// **'The longest stretch of audio transcribed as one unit. Shorter segments save progress more often.'**
  String get maxSegmentLengthHelp;

  /// No description provided for @sectionTranscription.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get sectionTranscription;

  /// No description provided for @transcriptionFooter.
  ///
  /// In en, this message translates to:
  /// **'More at once is faster up to a point, and costs memory. Four is measured rather than guessed.'**
  String get transcriptionFooter;

  /// No description provided for @detectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Detect language'**
  String get detectLanguage;

  /// No description provided for @detectLanguageHelp.
  ///
  /// In en, this message translates to:
  /// **'Tries the languages this machine can transcribe on a short sample and uses whichever the engine recognises confidently. The setting below is the fallback. Nothing is downloaded.'**
  String get detectLanguageHelp;

  /// No description provided for @verbatimOnlyNotice.
  ///
  /// In en, this message translates to:
  /// **'Verbatim only in this language. Clean and Polished need lexicons Vox Scripta does not have yet.'**
  String get verbatimOnlyNotice;

  /// No description provided for @polishedUnavailableNotice.
  ///
  /// In en, this message translates to:
  /// **'Polished is unavailable in this language. The checks that catch a reversed meaning have not been proven here, so the pass is withheld rather than run unguarded.'**
  String get polishedUnavailableNotice;

  /// No description provided for @segmentsAtOnce.
  ///
  /// In en, this message translates to:
  /// **'Segments at once'**
  String get segmentsAtOnce;

  /// No description provided for @segmentsAtOnceHelp.
  ///
  /// In en, this message translates to:
  /// **'How many segments are transcribed concurrently.'**
  String get segmentsAtOnceHelp;

  /// No description provided for @cleanFooter.
  ///
  /// In en, this message translates to:
  /// **'Clean uses fixed rules only. No language model is involved, and every edit is recorded.'**
  String get cleanFooter;

  /// No description provided for @removeFillers.
  ///
  /// In en, this message translates to:
  /// **'Remove fillers'**
  String get removeFillers;

  /// No description provided for @removeFillersHelp.
  ///
  /// In en, this message translates to:
  /// **'Drops “um”, “uh” and the like.'**
  String get removeFillersHelp;

  /// No description provided for @collapseStutters.
  ///
  /// In en, this message translates to:
  /// **'Collapse stutters'**
  String get collapseStutters;

  /// No description provided for @collapseStuttersHelp.
  ///
  /// In en, this message translates to:
  /// **'Turns “the the the” into “the”.'**
  String get collapseStuttersHelp;

  /// No description provided for @dropLowConfidence.
  ///
  /// In en, this message translates to:
  /// **'Drop low-confidence words'**
  String get dropLowConfidence;

  /// No description provided for @dropLowConfidenceHelp.
  ///
  /// In en, this message translates to:
  /// **'Removes words the recogniser was unsure of.'**
  String get dropLowConfidenceHelp;

  /// No description provided for @sectionStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage and privacy'**
  String get sectionStorage;

  /// No description provided for @privacyFooter.
  ///
  /// In en, this message translates to:
  /// **'Transcription runs entirely on this machine. No recording and no transcript is ever uploaded, and there is no telemetry.'**
  String get privacyFooter;

  /// No description provided for @privacyFooterWithAccount.
  ///
  /// In en, this message translates to:
  /// **'Transcription runs entirely on this machine. No recording and no transcript is ever uploaded, and there is no telemetry. An account is optional and carries only your email address, for signing in.'**
  String get privacyFooterWithAccount;

  /// No description provided for @keepWorkingFiles.
  ///
  /// In en, this message translates to:
  /// **'Keep working files'**
  String get keepWorkingFiles;

  /// No description provided for @keepWorkingFilesHelp.
  ///
  /// In en, this message translates to:
  /// **'Keeps the scratch audio after a job finishes. It is about 1.4 GB for a six-hour recording, and the transcripts do not need it.'**
  String get keepWorkingFilesHelp;

  /// No description provided for @projectsFolder.
  ///
  /// In en, this message translates to:
  /// **'Projects folder'**
  String get projectsFolder;

  /// No description provided for @polishFooter.
  ///
  /// In en, this message translates to:
  /// **'Polish rewrites sentence by sentence and checks each rewrite against the original. A rewrite that fails is discarded and the clean sentence stands.'**
  String get polishFooter;

  /// No description provided for @createPolished.
  ///
  /// In en, this message translates to:
  /// **'Create a polished transcript'**
  String get createPolished;

  /// No description provided for @polishRunsAfterClean.
  ///
  /// In en, this message translates to:
  /// **'Runs the model pass after Clean.'**
  String get polishRunsAfterClean;

  /// No description provided for @polishUnavailableInLanguage.
  ///
  /// In en, this message translates to:
  /// **'Unavailable in the selected language.'**
  String get polishUnavailableInLanguage;

  /// No description provided for @languageModel.
  ///
  /// In en, this message translates to:
  /// **'Language model'**
  String get languageModel;

  /// No description provided for @languageModelHelp.
  ///
  /// In en, this message translates to:
  /// **'Which model to prefer. A named model that is unavailable is refused rather than quietly swapped for another.'**
  String get languageModelHelp;

  /// No description provided for @backendAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Best available'**
  String get backendAutomatic;

  /// No description provided for @backendSystem.
  ///
  /// In en, this message translates to:
  /// **'Apple Intelligence'**
  String get backendSystem;

  /// No description provided for @backendBundled.
  ///
  /// In en, this message translates to:
  /// **'Bundled model'**
  String get backendBundled;

  /// No description provided for @willUse.
  ///
  /// In en, this message translates to:
  /// **'Will use'**
  String get willUse;

  /// No description provided for @polishWillBeSkipped.
  ///
  /// In en, this message translates to:
  /// **'unavailable — polish will be skipped'**
  String get polishWillBeSkipped;

  /// No description provided for @available.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get available;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @notIncluded.
  ///
  /// In en, this message translates to:
  /// **'Not included'**
  String get notIncluded;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageHelp.
  ///
  /// In en, this message translates to:
  /// **'The language spoken in the recording. Getting this wrong costs accuracy more than any other setting.'**
  String get settingsLanguageHelp;

  /// No description provided for @noLanguagesReported.
  ///
  /// In en, this message translates to:
  /// **'No transcription languages were reported.'**
  String get noLanguagesReported;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as'**
  String get signedInAs;

  /// No description provided for @signedInWith.
  ///
  /// In en, this message translates to:
  /// **'Signed in with'**
  String get signedInWith;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @signOutNote.
  ///
  /// In en, this message translates to:
  /// **'Your recordings and transcripts stay on this machine.'**
  String get signOutNote;

  /// No description provided for @deleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccount;

  /// No description provided for @deleteAccountNote.
  ///
  /// In en, this message translates to:
  /// **'Removes the account and everything the account service holds for it. Your local projects are not touched.'**
  String get deleteAccountNote;

  /// No description provided for @providerPassword.
  ///
  /// In en, this message translates to:
  /// **'An email address and password'**
  String get providerPassword;

  /// No description provided for @deleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this account?'**
  String get deleteAccountTitle;

  /// No description provided for @deleteAccountBody.
  ///
  /// In en, this message translates to:
  /// **'The account and everything the account service holds for it are removed. This cannot be undone.\n\nRecordings, projects and transcripts on this machine are not deleted — they were never on the account.'**
  String get deleteAccountBody;

  /// No description provided for @keepIt.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get keepIt;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No description provided for @welcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get welcomeBack;

  /// No description provided for @accountIsOptionalNote.
  ///
  /// In en, this message translates to:
  /// **'Your recordings stay on this device either way. An account is only for settings that follow you.'**
  String get accountIsOptionalNote;

  /// No description provided for @emailField.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailField;

  /// No description provided for @passwordField.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordField;

  /// No description provided for @forgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPassword;

  /// No description provided for @noAccountYet.
  ///
  /// In en, this message translates to:
  /// **'No account yet?'**
  String get noAccountYet;

  /// No description provided for @createOne.
  ///
  /// In en, this message translates to:
  /// **'Create one'**
  String get createOne;

  /// No description provided for @enterYourEmail.
  ///
  /// In en, this message translates to:
  /// **'Enter your email.'**
  String get enterYourEmail;

  /// No description provided for @enterYourPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter your password.'**
  String get enterYourPassword;

  /// No description provided for @createAnAccount.
  ///
  /// In en, this message translates to:
  /// **'Create an account'**
  String get createAnAccount;

  /// No description provided for @orSignUpWithEmail.
  ///
  /// In en, this message translates to:
  /// **'or sign up with email'**
  String get orSignUpWithEmail;

  /// No description provided for @emailHelper.
  ///
  /// In en, this message translates to:
  /// **'Used to sign in and to reset your password.'**
  String get emailHelper;

  /// No description provided for @confirmPasswordField.
  ///
  /// In en, this message translates to:
  /// **'Password again'**
  String get confirmPasswordField;

  /// No description provided for @createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get createAccount;

  /// No description provided for @deleteAnytimeNote.
  ///
  /// In en, this message translates to:
  /// **'You can delete your account, and everything stored with it, from Settings at any time.'**
  String get deleteAnytimeNote;

  /// No description provided for @enterAnEmailAddress.
  ///
  /// In en, this message translates to:
  /// **'Enter an email address.'**
  String get enterAnEmailAddress;

  /// No description provided for @notAnEmailAddress.
  ///
  /// In en, this message translates to:
  /// **'That does not look like an email address.'**
  String get notAnEmailAddress;

  /// No description provided for @typePasswordAgain.
  ///
  /// In en, this message translates to:
  /// **'Type your password again.'**
  String get typePasswordAgain;

  /// No description provided for @passwordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'The two passwords do not match.'**
  String get passwordsDoNotMatch;

  /// No description provided for @passwordRequirementsUnmet.
  ///
  /// In en, this message translates to:
  /// **'Your password does not meet all the requirements yet.'**
  String get passwordRequirementsUnmet;

  /// No description provided for @resetYourPassword.
  ///
  /// In en, this message translates to:
  /// **'Reset your password'**
  String get resetYourPassword;

  /// No description provided for @resetPasswordIntro.
  ///
  /// In en, this message translates to:
  /// **'Enter the email you signed up with and we will send you a link to choose a new password.'**
  String get resetPasswordIntro;

  /// No description provided for @sendResetLink.
  ///
  /// In en, this message translates to:
  /// **'Send reset link'**
  String get sendResetLink;

  /// No description provided for @checkYourEmail.
  ///
  /// In en, this message translates to:
  /// **'Check your email'**
  String get checkYourEmail;

  /// No description provided for @resetLinkSent.
  ///
  /// In en, this message translates to:
  /// **'If {email} has an account, a reset link is on its way. It expires after a short while, so use it soon.'**
  String resetLinkSent(String email);

  /// No description provided for @backToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get backToSignIn;

  /// No description provided for @useDifferentEmail.
  ///
  /// In en, this message translates to:
  /// **'Use a different email'**
  String get useDifferentEmail;

  /// No description provided for @enterYourEmailAddress.
  ///
  /// In en, this message translates to:
  /// **'Enter your email address.'**
  String get enterYourEmailAddress;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @continueWithApple.
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get continueWithApple;

  /// No description provided for @continueWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get continueWithGoogle;

  /// No description provided for @signInOptionalNote.
  ///
  /// In en, this message translates to:
  /// **'Optional. Transcription works without one.'**
  String get signInOptionalNote;

  /// No description provided for @errSourceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The audio file could not be found at {path}.'**
  String errSourceUnavailable(String path);

  /// No description provided for @errSourceChanged.
  ///
  /// In en, this message translates to:
  /// **'The audio file at {path} has changed since it was imported.'**
  String errSourceChanged(String path);

  /// No description provided for @errUnsupportedFormat.
  ///
  /// In en, this message translates to:
  /// **'This audio format is not supported: {description}.'**
  String errUnsupportedFormat(String description);

  /// No description provided for @errNoAudioTrack.
  ///
  /// In en, this message translates to:
  /// **'“{name}” has no audio track, so there is nothing to transcribe.'**
  String errNoAudioTrack(String name);

  /// No description provided for @errUnsupportedContainer.
  ///
  /// In en, this message translates to:
  /// **'Vox Scripta cannot read .{extension} files. Convert it to .mp4, .m4a or .wav first — a stream copy is enough, and costs no quality.'**
  String errUnsupportedContainer(String extension);

  /// No description provided for @errDecodingFailed.
  ///
  /// In en, this message translates to:
  /// **'The audio could not be decoded: {reason}.'**
  String errDecodingFailed(String reason);

  /// No description provided for @errNoWordsRecognized.
  ///
  /// In en, this message translates to:
  /// **'No words were recognised. This recording was transcribed as {locale} — if it is in another language, change it in Settings and import the file again.'**
  String errNoWordsRecognized(String locale);

  /// No description provided for @errMicrophoneDenied.
  ///
  /// In en, this message translates to:
  /// **'Vox Scripta does not have permission to use the microphone. Grant it in Settings, then try recording again.'**
  String get errMicrophoneDenied;

  /// No description provided for @errRecordingFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be started: {reason}.'**
  String errRecordingFailed(String reason);

  /// No description provided for @errAnalysisFailed.
  ///
  /// In en, this message translates to:
  /// **'Audio analysis failed during {stage}: {reason}.'**
  String errAnalysisFailed(String stage, String reason);

  /// No description provided for @errNoSpeechDetected.
  ///
  /// In en, this message translates to:
  /// **'No speech was detected in this recording.'**
  String get errNoSpeechDetected;

  /// No description provided for @errEngineUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The {engine} engine is unavailable: {reason}.'**
  String errEngineUnavailable(String engine, String reason);

  /// No description provided for @errLocaleUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The {engine} engine does not support {locale}.'**
  String errLocaleUnsupported(String engine, String locale);

  /// No description provided for @errTranscriptionFailed.
  ///
  /// In en, this message translates to:
  /// **'Chunk {chunk} could not be transcribed: {reason}.'**
  String errTranscriptionFailed(String chunk, String reason);

  /// No description provided for @errModelAssetMissing.
  ///
  /// In en, this message translates to:
  /// **'A required model asset is missing: {description}.'**
  String errModelAssetMissing(String description);

  /// No description provided for @errModelUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The language model {model} is unavailable: {reason}.'**
  String errModelUnavailable(String model, String reason);

  /// No description provided for @errContextWindowExceeded.
  ///
  /// In en, this message translates to:
  /// **'Input of {tokens} tokens exceeds the {limit}-token limit.'**
  String errContextWindowExceeded(int tokens, int limit);

  /// No description provided for @errValidationRejected.
  ///
  /// In en, this message translates to:
  /// **'Polished output failed validation: {reasons}.'**
  String errValidationRejected(String reasons);

  /// No description provided for @errProjectCorrupt.
  ///
  /// In en, this message translates to:
  /// **'The project file is damaged: {reason}.'**
  String errProjectCorrupt(String reason);

  /// No description provided for @errSchemaTooNew.
  ///
  /// In en, this message translates to:
  /// **'This project was made by a newer version (schema {found}, this app supports {supported}).'**
  String errSchemaTooNew(int found, int supported);

  /// No description provided for @errInsufficientDiskSpace.
  ///
  /// In en, this message translates to:
  /// **'Needs {needed} of free space; {available} available.'**
  String errInsufficientDiskSpace(String needed, String available);

  /// No description provided for @errIoFailure.
  ///
  /// In en, this message translates to:
  /// **'Could not read or write {path}: {reason}.'**
  String errIoFailure(String path, String reason);

  /// No description provided for @errCancelled.
  ///
  /// In en, this message translates to:
  /// **'Processing was cancelled.'**
  String get errCancelled;

  /// No description provided for @passwordRuleLength.
  ///
  /// In en, this message translates to:
  /// **'At least {minimum} characters'**
  String passwordRuleLength(int minimum);

  /// No description provided for @passwordRuleUppercase.
  ///
  /// In en, this message translates to:
  /// **'One capital letter'**
  String get passwordRuleUppercase;

  /// No description provided for @passwordRuleNumber.
  ///
  /// In en, this message translates to:
  /// **'One number'**
  String get passwordRuleNumber;

  /// No description provided for @passwordRuleSpecial.
  ///
  /// In en, this message translates to:
  /// **'One symbol, such as ! ? # or &'**
  String get passwordRuleSpecial;
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
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
