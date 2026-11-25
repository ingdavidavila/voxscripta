// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get tryAgain => 'Intentar de nuevo';

  @override
  String get record => 'Grabar';

  @override
  String get openFile => 'Abrir un archivo';

  @override
  String get open => 'Abrir';

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Eliminar';

  @override
  String get deleteEllipsis => 'Eliminar…';

  @override
  String get discard => 'Descartar';

  @override
  String get finish => 'Terminar';

  @override
  String get stop => 'Detener';

  @override
  String get restore => 'Restaurar';

  @override
  String get or => 'o';

  @override
  String get libraryTitle => 'Grabaciones';

  @override
  String get libraryRefreshTooltip =>
      'Volver a buscar grabaciones en el disco.';

  @override
  String get libraryOpenTooltip => 'Abre un archivo de audio que ya tengas.';

  @override
  String get libraryRecordTooltip => 'Graba algo ahora.';

  @override
  String get librarySettingsTooltip =>
      'Detección de silencio, idioma, limpieza y pulido.';

  @override
  String get libraryUnreadableTitle => 'No se pudo leer la biblioteca';

  @override
  String get libraryEmptyTitle => 'Aún no hay grabaciones';

  @override
  String libraryEmptyDetail(String directory) {
    return 'Graba algo, o abre un archivo.\n\n$directory';
  }

  @override
  String projectCannotOpen(String name) {
    return '$name no se puede abrir aquí.';
  }

  @override
  String couldNotOpenFileManager(String manager) {
    return 'No se pudo abrir $manager.';
  }

  @override
  String deleteProjectTitle(String name) {
    return '¿Eliminar $name?';
  }

  @override
  String get deleteExplainTrash =>
      'El proyecto se mueve a la Papelera. Tu archivo de audio original no se toca.';

  @override
  String get deleteExplainFolder =>
      'El proyecto se mueve a una carpeta Eliminados junto a la biblioteca. Tu archivo de audio original no se toca.';

  @override
  String deletedProject(String name) {
    return 'Se eliminó $name.';
  }

  @override
  String movedProjectTo(String name, String path) {
    return 'Se movió $name a $path';
  }

  @override
  String projectTileTooltip(String name, String duration) {
    return '$name · $duration. Haz clic para abrir su transcripción.';
  }

  @override
  String showInFileManager(String manager) {
    return 'Mostrar en $manager';
  }

  @override
  String get justNow => 'ahora mismo';

  @override
  String minutesAgo(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String hoursAgo(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'hace $hours horas',
      one: 'hace 1 hora',
    );
    return '$_temp0';
  }

  @override
  String daysAgo(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'hace $days días',
      one: 'hace 1 día',
    );
    return '$_temp0';
  }

  @override
  String get subscribe => 'Suscribirse';

  @override
  String get seePlans => 'Ver planes';

  @override
  String get trialLastDay => 'Último día de tu prueba gratuita.';

  @override
  String trialDaysLeft(int days) {
    return 'Quedan $days días de tu prueba gratuita.';
  }

  @override
  String trialEnded(int days) {
    return 'Tu prueba de $days días ha terminado. Todo lo que ya transcribiste sigue siendo tuyo.';
  }

  @override
  String get subscriptionLapsed =>
      'Tu suscripción ha vencido. Todo lo ya transcrito sigue siendo tuyo.';

  @override
  String get paywallPrivacyPromise =>
      'Vox Scripta transcribe en este equipo. No se sube nada, no se envía nada a ningún servicio, y nada de eso cambia con una suscripción: lo que pagas con ella es el trabajo de crear la aplicación.';

  @override
  String get noPlans => 'La tienda no devolvió ningún plan.';

  @override
  String get paywallHeadlineTrialing => 'Continúa después de tu prueba';

  @override
  String paywallHeadlineExpired(int days) {
    return 'Tu prueba de $days días ha terminado';
  }

  @override
  String get paywallHeadlineLapsed => 'Tu suscripción ha vencido';

  @override
  String get paywallHeadlineSubscribed => 'Tu suscripción está activa';

  @override
  String get staysYoursTitle => 'Lo que sigue siendo tuyo en cualquier caso';

  @override
  String get staysYoursRecordings =>
      'Todas las grabaciones que importaste, intactas y donde las dejaste.';

  @override
  String get staysYoursTranscripts =>
      'Todas las transcripciones ya hechas: se pueden leer, copiar y exportar.';

  @override
  String get staysYoursExports =>
      'Todos los formatos de exportación: txt, md, docx, srt, vtt.';

  @override
  String get staysYoursFolder => 'Tu carpeta de proyectos, en tu propio disco.';

  @override
  String get subscriptionUnlocks =>
      'La suscripción habilita nuevas transcripciones y la grabación.';

  @override
  String get subscriptionDisclosure =>
      'Las suscripciones se renuevan automáticamente al precio indicado hasta que se cancelen. Puedes cancelar cuando quieras; la suscripción sigue vigente hasta el final del periodo ya pagado.';

  @override
  String get termsOfUse => 'Términos de uso';

  @override
  String get privacyPolicy => 'Política de privacidad';

  @override
  String get manageSubscription => 'Gestionar suscripción';

  @override
  String get noStoreTitle => 'Esta versión no tiene ninguna tienda conectada';

  @override
  String get noStoreBody =>
      'Las suscripciones se venden en la App Store en los dispositivos Apple y en Google Play en Android, y ninguna de las dos está conectada todavía, así que aquí no hay nada que comprar. Esta versión no puede iniciar nuevas transcripciones cuando termina la prueba.';

  @override
  String get importTitle => 'Abrir audio';

  @override
  String get importChooseFile => 'Elegir un archivo…';

  @override
  String get importOrTypePath => 'o escribe una ruta';

  @override
  String get importStaysPut =>
      'El archivo se queda donde está. Vox Scripta lo lee y nunca lo modifica.';

  @override
  String get importChooseOrType => 'Elige un archivo, o escribe su ruta.';

  @override
  String get importNoFile => 'No hay ningún archivo en esa ruta.';

  @override
  String importUnsupported(String extension, String formats) {
    return 'Vox Scripta no puede leer archivos .$extension. Lee $formats y más.';
  }

  @override
  String get recordingTitle => 'Grabación';

  @override
  String get recordingOpeningMic => 'Abriendo el micrófono…';

  @override
  String get recordingRecording => 'Grabando…';

  @override
  String get recordingPaused => 'En pausa';

  @override
  String get audioNeverLeavesDevice =>
      'Tu audio nunca sale de este dispositivo';

  @override
  String get discardRecordingTitle => '¿Descartar esta grabación?';

  @override
  String get discardRecordingBody =>
      'Se eliminará el audio grabado hasta ahora. Esto no se puede deshacer.';

  @override
  String get keepRecording => 'Seguir grabando';

  @override
  String get discardRecordingTooltip =>
      'Elimina esta grabación sin conservarla.';

  @override
  String get resumeRecordingTooltip => 'Sigue grabando en el mismo archivo.';

  @override
  String get pauseRecordingTooltip =>
      'Deja de capturar sin terminar la grabación.';

  @override
  String get micCouldNotOpen => 'No se pudo abrir el micrófono';

  @override
  String get writingStopped => 'Se detuvo la escritura';

  @override
  String writingStoppedDetail(String message) {
    return '$message\n\nLo grabado antes de esto sigue en el disco.';
  }

  @override
  String get silentInputTitle => 'No llega sonido al micrófono';

  @override
  String get silentInputBody =>
      'La grabación sigue en marcha y se conservará. Comprueba que esté seleccionada la entrada correcta y que no esté silenciada.';

  @override
  String get micAccessBlocked =>
      'El acceso al micrófono está desactivado. Vox Scripta no tiene permiso para usarlo. Actívalo en Ajustes, en Aplicaciones, Vox Scripta, Permisos, y vuelve a intentar grabar.';

  @override
  String get micAccessDenied =>
      'No se concedió el acceso al micrófono, así que no se grabó nada. Vuelve atrás e inténtalo de nuevo, y permite el micrófono cuando se te pregunte.';

  @override
  String get jobCouldNotStart => 'Este trabajo no pudo iniciarse';

  @override
  String get jobStopped => 'Este trabajo se detuvo';

  @override
  String get jobStarting => 'Iniciando…';

  @override
  String speechSummary(int regions, int percent) {
    return '$regions regiones de voz · el $percent% de la grabación es voz';
  }

  @override
  String durationMinutes(int minutes) {
    return '$minutes minutos';
  }

  @override
  String durationHours(String hours) {
    return '$hours horas';
  }

  @override
  String polishNotice(String duration) {
    return 'El pulido tardará unos $duration: hace una petición al modelo de lenguaje por cada frase. La transcripción termina mucho antes, y puedes leerla mientras el pulido continúa.';
  }

  @override
  String get readingAudio => 'Leyendo el audio…';

  @override
  String get modelPreparingTitle => 'Preparando el modelo de voz';

  @override
  String modelNoSpace(int megabytes) {
    return 'No hay espacio libre suficiente para preparar el modelo de voz. Se necesitan unos $megabytes MB en este dispositivo.';
  }

  @override
  String get modelNotInPlace => 'No se pudo colocar el modelo de voz.';

  @override
  String modelCopyFailed(String detail) {
    return 'No se pudo preparar el modelo de voz: $detail';
  }

  @override
  String get modelPreparingBody =>
      'Esto ocurre una sola vez, la primera vez, y no usa la red. La transcripción empieza cuando termina.';

  @override
  String get phaseAnalyze => 'Analizar audio';

  @override
  String get phaseSilence => 'Detectar silencio';

  @override
  String get phasePlan => 'Planificar segmentos';

  @override
  String get phaseTranscribe => 'Transcribir';

  @override
  String get phaseAssemble => 'Ensamblar transcripción';

  @override
  String get phaseClean => 'Limpia';

  @override
  String get phasePolish => 'Pulir';

  @override
  String get variantVerbatim => 'Literal';

  @override
  String get variantClean => 'Limpia';

  @override
  String get variantPolished => 'Pulida';

  @override
  String get variantVerbatimExplained =>
      'Exactamente lo que se dijo, titubeos incluidos.';

  @override
  String get variantCleanExplained =>
      'Ordenada con reglas fijas. No interviene ningún modelo de lenguaje.';

  @override
  String get variantPolishedExplained =>
      'Reescrita para que se lea mejor, contrastada con el original.';

  @override
  String get formatPlainText => 'Texto sin formato (.txt)';

  @override
  String get formatMarkdown => 'Markdown (.md)';

  @override
  String get formatWord => 'Word (.docx)';

  @override
  String get formatSubRip => 'Subtítulos (.srt)';

  @override
  String get formatWebVTT => 'Subtítulos web (.vtt)';

  @override
  String get formatPlainTextExplained =>
      'Solo las palabras, en un archivo que abre cualquier editor.';

  @override
  String get formatMarkdownExplained =>
      'Palabras con formato ligero, para notas y documentación.';

  @override
  String get formatWordExplained =>
      'Un documento de Word, para compartir y seguir editando.';

  @override
  String get formatSubRipExplained =>
      'Subtítulos con tiempos, el formato que esperan casi todos los editores de vídeo.';

  @override
  String get formatWebVTTExplained => 'Subtítulos con tiempos para la web.';

  @override
  String get dispositionAccepted => 'Aceptadas';

  @override
  String get dispositionAcceptedAfterRetry => 'Aceptada tras un reintento';

  @override
  String get dispositionFellBackToClean => 'Se conservó el texto limpio';

  @override
  String get dispositionModelFailed =>
      'El modelo falló: se conservó el texto limpio';

  @override
  String get dispositionUnknown => 'Desconocido';

  @override
  String get reviewToggleTooltip =>
      'Muestra qué cambió el pulido y qué rechazó.';

  @override
  String get nothingToCopy => 'Todavía no hay nada que copiar.';

  @override
  String copyTranscriptTooltip(String variant) {
    return 'Copia al portapapeles la transcripción $variant completa.';
  }

  @override
  String get projectUnreadableTitle => 'No se pudo leer este proyecto';

  @override
  String get noTranscriptTitle => 'Todavía no hay nada transcrito';

  @override
  String get noTranscriptDetail =>
      'Este proyecto no tiene ninguna transcripción terminada.';

  @override
  String get transcribeIt => 'Transcribir';

  @override
  String copiedTranscript(String variant) {
    return 'Se copió la transcripción $variant.';
  }

  @override
  String get transcriptUnreadableTitle => 'No se pudo leer esa transcripción';

  @override
  String get includeTimestamps => 'Incluir marcas de tiempo';

  @override
  String get saveTranscriptTooltip =>
      'Guarda esta transcripción. Los formatos y las marcas de tiempo están en el menú.';

  @override
  String get saveDialogTitle => 'Guardar transcripción';

  @override
  String savedTo(String where) {
    return 'Guardado en $where';
  }

  @override
  String saveFailed(String reason) {
    return 'No se pudo guardar el archivo: $reason';
  }

  @override
  String get nothingToSave => 'Todavía no hay nada que guardar.';

  @override
  String wordsAndSegments(int words, int segments) {
    return '$words palabras · $segments segmentos';
  }

  @override
  String get polishDidNotRun => 'El pulido no se ejecutó';

  @override
  String get noReasonRecorded => 'No se registró ningún motivo.';

  @override
  String get polishReview => 'Revisión del pulido';

  @override
  String get everySentencePassed => 'Todas las frases pasaron.';

  @override
  String get reviewModelLabel => 'Modelo';

  @override
  String get engineUnavailableTitle => 'No se pudo cargar el motor';

  @override
  String get noReasonReported => 'No se indicó ningún motivo.';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get resetToDefaults => 'Restablecer valores predeterminados';

  @override
  String get sectionSilence => 'Detección de silencios';

  @override
  String get silenceThreshold => 'Umbral sobre el ruido';

  @override
  String get silenceThresholdHelp =>
      'Cuánto debe superar un sonido al ruido de fondo medido para contar como habla. Súbelo si la grabación es ruidosa.';

  @override
  String get shortestPause => 'Pausa más corta';

  @override
  String get shortestPauseHelp =>
      'Un tramo callado más breve que esto se considera parte del habla, no una pausa.';

  @override
  String get paddingAfterSpeech => 'Margen tras el habla';

  @override
  String get paddingAfterSpeechHelp =>
      'Silencio que se conserva después de cada frase, para que no se corten los finales de palabra al quitar los silencios.';

  @override
  String get sectionSegmentation => 'Segmentación';

  @override
  String get segmentationFooter =>
      'Los segmentos son internos. Determinan con qué frecuencia se guarda el trabajo, no cómo se lee la transcripción.';

  @override
  String get maxSegmentLength => 'Duración máxima del segmento';

  @override
  String get maxSegmentLengthHelp =>
      'El tramo de audio más largo que se transcribe como una unidad. Los segmentos cortos guardan el progreso más a menudo.';

  @override
  String get sectionTranscription => 'Transcripción';

  @override
  String get transcriptionFooter =>
      'Hacer más a la vez es más rápido hasta cierto punto, y consume memoria. El cuatro está medido, no supuesto.';

  @override
  String get detectLanguage => 'Detectar idioma';

  @override
  String get detectLanguageHelp =>
      'Prueba con una muestra corta los idiomas que este equipo puede transcribir y usa el que el motor reconoce con seguridad. El ajuste de abajo es el de reserva. No se descarga nada.';

  @override
  String get verbatimOnlyNotice =>
      'En este idioma solo hay versión literal. Limpia y Pulida necesitan léxicos que Vox Scripta aún no tiene.';

  @override
  String get polishedUnavailableNotice =>
      'La versión pulida no está disponible en este idioma. Las comprobaciones que detectan un significado invertido no se han verificado aquí, así que el pulido se retiene en lugar de ejecutarse sin protección.';

  @override
  String get segmentsAtOnce => 'Segmentos a la vez';

  @override
  String get segmentsAtOnceHelp => 'Cuántos segmentos se transcriben a la vez.';

  @override
  String get cleanFooter =>
      'La versión limpia usa solo reglas fijas. No interviene ningún modelo de lenguaje, y cada cambio queda registrado.';

  @override
  String get removeFillers => 'Quitar muletillas';

  @override
  String get removeFillersHelp => 'Elimina “eh”, “em” y similares.';

  @override
  String get collapseStutters => 'Unir repeticiones';

  @override
  String get collapseStuttersHelp => 'Convierte “el el el” en “el”.';

  @override
  String get dropLowConfidence => 'Descartar palabras dudosas';

  @override
  String get dropLowConfidenceHelp =>
      'Elimina las palabras de las que el motor no estaba seguro.';

  @override
  String get sectionStorage => 'Almacenamiento y privacidad';

  @override
  String get privacyFooter =>
      'La transcripción se hace por completo en este equipo. Ninguna grabación ni transcripción se sube jamás, y no hay telemetría.';

  @override
  String get privacyFooterWithAccount =>
      'La transcripción se ejecuta por completo en este equipo. Ninguna grabación ni transcripción se sube nunca, y no hay telemetría. La cuenta es opcional y solo contiene tu dirección de correo, para iniciar sesión.';

  @override
  String get keepWorkingFiles => 'Conservar los archivos de trabajo';

  @override
  String get keepWorkingFilesHelp =>
      'Conserva el audio de trabajo cuando termina un trabajo. Ocupa unos 1,4 GB en una grabación de seis horas, y las transcripciones no lo necesitan.';

  @override
  String get projectsFolder => 'Carpeta de proyectos';

  @override
  String get polishFooter =>
      'El pulido reescribe frase a frase y contrasta cada reescritura con el original. Una reescritura que falla se descarta y se conserva la frase limpia.';

  @override
  String get createPolished => 'Crear una transcripción pulida';

  @override
  String get polishRunsAfterClean =>
      'Ejecuta el paso del modelo después de la limpieza.';

  @override
  String get polishUnavailableInLanguage =>
      'No está disponible en el idioma seleccionado.';

  @override
  String get languageModel => 'Modelo de lenguaje';

  @override
  String get languageModelHelp =>
      'Qué modelo preferir. Un modelo indicado que no esté disponible se rechaza, en vez de cambiarlo en silencio por otro.';

  @override
  String get backendAutomatic => 'El mejor disponible';

  @override
  String get backendSystem => 'Apple Intelligence';

  @override
  String get backendBundled => 'Modelo incluido';

  @override
  String get willUse => 'Se usará';

  @override
  String get polishWillBeSkipped => 'no disponible: se omitirá el pulido';

  @override
  String get available => 'Disponible';

  @override
  String get unavailable => 'No disponible';

  @override
  String get notIncluded => 'No incluido';

  @override
  String get settingsLanguage => 'Idioma';

  @override
  String get settingsLanguageHelp =>
      'El idioma que se habla en la grabación. Equivocarse aquí cuesta más precisión que cualquier otro ajuste.';

  @override
  String get noLanguagesReported =>
      'No se indicó ningún idioma de transcripción.';

  @override
  String get account => 'Cuenta';

  @override
  String get signedInAs => 'Sesión iniciada como';

  @override
  String get signedInWith => 'Sesión iniciada con';

  @override
  String get signOut => 'Cerrar sesión';

  @override
  String get signOutNote =>
      'Tus grabaciones y transcripciones permanecen en este equipo.';

  @override
  String get deleteAccount => 'Eliminar cuenta';

  @override
  String get deleteAccountNote =>
      'Elimina la cuenta y todo lo que el servicio de cuentas guarda sobre ella. Tus proyectos locales no se tocan.';

  @override
  String get providerPassword => 'Un correo electrónico y una contraseña';

  @override
  String get deleteAccountTitle => '¿Eliminar esta cuenta?';

  @override
  String get deleteAccountBody =>
      'Se elimina la cuenta y todo lo que el servicio de cuentas guarda sobre ella. Esto no se puede deshacer.\n\nLas grabaciones, los proyectos y las transcripciones de este equipo no se eliminan: nunca estuvieron en la cuenta.';

  @override
  String get keepIt => 'Conservarla';

  @override
  String get signIn => 'Iniciar sesión';

  @override
  String get notNow => 'Ahora no';

  @override
  String get welcomeBack => 'Te damos la bienvenida de nuevo';

  @override
  String get accountIsOptionalNote =>
      'Tus grabaciones se quedan en este dispositivo en cualquier caso. Una cuenta solo sirve para los ajustes que te acompañan.';

  @override
  String get emailField => 'Correo electrónico';

  @override
  String get passwordField => 'Contraseña';

  @override
  String get forgotPassword => '¿Olvidaste tu contraseña?';

  @override
  String get noAccountYet => '¿Aún no tienes cuenta?';

  @override
  String get createOne => 'Crear una';

  @override
  String get enterYourEmail => 'Escribe tu correo electrónico.';

  @override
  String get enterYourPassword => 'Introduce tu contraseña.';

  @override
  String get createAnAccount => 'Crear una cuenta';

  @override
  String get orSignUpWithEmail => 'o regístrate con correo electrónico';

  @override
  String get emailHelper =>
      'Se usa para iniciar sesión y para restablecer tu contraseña.';

  @override
  String get confirmPasswordField => 'Repite la contraseña';

  @override
  String get createAccount => 'Crear cuenta';

  @override
  String get deleteAnytimeNote =>
      'Puedes eliminar tu cuenta, y todo lo guardado con ella, desde Ajustes en cualquier momento.';

  @override
  String get enterAnEmailAddress => 'Escribe un correo electrónico.';

  @override
  String get notAnEmailAddress => 'Eso no parece una dirección de correo.';

  @override
  String get typePasswordAgain => 'Escribe tu contraseña otra vez.';

  @override
  String get passwordsDoNotMatch => 'Las dos contraseñas no coinciden.';

  @override
  String get passwordRequirementsUnmet =>
      'Tu contraseña todavía no cumple todos los requisitos.';

  @override
  String get resetYourPassword => 'Restablece tu contraseña';

  @override
  String get resetPasswordIntro =>
      'Escribe el correo con el que te registraste y te enviaremos un enlace para elegir una contraseña nueva.';

  @override
  String get sendResetLink => 'Enviar enlace de restablecimiento';

  @override
  String get checkYourEmail => 'Revisa tu correo';

  @override
  String resetLinkSent(String email) {
    return 'Si $email tiene una cuenta, un enlace de restablecimiento va en camino. Caduca en poco tiempo, así que úsalo pronto.';
  }

  @override
  String get backToSignIn => 'Volver a iniciar sesión';

  @override
  String get useDifferentEmail => 'Usar otro correo';

  @override
  String get enterYourEmailAddress => 'Introduce tu dirección de correo.';

  @override
  String get hidePassword => 'Ocultar contraseña';

  @override
  String get showPassword => 'Mostrar contraseña';

  @override
  String get continueWithApple => 'Continuar con Apple';

  @override
  String get continueWithGoogle => 'Continuar con Google';

  @override
  String get signInOptionalNote =>
      'Opcional. La transcripción funciona sin ella.';

  @override
  String errSourceUnavailable(String path) {
    return 'No se encontró el archivo de audio en $path.';
  }

  @override
  String errSourceChanged(String path) {
    return 'El archivo de audio en $path ha cambiado desde que se importó.';
  }

  @override
  String errUnsupportedFormat(String description) {
    return 'Este formato de audio no es compatible: $description.';
  }

  @override
  String errNoAudioTrack(String name) {
    return '“$name” no tiene pista de audio, así que no hay nada que transcribir.';
  }

  @override
  String errUnsupportedContainer(String extension) {
    return 'Vox Scripta no puede leer archivos .$extension. Conviértelo antes a .mp4, .m4a o .wav: basta con copiar el flujo, y no se pierde calidad.';
  }

  @override
  String errDecodingFailed(String reason) {
    return 'No se pudo decodificar el audio: $reason.';
  }

  @override
  String errNoWordsRecognized(String locale) {
    return 'No se reconoció ninguna palabra. Esta grabación se transcribió como $locale; si está en otro idioma, cámbialo en Ajustes y vuelve a importar el archivo.';
  }

  @override
  String get errMicrophoneDenied =>
      'Vox Scripta no tiene permiso para usar el micrófono. Concédelo en Ajustes y vuelve a intentar grabar.';

  @override
  String errRecordingFailed(String reason) {
    return 'No se pudo iniciar la grabación: $reason.';
  }

  @override
  String errAnalysisFailed(String stage, String reason) {
    return 'El análisis del audio falló durante $stage: $reason.';
  }

  @override
  String get errNoSpeechDetected => 'No se detectó habla en esta grabación.';

  @override
  String errEngineUnavailable(String engine, String reason) {
    return 'El motor $engine no está disponible: $reason.';
  }

  @override
  String errLocaleUnsupported(String engine, String locale) {
    return 'El motor $engine no admite $locale.';
  }

  @override
  String errTranscriptionFailed(String chunk, String reason) {
    return 'No se pudo transcribir el fragmento $chunk: $reason.';
  }

  @override
  String errModelAssetMissing(String description) {
    return 'Falta un recurso necesario del modelo: $description.';
  }

  @override
  String errModelUnavailable(String model, String reason) {
    return 'El modelo de lenguaje $model no está disponible: $reason.';
  }

  @override
  String errContextWindowExceeded(int tokens, int limit) {
    final intl.NumberFormat tokensNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String tokensString = tokensNumberFormat.format(tokens);
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'La entrada de $tokensString tokens supera el límite de $limitString.';
  }

  @override
  String errValidationRejected(String reasons) {
    return 'El texto pulido no pasó la validación: $reasons.';
  }

  @override
  String errProjectCorrupt(String reason) {
    return 'El archivo del proyecto está dañado: $reason.';
  }

  @override
  String errSchemaTooNew(int found, int supported) {
    final intl.NumberFormat foundNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String foundString = foundNumberFormat.format(found);
    final intl.NumberFormat supportedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String supportedString = supportedNumberFormat.format(supported);

    return 'Este proyecto se creó con una versión más reciente (esquema $foundString; esta app admite $supportedString).';
  }

  @override
  String errInsufficientDiskSpace(String needed, String available) {
    return 'Necesita $needed de espacio libre; hay $available disponibles.';
  }

  @override
  String errIoFailure(String path, String reason) {
    return 'No se pudo leer ni escribir $path: $reason.';
  }

  @override
  String get errCancelled => 'Se canceló el proceso.';

  @override
  String passwordRuleLength(int minimum) {
    return 'Al menos $minimum caracteres';
  }

  @override
  String get passwordRuleUppercase => 'Una letra mayúscula';

  @override
  String get passwordRuleNumber => 'Un número';

  @override
  String get passwordRuleSpecial => 'Un símbolo, como ! ? # o &';
}
