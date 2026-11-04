import 'package:flutter/foundation.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The library screen's state.
///
/// Holds no rules. Listing, deleting and where the library lives are all the
/// engine's answers — this class decides when to ask and what to show while
/// waiting, which is the whole of an interface's job under `Docs/PARITY.md`.
class LibraryModel extends ChangeNotifier {
  LibraryModel(this._source);

  /// Built from the engine in the app; from a stub in widget tests.
  factory LibraryModel.of(VoxScriptaEngine engine) =>
      LibraryModel(EngineLibrarySource(engine));

  final LibrarySource _source;

  List<ProjectEntry> _projects = const [];
  String? _error;
  bool _isLoading = true;
  String? _selectedId;

  List<ProjectEntry> get projects => _projects;
  String? get error => _error;
  bool get isLoading => _isLoading;
  String? get selectedId => _selectedId;

  /// Where the engine says the library is. Shown in the empty state, because
  /// "no recordings yet" is much less useful than "no recordings yet, here".
  String get directory => _source.directory;

  ProjectEntry? get selected {
    if (_selectedId == null) return null;
    for (final project in _projects) {
      if (project.id == _selectedId) return project;
    }
    return null;
  }

  void refresh() {
    _isLoading = true;
    notifyListeners();
    try {
      _projects = _source.list();
      _error = null;
      // A project that was deleted elsewhere should not stay selected.
      if (selected == null) _selectedId = null;
    } on VoxScriptaException catch (failure) {
      _error = failure.message;
      _projects = const [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    notifyListeners();
  }

  /// Deletes a project and reports where it went.
  ///
  /// Returns the path it was moved to, or null if the platform could not say.
  /// Throws [VoxScriptaException] with the engine's own words, which the screen
  /// shows rather than paraphrasing.
  String? delete(ProjectEntry project) {
    final movedTo = _source.delete(project.path);
    if (_selectedId == project.id) _selectedId = null;
    refresh();
    return movedTo;
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}

/// The three things the library screen asks of the engine.
///
/// A seam rather than the engine itself, and the reason is narrow: the widget
/// tests are about the screen — its empty state, its confirmation, what it says
/// when something fails — and making them each dlopen a real library would be
/// slow and would test something `voxscripta_engine`'s own suite already tests
/// properly. The boundary keeps its no-mocks rule; this is above the boundary.
abstract interface class LibrarySource {
  String get directory;
  List<ProjectEntry> list();

  /// Returns where the project was moved to, or null if unknown.
  String? delete(String path);
}

/// The real one.
class EngineLibrarySource implements LibrarySource {
  const EngineLibrarySource(this._engine);

  final VoxScriptaEngine _engine;

  @override
  String get directory => _engine.defaultLibraryDirectory;

  @override
  List<ProjectEntry> list() => _engine.library();

  @override
  String? delete(String path) => _engine.deleteProject(path);
}
