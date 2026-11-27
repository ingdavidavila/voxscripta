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
  String get open => 'Open';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get deleteEllipsis => 'Delete…';

  @override
  String get discard => 'Discard';

  @override
  String get finish => 'Finish';

  @override
  String get stop => 'Stop';

  @override
  String get restore => 'Restore';

  @override
  String get or => 'or';

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

  @override
  String get paywallPrivacyPromise =>
      'Vox Scripta transcribes on this machine. Nothing is uploaded, nothing is sent to a service, and none of that changes with a subscription — what it pays for is the work of making it.';

  @override
  String get noPlans => 'No plans came back from the store.';

  @override
  String get paywallHeadlineTrialing => 'Keep going after your trial';

  @override
  String paywallHeadlineExpired(int days) {
    return 'Your $days-day trial has ended';
  }

  @override
  String get paywallHeadlineLapsed => 'Your subscription has lapsed';

  @override
  String get paywallHeadlineSubscribed => 'You are subscribed';

  @override
  String get staysYoursTitle => 'What stays yours either way';

  @override
  String get staysYoursRecordings =>
      'Every recording you imported — untouched, where you put it.';

  @override
  String get staysYoursTranscripts =>
      'Every transcript already made — readable, copyable, exportable.';

  @override
  String get staysYoursExports =>
      'Every export format: txt, md, docx, srt, vtt.';

  @override
  String get staysYoursFolder => 'Your projects folder, on your own disk.';

  @override
  String get subscriptionUnlocks =>
      'A subscription unlocks new transcriptions and recording.';

  @override
  String get subscriptionDisclosure =>
      'Subscriptions renew automatically at the price shown until cancelled. Cancel any time; the subscription runs to the end of the period already paid for.';

  @override
  String get termsOfUse => 'Terms of Use';

  @override
  String get privacyPolicy => 'Privacy Policy';

  @override
  String get manageSubscription => 'Manage subscription';

  @override
  String get noStoreTitle => 'No store is connected in this build';

  @override
  String get noStoreBody =>
      'Subscriptions are sold through the App Store on Apple devices and Google Play on Android, and neither is wired up yet, so there is nothing to buy here. This build cannot start new transcriptions once the trial ends.';

  @override
  String get importTitle => 'Open audio';

  @override
  String get importChooseFile => 'Choose a file…';

  @override
  String get importOrTypePath => 'or type a path';

  @override
  String get importStaysPut =>
      'The file stays where it is. Vox Scripta reads it and never modifies it.';

  @override
  String get importChooseOrType => 'Choose a file, or type its path.';

  @override
  String get importNoFile => 'There is no file at that path.';

  @override
  String importUnsupported(String extension, String formats) {
    return 'Vox Scripta cannot read .$extension files. It reads $formats and more.';
  }

  @override
  String get recordingTitle => 'Recording';

  @override
  String get recordingOpeningMic => 'Opening the microphone…';

  @override
  String get recordingRecording => 'Recording…';

  @override
  String get recordingPaused => 'Paused';

  @override
  String get audioNeverLeavesDevice => 'Your audio never leaves this device';

  @override
  String get discardRecordingTitle => 'Discard this recording?';

  @override
  String get discardRecordingBody =>
      'The audio recorded so far will be deleted. This cannot be undone.';

  @override
  String get keepRecording => 'Keep recording';

  @override
  String get discardRecordingTooltip =>
      'Delete this recording without keeping it.';

  @override
  String get resumeRecordingTooltip => 'Carry on recording into the same file.';

  @override
  String get pauseRecordingTooltip =>
      'Stop capturing without ending the recording.';

  @override
  String get micCouldNotOpen => 'The microphone could not be opened';

  @override
  String get writingStopped => 'Writing stopped';

  @override
  String writingStoppedDetail(String message) {
    return '$message\n\nWhat was recorded before this is still on disk.';
  }

  @override
  String get silentInputTitle => 'No sound is reaching the microphone';

  @override
  String get silentInputBody =>
      'Recording is still running and will be kept. Check that the right input is selected and that it is not muted.';

  @override
  String get micAccessBlocked =>
      'Microphone access is off. Vox Scripta does not have permission to use the microphone. Turn it on in Settings, under Apps, Vox Scripta, Permissions, then try recording again.';

  @override
  String get micAccessDenied =>
      'Microphone access was not granted, so nothing was recorded. Go back and try again, and allow the microphone when asked.';

  @override
  String get jobCouldNotStart => 'This job could not start';

  @override
  String get jobStopped => 'This job stopped';

  @override
  String get jobStarting => 'Starting…';

  @override
  String speechSummary(int regions, int percent) {
    return '$regions speech regions · $percent% of the recording is speech';
  }

  @override
  String durationMinutes(int minutes) {
    return '$minutes minutes';
  }

  @override
  String durationHours(String hours) {
    return '$hours hours';
  }

  @override
  String polishNotice(String duration) {
    return 'Polishing will take about $duration — it makes one request to the language model for every sentence. Transcription finishes long before that, and you can read it while polishing continues.';
  }

  @override
  String get readingAudio => 'Reading audio…';

  @override
  String get modelPreparingTitle => 'Preparing the speech model';

  @override
  String modelNoSpace(int megabytes) {
    return 'There is not enough free space to prepare the speech model. About $megabytes MB is needed on this device.';
  }

  @override
  String get modelNotInPlace => 'The speech model could not be put in place.';

  @override
  String modelCopyFailed(String detail) {
    return 'The speech model could not be prepared: $detail';
  }

  @override
  String get modelPreparingBody =>
      'This happens once, the first time, and uses no network. Transcription starts when it finishes.';

  @override
  String get phaseAnalyze => 'Analyze audio';

  @override
  String get phaseSilence => 'Detect silence';

  @override
  String get phasePlan => 'Plan segments';

  @override
  String get phaseTranscribe => 'Transcribe';

  @override
  String get phaseAssemble => 'Assemble transcript';

  @override
  String get phaseClean => 'Clean';

  @override
  String get phasePolish => 'Polish';

  @override
  String get variantVerbatim => 'Verbatim';

  @override
  String get variantClean => 'Clean';

  @override
  String get variantPolished => 'Polished';

  @override
  String get variantVerbatimExplained =>
      'Exactly what was said, including hesitations.';

  @override
  String get variantCleanExplained =>
      'Tidied by fixed rules. No language model was involved.';

  @override
  String get variantPolishedExplained =>
      'Rewritten for readability, checked against the original.';

  @override
  String get formatPlainText => 'Plain Text (.txt)';

  @override
  String get formatMarkdown => 'Markdown (.md)';

  @override
  String get formatWord => 'Word (.docx)';

  @override
  String get formatSubRip => 'Subtitles (.srt)';

  @override
  String get formatWebVTT => 'Web Captions (.vtt)';

  @override
  String get formatPlainTextExplained =>
      'Just the words, in a file any editor can open.';

  @override
  String get formatMarkdownExplained =>
      'Words with light formatting, for notes and documentation.';

  @override
  String get formatWordExplained =>
      'A Word document, for sharing and further editing.';

  @override
  String get formatSubRipExplained =>
      'Timed subtitles, the format most video editors expect.';

  @override
  String get formatWebVTTExplained => 'Timed captions for the web.';

  @override
  String get dispositionAccepted => 'Accepted';

  @override
  String get dispositionAcceptedAfterRetry => 'Accepted after a retry';

  @override
  String get dispositionFellBackToClean => 'Kept the clean text';

  @override
  String get dispositionModelFailed => 'Model failed — kept the clean text';

  @override
  String get dispositionUnknown => 'Unknown';

  @override
  String get reviewToggleTooltip =>
      'Show what polish changed, and what it refused.';

  @override
  String get nothingToCopy => 'Nothing to copy yet.';

  @override
  String copyTranscriptTooltip(String variant) {
    return 'Copy the whole $variant transcript to the clipboard.';
  }

  @override
  String get projectUnreadableTitle => 'This project could not be read';

  @override
  String get noTranscriptTitle => 'Nothing transcribed yet';

  @override
  String get noTranscriptDetail => 'This project has no finished transcript.';

  @override
  String get transcribeIt => 'Transcribe it';

  @override
  String copiedTranscript(String variant) {
    return 'Copied the $variant transcript.';
  }

  @override
  String get transcriptUnreadableTitle => 'That transcript could not be read';

  @override
  String get includeTimestamps => 'Include timestamps';

  @override
  String get saveTranscriptTooltip =>
      'Save this transcript. Formats and timestamps are in the menu.';

  @override
  String get saveDialogTitle => 'Save transcript';

  @override
  String savedTo(String where) {
    return 'Saved to $where';
  }

  @override
  String saveFailed(String reason) {
    return 'Could not save the file: $reason';
  }

  @override
  String get nothingToSave => 'Nothing to save yet.';

  @override
  String wordsAndSegments(int words, int segments) {
    return '$words words · $segments segments';
  }

  @override
  String get polishDidNotRun => 'Polish did not run';

  @override
  String get noReasonRecorded => 'No reason was recorded.';

  @override
  String get polishReview => 'Polish review';

  @override
  String get everySentencePassed => 'Every sentence passed.';

  @override
  String get reviewModelLabel => 'Model';

  @override
  String get engineUnavailableTitle => 'The engine could not be loaded';

  @override
  String get noReasonReported => 'No reason was reported.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get resetToDefaults => 'Reset to defaults';

  @override
  String get sectionSilence => 'Silence detection';

  @override
  String get silenceThreshold => 'Threshold above noise';

  @override
  String get silenceThresholdHelp =>
      'How far above the measured background noise a sound must be to count as speech. Raise it for a noisy recording.';

  @override
  String get shortestPause => 'Shortest pause';

  @override
  String get shortestPauseHelp =>
      'A quiet stretch shorter than this is treated as part of the speech, not as a pause.';

  @override
  String get paddingAfterSpeech => 'Padding after speech';

  @override
  String get paddingAfterSpeechHelp =>
      'Silence kept after each phrase, so word endings are not clipped when silence is removed.';

  @override
  String get sectionSegmentation => 'Segmentation';

  @override
  String get segmentationFooter =>
      'Segments are internal. They set how often work is saved, not how the transcript reads.';

  @override
  String get maxSegmentLength => 'Maximum segment length';

  @override
  String get maxSegmentLengthHelp =>
      'The longest stretch of audio transcribed as one unit. Shorter segments save progress more often.';

  @override
  String get sectionTranscription => 'Transcription';

  @override
  String get transcriptionFooter =>
      'More at once is faster up to a point, and costs memory. Four is measured rather than guessed.';

  @override
  String get detectLanguage => 'Detect language';

  @override
  String get detectLanguageHelp =>
      'Tries the languages this machine can transcribe on a short sample and uses whichever the engine recognises confidently. The setting below is the fallback. Nothing is downloaded.';

  @override
  String get verbatimOnlyNotice =>
      'Verbatim only in this language. Clean and Polished need lexicons Vox Scripta does not have yet.';

  @override
  String get polishedUnavailableNotice =>
      'Polished is unavailable in this language. The checks that catch a reversed meaning have not been proven here, so the pass is withheld rather than run unguarded.';

  @override
  String get segmentsAtOnce => 'Segments at once';

  @override
  String get segmentsAtOnceHelp =>
      'How many segments are transcribed concurrently.';

  @override
  String get cleanFooter =>
      'Clean uses fixed rules only. No language model is involved, and every edit is recorded.';

  @override
  String get removeFillers => 'Remove fillers';

  @override
  String get removeFillersHelp => 'Drops “um”, “uh” and the like.';

  @override
  String get collapseStutters => 'Collapse stutters';

  @override
  String get collapseStuttersHelp => 'Turns “the the the” into “the”.';

  @override
  String get dropLowConfidence => 'Drop low-confidence words';

  @override
  String get dropLowConfidenceHelp =>
      'Removes words the recogniser was unsure of.';

  @override
  String get sectionStorage => 'Storage and privacy';

  @override
  String get privacyFooter =>
      'Transcription runs entirely on this machine. No recording and no transcript is ever uploaded, and there is no telemetry.';

  @override
  String get privacyFooterWithAccount =>
      'Transcription runs entirely on this machine. No recording and no transcript is ever uploaded, and there is no telemetry. An account is optional and carries only your email address, for signing in.';

  @override
  String get keepWorkingFiles => 'Keep working files';

  @override
  String get keepWorkingFilesHelp =>
      'Keeps the scratch audio after a job finishes. It is about 1.4 GB for a six-hour recording, and the transcripts do not need it.';

  @override
  String get projectsFolder => 'Projects folder';

  @override
  String get polishFooter =>
      'Polish rewrites sentence by sentence and checks each rewrite against the original. A rewrite that fails is discarded and the clean sentence stands.';

  @override
  String get createPolished => 'Create a polished transcript';

  @override
  String get polishRunsAfterClean => 'Runs the model pass after Clean.';

  @override
  String get polishUnavailableInLanguage =>
      'Unavailable in the selected language.';

  @override
  String get languageModel => 'Language model';

  @override
  String get languageModelHelp =>
      'Which model to prefer. A named model that is unavailable is refused rather than quietly swapped for another.';

  @override
  String get backendAutomatic => 'Best available';

  @override
  String get backendSystem => 'Apple Intelligence';

  @override
  String get backendBundled => 'Bundled model';

  @override
  String get willUse => 'Will use';

  @override
  String get polishWillBeSkipped => 'unavailable — polish will be skipped';

  @override
  String get available => 'Available';

  @override
  String get unavailable => 'Unavailable';

  @override
  String get notIncluded => 'Not included';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageHelp =>
      'The language spoken in the recording. Getting this wrong costs accuracy more than any other setting.';

  @override
  String get noLanguagesReported => 'No transcription languages were reported.';

  @override
  String get account => 'Account';

  @override
  String get signedInAs => 'Signed in as';

  @override
  String get signedInWith => 'Signed in with';

  @override
  String get signOut => 'Sign out';

  @override
  String get signOutNote =>
      'Your recordings and transcripts stay on this machine.';

  @override
  String get deleteAccount => 'Delete account';

  @override
  String get deleteAccountNote =>
      'Removes the account and everything the account service holds for it. Your local projects are not touched.';

  @override
  String get providerPassword => 'An email address and password';

  @override
  String get deleteAccountTitle => 'Delete this account?';

  @override
  String get deleteAccountBody =>
      'The account and everything the account service holds for it are removed. This cannot be undone.\n\nRecordings, projects and transcripts on this machine are not deleted — they were never on the account.';

  @override
  String get keepIt => 'Keep it';

  @override
  String get signIn => 'Sign in';

  @override
  String get notNow => 'Not now';

  @override
  String get welcomeBack => 'Welcome back';

  @override
  String get accountIsOptionalNote =>
      'Your recordings stay on this device either way. An account is only for settings that follow you.';

  @override
  String get emailField => 'Email';

  @override
  String get passwordField => 'Password';

  @override
  String get forgotPassword => 'Forgot password?';

  @override
  String get noAccountYet => 'No account yet?';

  @override
  String get createOne => 'Create one';

  @override
  String get enterYourEmail => 'Enter your email.';

  @override
  String get enterYourPassword => 'Enter your password.';

  @override
  String get createAnAccount => 'Create an account';

  @override
  String get orSignUpWithEmail => 'or sign up with email';

  @override
  String get emailHelper => 'Used to sign in and to reset your password.';

  @override
  String get confirmPasswordField => 'Password again';

  @override
  String get createAccount => 'Create account';

  @override
  String get deleteAnytimeNote =>
      'You can delete your account, and everything stored with it, from Settings at any time.';

  @override
  String get enterAnEmailAddress => 'Enter an email address.';

  @override
  String get notAnEmailAddress => 'That does not look like an email address.';

  @override
  String get typePasswordAgain => 'Type your password again.';

  @override
  String get passwordsDoNotMatch => 'The two passwords do not match.';

  @override
  String get passwordRequirementsUnmet =>
      'Your password does not meet all the requirements yet.';

  @override
  String get resetYourPassword => 'Reset your password';

  @override
  String get resetPasswordIntro =>
      'Enter the email you signed up with and we will send you a link to choose a new password.';

  @override
  String get sendResetLink => 'Send reset link';

  @override
  String get checkYourEmail => 'Check your email';

  @override
  String resetLinkSent(String email) {
    return 'If $email has an account, a reset link is on its way. It expires after a short while, so use it soon.';
  }

  @override
  String get backToSignIn => 'Back to sign in';

  @override
  String get useDifferentEmail => 'Use a different email';

  @override
  String get enterYourEmailAddress => 'Enter your email address.';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get showPassword => 'Show password';

  @override
  String get continueWithApple => 'Continue with Apple';

  @override
  String get continueWithGoogle => 'Continue with Google';

  @override
  String get signInOptionalNote => 'Optional. Transcription works without one.';

  @override
  String errSourceUnavailable(String path) {
    return 'The audio file could not be found at $path.';
  }

  @override
  String errSourceChanged(String path) {
    return 'The audio file at $path has changed since it was imported.';
  }

  @override
  String errUnsupportedFormat(String description) {
    return 'This audio format is not supported: $description.';
  }

  @override
  String errNoAudioTrack(String name) {
    return '“$name” has no audio track, so there is nothing to transcribe.';
  }

  @override
  String errUnsupportedContainer(String extension) {
    return 'Vox Scripta cannot read .$extension files. Convert it to .mp4, .m4a or .wav first — a stream copy is enough, and costs no quality.';
  }

  @override
  String errDecodingFailed(String reason) {
    return 'The audio could not be decoded: $reason.';
  }

  @override
  String errNoWordsRecognized(String locale) {
    return 'No words were recognised. This recording was transcribed as $locale — if it is in another language, change it in Settings and import the file again.';
  }

  @override
  String get errMicrophoneDenied =>
      'Vox Scripta does not have permission to use the microphone. Grant it in Settings, then try recording again.';

  @override
  String errRecordingFailed(String reason) {
    return 'The recording could not be started: $reason.';
  }

  @override
  String errAnalysisFailed(String stage, String reason) {
    return 'Audio analysis failed during $stage: $reason.';
  }

  @override
  String get errNoSpeechDetected => 'No speech was detected in this recording.';

  @override
  String errEngineUnavailable(String engine, String reason) {
    return 'The $engine engine is unavailable: $reason.';
  }

  @override
  String errLocaleUnsupported(String engine, String locale) {
    return 'The $engine engine does not support $locale.';
  }

  @override
  String errTranscriptionFailed(String chunk, String reason) {
    return 'Chunk $chunk could not be transcribed: $reason.';
  }

  @override
  String errModelAssetMissing(String description) {
    return 'A required model asset is missing: $description.';
  }

  @override
  String errModelUnavailable(String model, String reason) {
    return 'The language model $model is unavailable: $reason.';
  }

  @override
  String errContextWindowExceeded(int tokens, int limit) {
    final intl.NumberFormat tokensNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String tokensString = tokensNumberFormat.format(tokens);
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Input of $tokensString tokens exceeds the $limitString-token limit.';
  }

  @override
  String errValidationRejected(String reasons) {
    return 'Polished output failed validation: $reasons.';
  }

  @override
  String errProjectCorrupt(String reason) {
    return 'The project file is damaged: $reason.';
  }

  @override
  String errSchemaTooNew(int found, int supported) {
    final intl.NumberFormat foundNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String foundString = foundNumberFormat.format(found);
    final intl.NumberFormat supportedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String supportedString = supportedNumberFormat.format(supported);

    return 'This project was made by a newer version (schema $foundString, this app supports $supportedString).';
  }

  @override
  String errInsufficientDiskSpace(String needed, String available) {
    return 'Needs $needed of free space; $available available.';
  }

  @override
  String errIoFailure(String path, String reason) {
    return 'Could not read or write $path: $reason.';
  }

  @override
  String get errCancelled => 'Processing was cancelled.';

  @override
  String passwordRuleLength(int minimum) {
    return 'At least $minimum characters';
  }

  @override
  String get passwordRuleUppercase => 'One capital letter';

  @override
  String get passwordRuleNumber => 'One number';

  @override
  String get passwordRuleSpecial => 'One symbol, such as ! ? # or &';

  @override
  String get reportProblem => 'Report a problem';

  @override
  String get reportProblemHelp =>
      'See what a report would say before you send it.';

  @override
  String get reportExplain =>
      'Nothing has been sent. This app cannot send anything. Read the report, then share it however you like, or not at all. It holds no transcript, audio or file paths.';

  @override
  String get reportShare => 'Share…';

  @override
  String get reportSave => 'Save…';

  @override
  String get reportCopy => 'Copy';

  @override
  String get reportCopied => 'Copied the report.';

  @override
  String get reportSubject => 'Vox Scripta problem report';

  @override
  String get reportShareFailed =>
      'No app could take the report. Copy it instead.';

  @override
  String get reportUnavailable => 'The report could not be made.';
}
