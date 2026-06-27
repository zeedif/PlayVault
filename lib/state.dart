import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'hltb_service.dart';
import 'model.dart';

enum TriFilter { all, yes, no }
enum SliderDistribution { discrete, quadratic, cubic }
enum ExperienceFilter { any, coop, pvp, both }
typedef StatusEntry = ({GameStatus status, bool visible});

// ─── ESTADO ───

class HomeState({
  final List<Game> filteredGames = const [],
  final int gameCount = 0,
  final double totalBytes = 0,

  // Estado de operaciones en segundo plano
  final bool isFetchingGfnDb = false,
  final int steamQueueSize = 0,
  final int hltbQueueSize = 0,

  // Configuración y rutas
  final String? esDePath,
  final Map<String, Map<String, dynamic>> filterProfiles = const {},

  // Ordenación
  final String sortBy = 'name',
  final bool sortAsc = true,
  final bool groupByStatus = false,
  required final List<StatusEntry> statusFilters,

  // Filtros — búsqueda y visibilidad
  final String searchQuery = '',
  final Set<GameLanguage> visibleLanguages = const {},
  final Set<SpType> visibleSpTypes = const {},
  final Set<VrSupport> visibleVrTypes = const {},
  final bool includeSoftware = false,

  // Filtros — características de juego
  final TriFilter friendPlayFilter = TriFilter.all,
  final ExperienceFilter friendPlayExperience = ExperienceFilter.any,
  final TriFilter matchmakingFilter = TriFilter.all,
  final ExperienceFilter matchmakingExperience = ExperienceFilter.any,
  final TriFilter achievementsFilter = TriFilter.all,
  final TriFilter steamCloudFilter = TriFilter.all,
  final TriFilter priceFilter = TriFilter.all,
  final TriFilter geforceNowFilter = TriFilter.all,

  // Slider — formato, distribución y límites
  final bool binaryFormat = false,
  final SliderDistribution sliderDistribution = SliderDistribution.discrete,
  final double absoluteMinBytes = 0,
  final double absoluteMaxBytes = 1,
  final double currentMinBytes = 0,
  final double currentMaxBytes = 1,
}) {
  bool get isFetchingSteam => steamQueueSize > 0;
  bool get isFetchingHltb => hltbQueueSize > 0;

  /// Comprueba si un estado específico está activo en los filtros actuales.
  bool isStatusVisible(GameStatus status) {
    for (final e in statusFilters) {
      if (e.status == status) return e.visible;
    }
    return true;
  }

  /// Devuelve un set con los estados que el usuario mantiene visibles.
  Set<GameStatus> get visibleStatuses => {
    for (final e in statusFilters) if (e.visible) e.status,
  };

   /// Devuelve la lista de estados con el orden dado por el usuario.
  List<GameStatus> get statusOrder => [for (final e in statusFilters) e.status];

  HomeState copyWith({
    List<Game>? filteredGames,
    int? gameCount,
    double? totalBytes,
    bool? isFetchingGfnDb,
    int? steamQueueSize,
    int? hltbQueueSize,
    String? esDePath,
    Map<String, Map<String, dynamic>>? filterProfiles,
    String? sortBy,
    bool? sortAsc,
    bool? groupByStatus,
    List<StatusEntry>? statusFilters,
    String? searchQuery,
    Set<GameLanguage>? visibleLanguages,
    Set<SpType>? visibleSpTypes,
    Set<VrSupport>? visibleVrTypes,
    bool? includeSoftware,
    TriFilter? friendPlayFilter,
    ExperienceFilter? friendPlayExperience,
    TriFilter? matchmakingFilter,
    ExperienceFilter? matchmakingExperience,
    TriFilter? achievementsFilter,
    TriFilter? steamCloudFilter,
    TriFilter? priceFilter,
    TriFilter? geforceNowFilter,
    bool? binaryFormat,
    SliderDistribution? sliderDistribution,
    double? absoluteMinBytes,
    double? absoluteMaxBytes,
    double? currentMinBytes,
    double? currentMaxBytes,
  }) => HomeState(
    filteredGames: filteredGames ?? this.filteredGames,
    gameCount: gameCount ?? this.gameCount,
    totalBytes: totalBytes ?? this.totalBytes,
    isFetchingGfnDb: isFetchingGfnDb ?? this.isFetchingGfnDb,
    steamQueueSize: steamQueueSize ?? this.steamQueueSize,
    hltbQueueSize: hltbQueueSize ?? this.hltbQueueSize,
    esDePath: esDePath ?? this.esDePath,
    filterProfiles: filterProfiles ?? this.filterProfiles,
    sortBy: sortBy ?? this.sortBy,
    sortAsc: sortAsc ?? this.sortAsc,
    groupByStatus: groupByStatus ?? this.groupByStatus,
    statusFilters: statusFilters ?? this.statusFilters,
    searchQuery: searchQuery ?? this.searchQuery,
    visibleLanguages: visibleLanguages ?? this.visibleLanguages,
    visibleSpTypes: visibleSpTypes ?? this.visibleSpTypes,
    visibleVrTypes: visibleVrTypes ?? this.visibleVrTypes,
    includeSoftware: includeSoftware ?? this.includeSoftware,
    friendPlayFilter: friendPlayFilter ?? this.friendPlayFilter,
    friendPlayExperience: friendPlayExperience ?? this.friendPlayExperience,
    matchmakingFilter: matchmakingFilter ?? this.matchmakingFilter,
    matchmakingExperience: matchmakingExperience ?? this.matchmakingExperience,
    achievementsFilter: achievementsFilter ?? this.achievementsFilter,
    steamCloudFilter: steamCloudFilter ?? this.steamCloudFilter,
    priceFilter: priceFilter ?? this.priceFilter,
    geforceNowFilter: geforceNowFilter ?? this.geforceNowFilter,
    binaryFormat: binaryFormat ?? this.binaryFormat,
    sliderDistribution: sliderDistribution ?? this.sliderDistribution,
    absoluteMinBytes: absoluteMinBytes ?? this.absoluteMinBytes,
    absoluteMaxBytes: absoluteMaxBytes ?? this.absoluteMaxBytes,
    currentMinBytes: currentMinBytes ?? this.currentMinBytes,
    currentMaxBytes: currentMaxBytes ?? this.currentMaxBytes,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HomeState &&
        listEquals(other.filteredGames, filteredGames) &&
        other.gameCount == gameCount &&
        other.totalBytes == totalBytes &&
        other.isFetchingGfnDb == isFetchingGfnDb &&
        other.steamQueueSize == steamQueueSize &&
        other.hltbQueueSize == hltbQueueSize &&
        other.esDePath == esDePath &&
        mapEquals(other.filterProfiles, filterProfiles) &&
        other.sortBy == sortBy &&
        other.sortAsc == sortAsc &&
        other.groupByStatus == groupByStatus &&
        listEquals(other.statusFilters, statusFilters) &&
        other.searchQuery == searchQuery &&
        setEquals(other.visibleLanguages, visibleLanguages) &&
        setEquals(other.visibleSpTypes, visibleSpTypes) &&
        setEquals(other.visibleVrTypes, visibleVrTypes) &&
        other.includeSoftware == includeSoftware &&
        other.friendPlayFilter == friendPlayFilter &&
        other.friendPlayExperience == friendPlayExperience &&
        other.matchmakingFilter == matchmakingFilter &&
        other.matchmakingExperience == matchmakingExperience &&
        other.achievementsFilter == achievementsFilter &&
        other.steamCloudFilter == steamCloudFilter &&
        other.priceFilter == priceFilter &&
        other.geforceNowFilter == geforceNowFilter &&
        other.binaryFormat == binaryFormat &&
        other.sliderDistribution == sliderDistribution &&
        other.absoluteMinBytes == absoluteMinBytes &&
        other.absoluteMaxBytes == absoluteMaxBytes &&
        other.currentMinBytes == currentMinBytes &&
        other.currentMaxBytes == currentMaxBytes;
  }

  @override
  int get hashCode => Object.hashAll([
    filteredGames.length,
    gameCount,
    totalBytes,
    isFetchingGfnDb,
    steamQueueSize,
    hltbQueueSize,
    esDePath,
    filterProfiles.length,
    sortBy,
    sortAsc,
    groupByStatus,
    ...statusFilters.map((e) => Object.hash(e.status, e.visible)),
    searchQuery,
    visibleLanguages,
    visibleSpTypes,
    visibleVrTypes,
    includeSoftware,
    friendPlayFilter,
    friendPlayExperience,
    matchmakingFilter,
    matchmakingExperience,
    achievementsFilter,
    steamCloudFilter,
    priceFilter,
    geforceNowFilter,
    binaryFormat,
    sliderDistribution,
    absoluteMinBytes,
    absoluteMaxBytes,
    currentMinBytes,
    currentMaxBytes,
  ]);
}

// ─── CUBIT ───

class HomeCubit extends Cubit<HomeState> {
  // Tabla de verdad en memoria: fuente canónica para todos los hilos de tarea.
  // Los workers de cola leen/escriben aquí directamente sin depender del snapshot de HomeState.
  final Map<String, Game> _gamesById = {};

  // Índice steamId → internalId para lookups O(1) en las colas (evita O(N) por cada elemento).
  final Map<int, String> _steamIdToInternalId = {};

  // Mapeo en memoria para relacionar cada juego (internalId) con su archivo físico .json UUID.
  final Map<String, String> _gameFiles = {};

  // Cadenas de escritura por archivo: serializa las writes al mismo archivo sin bloquear la cola.
  final Map<String, Future<void>> _writeChain = {};

  // Colas fire-and-forget: lista de steamIds pendientes + flag de worker activo.
  final List<int> _steamQueue = [];
  bool _isSteamQueueRunning = false;
  final List<int> _hltbQueue = [];
  bool _isHltbQueueRunning = false;
  bool _isGfnQueueRunning = false;

  // Caché de los límites brutos de tamaño en bytes.
  // Se invalida (null) en limpiezas completas o importaciones con reemplazo total.
  ({double min, double max})? _sizeCache;

  //Configuración inicial: todos los statuses visibles en el orden del enum.
  static final List<StatusEntry> _defaultStatusFilters = [
    for (final s in GameStatus.values) (status: s, visible: true),
  ];

  HomeCubit() : super(HomeState(
    statusFilters: _defaultStatusFilters,
    visibleLanguages: GameLanguage.values.toSet(),
    visibleSpTypes: SpType.values.toSet(),
    visibleVrTypes: VrSupport.values.toSet(),
  )) {
    _loadLocalState();
  }

  Game? gameById(String id) => _gamesById[id];

  // ─── RUTAS ───

  // `getApplicationDocumentsDirectory` y `getExternalStorageDirectory` son
  // llamadas de plataforma costosas. Con `late final` el Future se resuelve una
  // sola vez; todas las awaits posteriores devuelven el valor ya cacheado.

  late final Future<String> _basePath = _resolveBasePath();

  Future<String> _resolveBasePath() async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) return extDir.parent.path;
    }
    return (await getApplicationDocumentsDirectory()).path;
  }

  late final Future<File> _localFile = _basePath.then((p) => File('$p/db.json'));

  late final Future<File> _gfnLocalFile = _basePath.then((p) => File('$p/gfn_db.json'));

  /// NOT late final: clearJson() puede borrar el directorio; necesitamos
  /// comprobar y recrearlo en cada acceso.
  Future<Directory> get _gamesDir async {
    final dir = Directory('${await _basePath}/games');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ─── HELPERS DE PARSEO ───────────────────────────────────────────────────────

  Set<T>? _parseEnumSet<T extends Enum>(Iterable<T> values, dynamic list) {
    if (list is! List) return null;
    final set = list
        .map((e) => values.byNameOrNull(e?.toString()))
        .whereType<T>()
        .toSet();
    return set.isEmpty ? null : set;
  }

  /// Parsea statusFilters desde JSON.
  /// Garantiza que todos los valores del enum estén presentes:
  /// los que falten en el JSON se añaden al final con visible=true.
  List<StatusEntry>? _parseStatusFilters(dynamic raw) {
    if (raw is List && raw.isNotEmpty) {
      final parsed = <StatusEntry>[];
      for (final e in raw) {
        if (e case {'status': final String name, 'visible': final bool vis}) {
          if (GameStatus.values.byNameOrNull(name) case final s?) {
            parsed.add((status: s, visible: vis));
          }
        }
      }
      if (parsed.isNotEmpty) {
        final seen = {for (final e in parsed) e.status};
        return [
          ...parsed,
          // Statuses añadidos al enum después del guardado quedan visibles al final
          for (final s in GameStatus.values)
            if (!seen.contains(s)) (status: s, visible: true),
        ];
      }
    }
    return null;
  }

  Map<String, Map<String, dynamic>> _parseFilterProfiles(dynamic data) {
    if (data is! Map) return {};
    return Map.fromEntries(
      data.entries
        .where((e) => e.key is String && e.value is Map)
        .map((e) => MapEntry(e.key as String, Map<String, dynamic>.from(e.value as Map))),
    );
  }

  Map<String, dynamic> _extractFilters(HomeState s) => {
    'visibleLanguages': s.visibleLanguages.map((e) => e.name).toList(),
    'visibleSpTypes': s.visibleSpTypes.map((e) => e.name).toList(),
    'visibleVrTypes': s.visibleVrTypes.map((e) => e.name).toList(),
    'includeSoftware': s.includeSoftware,
    'binaryFormat': s.binaryFormat,
    'matchmakingFilter': s.matchmakingFilter.name,
    'matchmakingExperience': s.matchmakingExperience.name,
    'friendPlayFilter': s.friendPlayFilter.name,
    'friendPlayExperience': s.friendPlayExperience.name,
    'achievementsFilter': s.achievementsFilter.name,
    'steamCloudFilter': s.steamCloudFilter.name,
    'priceFilter': s.priceFilter.name,
    'geforceNowFilter': s.geforceNowFilter.name,
    'sliderDistribution': s.sliderDistribution.name,
    'sortBy': s.sortBy,
    'sortAsc': s.sortAsc,
    'groupByStatus': s.groupByStatus,
    'statusFilters': s.statusFilters
        .map((e) => {'status': e.status.name, 'visible': e.visible})
        .toList(),
    'currentMinBytes': s.currentMinBytes,
    'currentMaxBytes': s.currentMaxBytes,
    'filterProfiles': s.filterProfiles,
    if (s.esDePath != null) 'esDePath': s.esDePath,
  };

  HomeState _restoreFilters(HomeState current, Map<String, dynamic> profile) => current.copyWith(
      searchQuery: profile['searchQuery'] as String? ?? current.searchQuery,
      visibleLanguages: _parseEnumSet(GameLanguage.values, profile['visibleLanguages']) ?? current.visibleLanguages,
      visibleSpTypes: _parseEnumSet(SpType.values, profile['visibleSpTypes']) ?? current.visibleSpTypes,
      visibleVrTypes: _parseEnumSet(VrSupport.values, profile['visibleVrTypes']) ?? current.visibleVrTypes,
      includeSoftware: profile['includeSoftware'] as bool? ?? current.includeSoftware,
      binaryFormat: profile['binaryFormat'] as bool? ?? current.binaryFormat,
      matchmakingFilter: TriFilter.values.byNameOrNull(profile['matchmakingFilter'] as String?) ?? current.matchmakingFilter,
      matchmakingExperience: ExperienceFilter.values.byNameOrNull(profile['matchmakingExperience'] as String?) ?? current.matchmakingExperience,
      friendPlayFilter: TriFilter.values.byNameOrNull(profile['friendPlayFilter'] as String?) ?? current.friendPlayFilter,
      friendPlayExperience: ExperienceFilter.values.byNameOrNull(profile['friendPlayExperience'] as String?) ?? current.friendPlayExperience,
      achievementsFilter: TriFilter.values.byNameOrNull(profile['achievementsFilter'] as String?) ?? current.achievementsFilter,
      steamCloudFilter: TriFilter.values.byNameOrNull(profile['steamCloudFilter'] as String?) ?? current.steamCloudFilter,
      priceFilter: TriFilter.values.byNameOrNull(profile['priceFilter'] as String?) ?? current.priceFilter,
      geforceNowFilter: TriFilter.values.byNameOrNull(profile['geforceNowFilter'] as String?) ?? current.geforceNowFilter,
      sliderDistribution: SliderDistribution.values.byNameOrNull(profile['sliderDistribution'] as String?) ?? current.sliderDistribution,
      sortBy: profile['sortBy'] as String? ?? current.sortBy,
      sortAsc: profile['sortAsc'] as bool? ?? current.sortAsc,
      groupByStatus: profile['groupByStatus'] as bool? ?? current.groupByStatus,
      statusFilters: _parseStatusFilters(profile['statusFilters']) ?? current.statusFilters,
      currentMinBytes: (profile['currentMinBytes'] as num?)?.toDouble() ?? current.currentMinBytes,
      currentMaxBytes: (profile['currentMaxBytes'] as num?)?.toDouble() ?? current.currentMaxBytes,
    );

  // ─── CARGA / GUARDADO LOCAL ───

  /// Carga el estado inicial desde disco: primero los archivos de juego individuales en `games/`,
  /// después la configuración en `db.json`. Re-encola los juegos con fetches pendientes y
  /// descarga el catálogo GFN si no existe localmente.
  Future<void> _loadLocalState() async {
    final gamesDir = await _gamesDir;
    final Map<String, Game> loadedGames = {};

    if (await gamesDir.exists()) {
      final files = gamesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));

      final results = await Future.wait(files.map((file) async {
        try {
          final content = await file.readAsString();
          return (file.uri.pathSegments.last, Game.fromJson(jsonDecode(content)));
        } catch (e) {
          debugPrint('Error loading game file ${file.path}: $e');
          return null;
        }
      }));

      for (final (filename, game) in results.nonNulls) {
        loadedGames[game.internalId] = game;
        _gameFiles[game.internalId] = filename;
        // Reanudar pendientes que fallaron por red (Prioridad normal)
        if (game.idSteam != null) {
          _steamIdToInternalId[game.idSteam!] = game.internalId;
          if (!game.hasFetchedSteam) _enqueueForSteam(game.idSteam!);
          if (!game.hasFetchedHltb) _enqueueForHltb(game.idSteam!);
        }
      }
    }

    _gamesById.addAll(loadedGames);

    final file = await _localFile;
    HomeState newState = state;

    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded case {'settings': Map<String, dynamic> settings}) {
          newState = state.copyWith(
            visibleLanguages: _parseEnumSet(GameLanguage.values, settings['visibleLanguages']),
            visibleSpTypes: _parseEnumSet(SpType.values, settings['visibleSpTypes']),
            visibleVrTypes: _parseEnumSet(VrSupport.values, settings['visibleVrTypes']),
            includeSoftware: settings['includeSoftware'] as bool?,
            binaryFormat: settings['binaryFormat'] as bool?,
            matchmakingFilter: TriFilter.values.byNameOrNull(settings['matchmakingFilter'] as String?),
            matchmakingExperience: ExperienceFilter.values.byNameOrNull(settings['matchmakingExperience'] as String?),
            friendPlayFilter: TriFilter.values.byNameOrNull(settings['friendPlayFilter'] as String?),
            friendPlayExperience: ExperienceFilter.values.byNameOrNull(settings['friendPlayExperience'] as String?),
            achievementsFilter: TriFilter.values.byNameOrNull(settings['achievementsFilter'] as String?),
            steamCloudFilter: TriFilter.values.byNameOrNull(settings['steamCloudFilter'] as String?),
            priceFilter: TriFilter.values.byNameOrNull(settings['priceFilter'] as String?),
            geforceNowFilter: TriFilter.values.byNameOrNull(settings['geforceNowFilter'] as String?),
            sliderDistribution: SliderDistribution.values.byNameOrNull(settings['sliderDistribution'] as String?),
            sortBy: settings['sortBy'] as String?,
            sortAsc: settings['sortAsc'] as bool?,
            groupByStatus: settings['groupByStatus'] as bool?,
            statusFilters: _parseStatusFilters(settings['statusFilters']),
            esDePath: settings['esDePath'] as String?,
            currentMinBytes: (settings['currentMinBytes'] as num?)?.toDouble(),
            currentMaxBytes: (settings['currentMaxBytes'] as num?)?.toDouble(),
            filterProfiles: _parseFilterProfiles(settings['filterProfiles']),
          );
        }
      } catch (e) {
        debugPrint('Error al cargar estado local: $e');
      }
    }

    newState = _applyFilters(_updateLimits(newState));
    emit(newState);

    _startSteamQueue();
    _startHltbQueue();

    final gfnFile = await _gfnLocalFile;
    if (!await gfnFile.exists()) {
      fetchGeforceNowDatabase();
    } else {
      _startGfnComparisonQueue();
    }
  }

  Future<void> _saveLocalState(HomeState currentState) async {
    final file = await _localFile;
    await file.writeAsString(jsonEncode({'settings': _extractFilters(currentState)}));
  }

  // ─── NÚCLEO DE PARCHEO ───

  /// [1] Actualiza solo la tabla de verdad en memoria. Sin I/O, sin emit.
  void _updateGameInMemory(Game game, Map<String, dynamic> patch) {
    if (patch.isEmpty) return;
    _gamesById[game.internalId] = game.updateFromJson(patch);
  }

  /// [2] Escritura a disco fire-and-forget, serializada por archivo.
  /// Las writes al mismo internalId se encadenan (nunca solapan).
  /// Las writes a archivos distintos corren en paralelo de forma natural.
  void _writeToDisk(String internalId, Map<String, dynamic> patch) {
    if (internalId.isEmpty) return;
    final prev = _writeChain[internalId] ?? Future<void>.value();
    _writeChain[internalId] = prev.then((_) => _doWriteToDisk(internalId, patch));
  }

  Future<void> _doWriteToDisk(String internalId, Map<String, dynamic> patch) async {
    try {
      String? filename = _gameFiles[internalId];
      if (filename == null) {
        filename = '${const Uuid().v4()}.json';
        _gameFiles[internalId] = filename;
      }
      final dir = await _gamesDir;
      final file = File('${dir.path}/$filename');
      Map<String, dynamic> jsonToSave;
      if (await file.exists()) {
        try {
          jsonToSave = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          jsonToSave.addAll(patch);
        } catch (_) {
          jsonToSave = _gamesById[internalId]?.toJson() ?? patch;
        }
      } else {
        jsonToSave = _gamesById[internalId]?.toJson() ?? patch;
      }
      await file.writeAsString(jsonEncode(jsonToSave));
    } catch (e) {
      debugPrint('Disk write error [$internalId]: $e');
    }
  }

  /// [3a] Para workers de cola: actualiza memoria + dispara write a disco. Sin emit.
  /// Permite acumular N cambios antes de emitir una sola vez.
  void _applyQueuePatch(Game game, Map<String, dynamic> patch) {
    if (patch.isEmpty) return;
    _updateGameInMemory(game, patch);
    _writeToDisk(game.internalId, patch);
  }

  /// [3b] Para operaciones inmediatas de UI: memoria + emit + disco.
  /// Cada llamada produce exactamente un emit y una write encadenada.
  void _patchGame(Game game, Map<String, dynamic> patch) {
    if (patch.isEmpty) return;
    _updateGameInMemory(game, patch);
    emit(_applyFilters(state));
    _writeToDisk(game.internalId, patch);
  }

  /// Equivalente full write (usado solo al importar masivamente o modificaciones de interfaz)
  Future<void> _saveGameLocally(Game game) async {
    final id = game.internalId;
    if (id.isEmpty) return;
    String? filename = _gameFiles[id];
    if (filename == null) {
      filename = '${const Uuid().v4()}.json';
      _gameFiles[id] = filename;
    }
    final dir = await _gamesDir;
    await File('${dir.path}/$filename').writeAsString(jsonEncode(game.toJson()));
  }

  // ─── IMPORTACIÓN / EXPORTACIÓN ───

  String exportGamesJson() {
    if (_gamesById.isEmpty) return '[]';
    final sorted = _gamesById.values.toList()
      ..sort((a, b) => _compareCustom(a.name ?? '', b.name ?? ''));
    final buffer = StringBuffer('[');
    for (int i = 0; i < sorted.length; i++) {
      buffer.write('\n  ${jsonEncode(sorted[i].toJson())}');
      if (i < sorted.length - 1) buffer.write(',');
    }
    buffer.write('\n]');
    return buffer.toString();
  }

  Future<void> processJson(String jsonString, {required bool replace}) async {
    switch (jsonDecode(jsonString)) {
      case {'games': List gamesList}:
        await _processGamesList(gamesList, replace: replace);
      case List gamesList:
        await _processGamesList(gamesList, replace: replace);
    }
  }

  /// Importa una lista de juegos: con `replace=true` borra todos los datos existentes primero.
  /// En modo merge actualiza por `internalId`; juegos desconocidos se añaden, conocidos se fusionan.
  /// Escribe a disco en lotes paralelos de 50 para no saturar el filesystem.
  Future<void> _processGamesList(List<dynamic> rawList, {required bool replace}) async {
    if (replace) {
      final gamesDir = await _gamesDir;
      if (await gamesDir.exists()) {
        for (final f in gamesDir.listSync().whereType<File>()) {
          if (f.path.endsWith('.json')) await f.delete();
        }
      }
      _gameFiles.clear();
      _steamQueue.clear();
      _hltbQueue.clear();
      _gamesById.clear();
      _steamIdToInternalId.clear();
      _sizeCache = null;
    }

    final Map<String, Game> newAllGames = Map.from(_gamesById);
    final gamesToSave = <Game>[];

    // Acumular en variables locales para evitar un segundo recorrido O(N) dentro de _updateLimits.
    var cMin = _sizeCache?.min ?? double.infinity;
    var cMax = _sizeCache?.max ?? double.negativeInfinity;

    for (final rawGame in rawList.whereType<Map<String, dynamic>>()) {
      final steamId = rawGame['id_steam'];
      final gameName = rawGame['name']?.toString();
      if (steamId == null && (gameName == null || gameName.trim().isEmpty)) continue;

      final g = Game.fromJson(rawGame);
      if (replace || !newAllGames.containsKey(g.internalId)) {
        newAllGames[g.internalId] = g;
      } else {
        newAllGames[g.internalId] = newAllGames[g.internalId]!.updateFromJson(rawGame);
      }
      final finalGame = newAllGames[g.internalId]!;
      gamesToSave.add(finalGame);

      // Actualización incremental de la caché para evitar un segundo scan O(N).
      final size = finalGame.sizeInBytes;
      if (size < cMin) cMin = size;
      if (size > cMax) cMax = size;
    }

    if (gamesToSave.isNotEmpty) _sizeCache = (min: cMin, max: cMax);

    _gamesById.addAll(newAllGames);
    for (final g in newAllGames.values) {
      if (g.idSteam != null) _steamIdToInternalId[g.idSteam!] = g.internalId;
    }
    for (final g in gamesToSave) {
      if (g.idSteam != null) {
        if (!g.hasFetchedSteam) _enqueueForSteam(g.idSteam!);
        if (!g.hasFetchedHltb) _enqueueForHltb(g.idSteam!);
      }
    }

    final newState = _applyFilters(_updateLimits(state));
    emit(newState);
    await _saveLocalState(newState);

    // Writes paralelas en lotes de 50 para no saturar el filesystem
    const batchSize = 50;
    for (int i = 0; i < gamesToSave.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, gamesToSave.length);
      await Future.wait(gamesToSave.sublist(i, end).map(_saveGameLocally));
      if (end < gamesToSave.length) await Future.delayed(Duration.zero);
    }

    _startSteamQueue();
    _startHltbQueue();
    _startGfnComparisonQueue();
  }

  // ─── GEFORCE NOW API & DB QUEUE ───

  /// Descarga el catálogo completo de GeForce NOW via GraphQL paginado y lo persiste en `gfn_db.json`.
  /// Marca todos los juegos como pendientes de comparación y dispara `_startGfnComparisonQueue`.
  Future<void> fetchGeforceNowDatabase() async {
    if (state.isFetchingGfnDb) return;
    emit(state.copyWith(isFetchingGfnDb: true));

    try {
      final client = HttpClient();
      String afterValue = '';
      bool hasNextPage = true;
      final Set<int> steamIdsInGfn = {};

      while (hasNextPage) {
        final request = await client.postUrl(Uri.parse('https://api-prod.nvidia.com/services/gfngames/v1/gameList'));
        request.headers..set('Content-Type', 'application/json')
          ..set('Accept', 'application/json');
        request.write('''
        {
          apps(country: "US", language: "en_US", after: "$afterValue") {
            pageInfo { hasNextPage endCursor }
            items { variants { appStore storeId } }
          }
        }
        ''');

        final response = await request.close();
        if (response.statusCode != 200) break;

        final data = jsonDecode(await response.transform(utf8.decoder).join())?['data']?['apps'];
        if (data == null) break;

        hasNextPage = data['pageInfo']?['hasNextPage'] as bool? ?? false;
        afterValue = data['pageInfo']?['endCursor'] as String? ?? '';

        for (final item in (data['items'] as List? ?? [])) {
          for (final variant in (item['variants'] as List? ?? [])) {
            if (variant['appStore']?.toString().toUpperCase() case 'STEAM' || '11') {
              final storeId = int.tryParse(variant['storeId']?.toString() ?? '');
              if (storeId != null) steamIdsInGfn.add(storeId);
            }
          }
        }
      }
      client.close();

      if (steamIdsInGfn.isNotEmpty) {
        await (await _gfnLocalFile).writeAsString(jsonEncode(steamIdsInGfn.toList()));
        // Solo memoria: _startGfnComparisonQueue escribirá los valores correctos al disco.
        for (final id in _gamesById.keys.toList()) {
          _gamesById[id] = _gamesById[id]!.updateFromJson({'has_fetched_gfn': false});
        }
        emit(_applyFilters(state));
        _startGfnComparisonQueue();
      }
    } catch (e) {
      debugPrint('Error obteniendo GFN DB: $e');
    }

    emit(state.copyWith(isFetchingGfnDb: false));
  }

  /// Compara cada juego con `hasFetchedGfn=false` contra el catálogo local de GFN,
  /// aplica todos los parches en un único emit y los persiste en lotes paralelos cediendo
  /// el event loop entre cada lote.
  Future<void> _startGfnComparisonQueue() async {
    if (_isGfnQueueRunning) return;
    final file = await _gfnLocalFile;
    if (!await file.exists()) return;
    _isGfnQueueRunning = true;

    try {
      final gfnSteamIds = (jsonDecode(await file.readAsString()) as List)
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .toSet();

      final pendingPatches = <String, Map<String, dynamic>>{
        for (final g in _gamesById.values.where((g) => !g.hasFetchedGfn))
          g.internalId: {
            'is_geforce_now': g.idSteam != null ? gfnSteamIds.contains(g.idSteam) : g.isGeforceNow,
            'has_fetched_gfn': true
          },
      };

      if (pendingPatches.isNotEmpty) {
        for (final entry in pendingPatches.entries) {
          final g = _gamesById[entry.key];
          if (g != null) _gamesById[entry.key] = g.updateFromJson(entry.value);
        }
        emit(_applyFilters(state));

        final dir = await _gamesDir;
        final patchList = pendingPatches.entries.toList();
        const batchSize = 50;
        for (int i = 0; i < patchList.length; i += batchSize) {
          final end = (i + batchSize).clamp(0, patchList.length);
          await Future.wait(patchList.sublist(i, end).map((entry) async {
            final filename = _gameFiles[entry.key];
            if (filename == null) return;
            final gFile = File('${dir.path}/$filename');
            Map<String, dynamic> jsonToSave;
            if (await gFile.exists()) {
              try {
                jsonToSave = jsonDecode(await gFile.readAsString()) as Map<String, dynamic>;
                jsonToSave.addAll(entry.value);
              } catch (_) {
                jsonToSave = _gamesById[entry.key]?.toJson() ?? entry.value;
              }
            } else {
              jsonToSave = _gamesById[entry.key]?.toJson() ?? entry.value;
            }
            await gFile.writeAsString(jsonEncode(jsonToSave));
          }));
          // Ceder el event loop entre lotes para que Flutter pueda renderizar frames
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      debugPrint('Error en cola de comparación GFN: $e');
    }

    _isGfnQueueRunning = false;
  }

  // ─── COLA DE STEAM API ───

  void _enqueueForSteam(int id, {bool priority = false}) {
    _steamQueue.remove(id);
    priority ? _steamQueue.insert(0, id) : _steamQueue.add(id);
  }

  /// Procesa la cola de Steam de forma secuencial: obtiene metadatos via `GetItems/v1`,
  /// aplica el parche con `_buildSteamPatch` y espera 1.5 s entre llamadas.
  /// Un 429 re-encola el ID actual y pausa 60 s antes de continuar.
  Future<void> _startSteamQueue() async {
    if (_isSteamQueueRunning) return;
    _isSteamQueueRunning = true;
    emit(state.copyWith(steamQueueSize: _steamQueue.length));

    final client = HttpClient();

    while (_steamQueue.isNotEmpty) {
      final idSteam = _steamQueue.removeAt(0);
      final internalId = _steamIdToInternalId[idSteam];
      final game = internalId != null ? _gamesById[internalId] : null;
      if (game == null) continue;

      final isRefetch = game.hasFetchedSteam;
      final needsFetch = isRefetch ||
          game.name == null ||
          game.isSoftware == null ||
          game.isFree == null ||
          game.hasSpanish == null ||
          game.spType == null ||
          game.hasSteamCloud == null ||
          game.vrSupport == null ||
          game.matchmaking == null ||
          game.friendPlay == null ||
          game.hasAchievements == null;

      if (!needsFetch) {
        _applyQueuePatch(game, {'has_fetched_steam': true});
        emit(_applyFilters(state.copyWith(steamQueueSize: _steamQueue.length)));
        continue;
      }

      try {
        final inputJson = jsonEncode({
          'context': {'language': 'spanish', 'country_code': 'US'},
          'data_request': {'include_basic_info': true, 'include_supported_languages': true},
          'ids': [{'appid': idSteam}],
        });
        final uri = Uri.parse('https://api.steampowered.com/IStoreBrowseService/GetItems/v1?input_json=${Uri.encodeComponent(inputJson)}');
        final response = await (await client.getUrl(uri)).close();

        if (response.statusCode == 200) {
          final payload = jsonDecode(await response.transform(utf8.decoder).join());
          final storeItems = payload['response']?['store_items'];
          if (storeItems is List && storeItems.isNotEmpty) {
            final item = storeItems.first as Map<String, dynamic>;
            // Otro worker pudo haber actualizado el juego mientras esperábamos la respuesta.
            final freshGame = _gamesById[internalId] ?? game;
            if (item['success'] == 1) {
              _applyQueuePatch(freshGame, _buildSteamPatch(freshGame, item, isRefetch));
            } else {
              _applyQueuePatch(freshGame, {'has_fetched_steam': true});
            }
          } else {
            _applyQueuePatch(game, {'has_fetched_steam': true});
          }
        } else if (response.statusCode == 429) {
          await response.drain();
          _steamQueue.insert(0, idSteam);
          emit(state.copyWith(steamQueueSize: _steamQueue.length));
          await Future.delayed(const Duration(seconds: 60));
          continue;
        } else {
          await response.drain();
          _applyQueuePatch(game, {'has_fetched_steam': true});
        }
      } catch (e) {
        debugPrint('Steam API error de red: $e');
        emit(state.copyWith(steamQueueSize: 0));
        break;
      }

      emit(_applyFilters(state.copyWith(steamQueueSize: _steamQueue.length)));
      await Future.delayed(const Duration(milliseconds: 1500));
    }

    client.close();
    _isSteamQueueRunning = false;
    emit(_applyFilters(state.copyWith(steamQueueSize: 0)));
  }

  /// Construye el parche Steam a partir de la respuesta de la API. Sin efectos secundarios.
  /// El caller decide si hace emit y cuándo (permite batching en la cola).
  Map<String, dynamic> _buildSteamPatch(Game game, Map<String, dynamic> item, bool isRefetch) {
    final patch = <String, dynamic>{'has_fetched_steam': true};

    final name = item['name']?.toString();
    if (name != null && (game.name == null || Game.normalizeIdName(game.name) == Game.normalizeIdName(name))) patch['name'] = name;

    if (item['type'] is int) patch['is_software'] = isRefetch ? (item['type'] != 0) : (game.isSoftware ?? (item['type'] != 0));

    final isFree = item['is_free'] as bool?;
    if (isFree != null) patch['is_free'] = isRefetch ? isFree : (game.isFree ?? isFree);

    // Idiomas: array estructurado con elanguage (int). elanguage==5 = Español (España).
    final supportedLangs = item['supported_languages'] as List?;
    if (supportedLangs != null) {
      final hasSpanish = supportedLangs.any((l) => l is Map && l['elanguage'] == 5 && l['supported'] == true);
      patch['has_spanish'] = isRefetch ? hasSpanish : (game.hasSpanish ?? hasSpanish);
    }

    // Categorías: la nueva API las divide en dos sub-arrays; combinamos ambos.
    final catObj = item['categories'];
    final catIds = <int>{
      ...(catObj?['supported_player_categoryids'] as List?)?.whereType<int>() ?? [],
      ...(catObj?['feature_categoryids'] as List?)?.whereType<int>() ?? []
    };

    if (catIds.isNotEmpty) {
      final detectedVr = switch (catIds) {
        _ when catIds.contains(54) => VrSupport.only, // 54: VR Only
        _ when catIds.contains(31) || catIds.contains(53) => VrSupport.yes, // 31: VR Support, 53: VR Supported
        _ => VrSupport.no,
      };
      if (game.vrSupport != VrSupport.mod || isRefetch) {
        patch['vr_support'] = isRefetch && game.vrSupport == VrSupport.mod ? VrSupport.mod.name : detectedVr.name;
      } else if (game.vrSupport == null) {
        patch['vr_support'] = detectedVr.name;
      }

      final spType = catIds.contains(2) ? SpType.native : SpType.none; // 2: Single-player
      if (game.spType != SpType.simulated || isRefetch) {
        patch['sp_type'] = isRefetch && game.spType == SpType.simulated ? SpType.simulated.name : spType.name;
      } else if (game.spType == null) {
        patch['sp_type'] = spType.name;
      }

      final hasCloud = catIds.contains(23); // 23: Steam Cloud
      patch['has_steam_cloud'] = isRefetch ? hasCloud : (game.hasSteamCloud ?? hasCloud);
      final hasAch = catIds.contains(22); // 22: Steam Achievements
      patch['has_achievements'] = isRefetch ? hasAch : (game.hasAchievements ?? hasAch);

      final hasPvpGeneric = catIds.contains(36) || catIds.contains(49); // 36: Online PvP, 49: PvP
      final hasCoopGeneric = catIds.contains(9) || catIds.contains(38); // 9: Co-op, 38: Online Co-op
      // 1: Multi-player, 20: MMO, 27: Cross-Platform
      final isGenericOnline = catIds.contains(1) || catIds.contains(20) || catIds.contains(27);

      if (hasPvpGeneric || hasCoopGeneric || isGenericOnline) {
        final infMm = switch ((hasPvpGeneric, hasCoopGeneric)) {
          (true, true) => InteractionType.both,
          (true, false) => InteractionType.pvp,
          (false, true) => InteractionType.coop,
          (false, false) => InteractionType.both,
        };
        if (game.matchmaking == null) patch['matchmaking'] = infMm.name;
      }

      final hasLocalPvp = catIds.contains(37) || catIds.contains(47); // 37: Shared PvP, 47: LAN PvP
      final hasLocalCoop = catIds.contains(39) || catIds.contains(48); // 39: Shared Co-op, 48: LAN Co-op
      final hasGenericLocal = catIds.contains(24) || catIds.contains(44); // 24: Shared Screen, 44: Remote Play Together

      if (hasLocalPvp || hasLocalCoop || hasGenericLocal) {
        final isPvp = hasLocalPvp || (hasGenericLocal && hasPvpGeneric);
        final isCoop = hasLocalCoop || (hasGenericLocal && hasCoopGeneric);
        final infFp = switch ((isPvp, isCoop)) {
          (true, true) => InteractionType.both,
          (true, false) => InteractionType.pvp,
          (false, _) => InteractionType.coop,
        };
        if (game.friendPlay == null) patch['friend_play'] = infFp.name;
      }
    }

    return patch;
  }

  // ─── COLA DE HLTB API ───

  void _enqueueForHltb(int id, {bool priority = false}) {
    _hltbQueue.remove(id);
    priority ? _hltbQueue.insert(0, id) : _hltbQueue.add(id);
  }

  /// Procesa la cola de HLTB de forma secuencial: delega en `HltbService.fetchGameStats`
  /// y aplica el parche resultante leyendo siempre la versión más fresca del juego en memoria.
  Future<void> _startHltbQueue() async {
    if (_isHltbQueueRunning) return;
    _isHltbQueueRunning = true;
    emit(state.copyWith(hltbQueueSize: _hltbQueue.length));

    while (_hltbQueue.isNotEmpty) {
      final idSteam = _hltbQueue.removeAt(0);
      final internalId = _steamIdToInternalId[idSteam];
      final game = internalId != null ? _gamesById[internalId] : null;
      if (game == null || (game.name == null && game.hltbStats?.id == null)) {
        emit(state.copyWith(hltbQueueSize: _hltbQueue.length));
        continue;
      }

      try {
        final fetchedData = await HltbService.fetchGameStats(
          game.name,
          game.hltbStats?.id,
          game.idSteam?.toString(),
          game.hasFetchedHltb,
        );
        // Steam pudo haber actualizado el juego mientras esperábamos la respuesta de HLTB.
        final freshGame = _gamesById[internalId] ?? game;
        _applyQueuePatch(freshGame, {
          'hltb_stats': fetchedData?.toJson(),
          'has_fetched_hltb': true,
        });
      } catch (e) {
        debugPrint('HLTB Error general: $e');
        emit(state.copyWith(hltbQueueSize: 0));
        break;
      }

      emit(_applyFilters(state.copyWith(hltbQueueSize: _hltbQueue.length)));
    }

    _isHltbQueueRunning = false;
    emit(_applyFilters(state.copyWith(hltbQueueSize: 0)));
  }

  // ─── RE-FETCH ───

  Future<void> refetchSteamAll() async {
    for (final g in _gamesById.values.where((g) => g.idSteam != null)) {
      _enqueueForSteam(g.idSteam!);
    }
    _startSteamQueue();
  }

  Future<void> refetchHltbAll() async {
    for (final g in _gamesById.values.where((g) => g.idSteam != null)) {
      _enqueueForHltb(g.idSteam!);
    }
    _startHltbQueue();
  }

  // ===============================================
  // RE-FETCH INDIVIDUAL (Prioridad Inmediata)
  // ===============================================
  Future<void> refetchSteamForGame(Game game) async {
    if (game.idSteam == null) return;
    _enqueueForSteam((_gamesById[game.internalId] ?? game).idSteam!, priority: true);
    _startSteamQueue();
  }

  Future<void> refetchGfnForGame(Game game) async {
    if (game.idSteam == null) return;
    _patchGame(_gamesById[game.internalId] ?? game, {'has_fetched_gfn': false});
    _startGfnComparisonQueue();
  }

  Future<void> refetchHltbForGame(Game game) async {
    if (game.idSteam == null) return;
    _enqueueForHltb((_gamesById[game.internalId] ?? game).idSteam!, priority: true);
    _startHltbQueue();
  }

  // ─── MÉTODOS DE INTERFAZ Y MUTACIÓN MANUAL ───

  void updateGameStatus(Game game, GameStatus newStatus) =>
      _patchGame(game, {'status': newStatus.name});

  void updateGameDetails(Game updatedGame, {Game? originalGame}) =>
      _patchGame(updatedGame, updatedGame.toJson());

  Future<void> clearJson() async {
    final file = await _localFile;
    if (await file.exists()) await file.delete();
    final gamesDir = await _gamesDir;
    if (await gamesDir.exists()) await gamesDir.delete(recursive: true);
    _gameFiles.clear();
    _gamesById.clear();
    _steamIdToInternalId.clear();
    _writeChain.clear();
    // Invalidar caché de rangos:  el catálogo quedó completamente vacío.
    _sizeCache = null;
    emit(state.copyWith(filteredGames: [], totalBytes: 0, gameCount: 0, currentMinBytes: 0, currentMaxBytes: 1, absoluteMinBytes: 0, absoluteMaxBytes: 1));
  }

  void updateRange(double minBytes, double maxBytes) {
    final minB = minBytes.clamp(state.absoluteMinBytes, state.absoluteMaxBytes);
    final maxB = maxBytes.clamp(minB, state.absoluteMaxBytes);
    final newState = _applyFilters(state.copyWith(currentMinBytes: minB, currentMaxBytes: maxB));
    emit(newState);
    _saveLocalState(newState);
  }

  void updateFlag({
    bool? software,
    bool? binary,
    String? sort,
    bool? asc,
    bool? groupByStatus,
    List<StatusEntry>? statusFilters,
    String? searchQuery,
    Set<GameLanguage>? visibleLanguages,
    Set<SpType>? visibleSpTypes,
    Set<VrSupport>? visibleVrTypes,
    TriFilter? matchmakingFilter,
    ExperienceFilter? matchmakingExperience,
    TriFilter? friendPlayFilter,
    ExperienceFilter? friendPlayExperience,
    TriFilter? achievementsFilter,
    TriFilter? steamCloudFilter,
    TriFilter? priceFilter,
    TriFilter? geforceNowFilter,
    SliderDistribution? sliderDistribution,
    String? esDePath,
  }) {
    var newState = state.copyWith(
      includeSoftware: software,
      binaryFormat: binary,
      sortBy: sort,
      sortAsc: asc,
      groupByStatus: groupByStatus,
      statusFilters: statusFilters,
      searchQuery: searchQuery,
      visibleLanguages: visibleLanguages,
      visibleSpTypes: visibleSpTypes,
      visibleVrTypes: visibleVrTypes,
      matchmakingFilter: matchmakingFilter,
      matchmakingExperience: matchmakingExperience,
      friendPlayFilter: friendPlayFilter,
      friendPlayExperience: friendPlayExperience,
      achievementsFilter: achievementsFilter,
      steamCloudFilter: steamCloudFilter,
      priceFilter: priceFilter,
      geforceNowFilter: geforceNowFilter,
      sliderDistribution: sliderDistribution,
      esDePath: esDePath,
    );
    if (binary != null) newState = _updateLimits(newState);
    newState = _applyFilters(newState);
    emit(newState);
    _saveLocalState(newState);
  }

  void toggleStatusFilter(GameStatus status, bool isEnabled) {
    updateFlag(statusFilters: [
      for (final e in state.statusFilters)
        (status: e.status, visible: e.status == status ? isEnabled : e.visible),
    ]);
  }

  void reorderStatus(int oldIndex, int newIndex) {
    final config = List<StatusEntry>.from(state.statusFilters);
    config.insert(newIndex, config.removeAt(oldIndex));
    updateFlag(statusFilters: config);
  }

  void toggleLanguageFilter(GameLanguage language, bool isEnabled) {
    final newLangs = Set<GameLanguage>.from(state.visibleLanguages);
    isEnabled ? newLangs.add(language) : newLangs.remove(language);
    updateFlag(visibleLanguages: newLangs);
  }

  void toggleSpTypeFilter(SpType type, bool isEnabled) {
    final newTypes = Set<SpType>.from(state.visibleSpTypes);
    isEnabled ? newTypes.add(type) : newTypes.remove(type);
    updateFlag(visibleSpTypes: newTypes);
  }

  void toggleVrFilter(VrSupport type, bool isEnabled) {
    final newTypes = Set<VrSupport>.from(state.visibleVrTypes);
    isEnabled ? newTypes.add(type) : newTypes.remove(type);
    updateFlag(visibleVrTypes: newTypes);
  }

  // ─── PERFILES DE FILTRO ───

  void saveFilterProfile(String name) {
    if (name.trim().isEmpty) return;
    final profiles = Map<String, Map<String, dynamic>>.from(state.filterProfiles);
    profiles[name.trim()] = _extractFilters(state);
    final newState = state.copyWith(filterProfiles: profiles);
    emit(newState);
    _saveLocalState(newState);
  }

  void loadFilterProfile(String name) {
    final profile = state.filterProfiles[name];
    if (profile == null) return;
    // Actualiza límites en O(1) usando la caché de rangos: el catálogo no cambió,
    // solo necesita recalcular el redondeo si el perfil cambia binaryFormat.
    final newState = _applyFilters(_updateLimits(_restoreFilters(state, profile)));
    emit(newState);
    _saveLocalState(newState);
  }

  void deleteFilterProfile(String name) {
    final profiles = Map<String, Map<String, dynamic>>.from(state.filterProfiles)..remove(name);
    final newState = state.copyWith(filterProfiles: profiles);
    emit(newState);
    _saveLocalState(newState);
  }

  // ─── MOTOR DE FILTRADO Y ORDENACIÓN ───

  /// Calcula los límites absolutos del slider de tamaño según todos los juegos en memoria.
  ///
  /// Estrategia de caché (`_sizeCache`):
  ///   · Inicialmente null → Escaneo O(N) obligatorio para poblarla.
  ///   · Válida → Operación O(1) que calcula los redondeos de unidad (MB/GiB...).
  ///
  /// Si el rango seleccionado por el usuario está en su valor inicial (0-1), se expande
  /// a los nuevos límites; si ya fue ajustado, se preserva adaptándolo al nuevo rango.
  HomeState _updateLimits(HomeState s) {
    if (_gamesById.isEmpty) {
      _sizeCache = null;
      return s.copyWith(absoluteMinBytes: 0, absoluteMaxBytes: 1, currentMinBytes: 0, currentMaxBytes: 1);
    }

    // Scan O(N) solo cuando la caché está invalidada.
    if (_sizeCache == null) {
      var minB = double.infinity;
      var maxB = double.negativeInfinity;
      for (final g in _gamesById.values) {
        final size = g.sizeInBytes;
        if (size < minB) minB = size;
        if (size > maxB) maxB = size;
      }
      _sizeCache = (min: minB, max: maxB);
    }

    final (:min, :max) = _sizeCache!;
    final minDivisor = _getUnitDivisor(min, s.binaryFormat);
    final absMin = (min / minDivisor).floor() * minDivisor;
    final maxDivisor = _getUnitDivisor(max, s.binaryFormat);
    var absMax = (max / maxDivisor).ceil() * maxDivisor;
    if (absMin == absMax) absMax += maxDivisor;

    final isInitialRange = s.currentMinBytes == 0 && s.currentMaxBytes <= 1;
    final cMin = isInitialRange ? absMin : s.currentMinBytes.clamp(absMin, absMax);
    final cMax = isInitialRange ? absMax : s.currentMaxBytes.clamp(cMin, absMax);

    return s.copyWith(
      absoluteMinBytes: absMin,
      absoluteMaxBytes: absMax,
      currentMinBytes: cMin,
      currentMaxBytes: cMax,
    );
  }

  // ─── ALGORITMOS DE NORMALIZACIÓN Y COMPARACIÓN ───

  static String _normalizeForSort(String text) => HltbService.removeDiacritics(text).toLowerCase().replaceAll('.', '');

  static int _compareCustom(String a, String b) => _normalizeForSort(a).compareTo(_normalizeForSort(b));

  static bool _matchSearchTitle(String title, String query) {
    if (query.trim().isEmpty) return true;
    final parts = HltbService.removeDiacritics(query).trim().split(RegExp(r' +')).map(RegExp.escape);
    return RegExp(parts.join(r'\s+'), caseSensitive: false)
        .hasMatch(HltbService.removeDiacritics(title));
  }

  /// DRY para los filtros de interacción (matchmaking y friendPlay).
  static bool _matchesInteraction(InteractionType? actual, TriFilter filter, ExperienceFilter exp) {
    if (filter == TriFilter.yes && (actual == null || actual == InteractionType.none)) return false;
    if (filter == TriFilter.no && actual != null && actual != InteractionType.none) return false;
    if (filter != TriFilter.no && exp != ExperienceFilter.any) {
      if (actual == null || actual == InteractionType.none) return false;
      return switch (exp) {
        ExperienceFilter.coop => actual == InteractionType.coop || actual == InteractionType.both,
        ExperienceFilter.pvp  => actual == InteractionType.pvp  || actual == InteractionType.both,
        ExperienceFilter.both => actual == InteractionType.both,
        ExperienceFilter.any  => true,
      };
    }
    return true;
  }

  HomeState _applyFilters(HomeState s) {
    var filtered = _gamesById.values.where((g) {
      if (!_matchSearchTitle(g.name ?? '', s.searchQuery)) return false;
      if (!s.includeSoftware && g.isSoftware == true) return false;
      if (g.spType != null && !s.visibleSpTypes.contains(g.spType)) return false;
      if (g.vrSupport != null && !s.visibleVrTypes.contains(g.vrSupport)) return false;
      if (!_matchesInteraction(g.matchmaking, s.matchmakingFilter, s.matchmakingExperience)) return false;
      if (!_matchesInteraction(g.friendPlay, s.friendPlayFilter, s.friendPlayExperience)) return false;
      if (s.steamCloudFilter == TriFilter.yes && g.hasSteamCloud != true) return false;
      if (s.steamCloudFilter == TriFilter.no && g.hasSteamCloud == true) return false;
      if (s.achievementsFilter == TriFilter.yes && g.hasAchievements != true) return false;
      if (s.achievementsFilter == TriFilter.no && g.hasAchievements == true) return false;
      if (s.priceFilter == TriFilter.yes && g.isFree != true) return false;
      if (s.priceFilter == TriFilter.no && g.isFree == true) return false;
      if (s.geforceNowFilter == TriFilter.yes && g.isGeforceNow != true) return false;
      if (s.geforceNowFilter == TriFilter.no && g.isGeforceNow == true && g.language != GameLanguage.patched) return false;
      if (!s.visibleLanguages.contains(g.language)) return false;
      if (!s.visibleStatuses.contains(g.status)) return false;
      if (g.sizeInBytes < s.currentMinBytes || g.sizeInBytes > s.currentMaxBytes) return false;
      return true;
    }).toList();

    final totalBytes = filtered.fold<double>(0.0, (sum, g) => sum + g.sizeInBytes);

    if (s.groupByStatus) {
      final orderedVisible = [
        for (final (:status, :visible) in s.statusFilters)
          if (visible) status,
      ];
      final grouped = <GameStatus, List<Game>>{
        for (final st in orderedVisible) st: [],
      };
      for (final g in filtered) {
        grouped[g.status]?.add(g);
      }
      for (final group in grouped.values) {
        _sortGames(group, s);
      }
      filtered = [for (final st in orderedVisible) ...grouped[st]!];
    } else {
      _sortGames(filtered, s);
    }

    return s.copyWith(filteredGames: filtered, totalBytes: totalBytes, gameCount: _gamesById.length);
  }

  void _sortGames(List<Game> list, HomeState s) {
    if (s.sortBy == 'name') {
      list.sort((a, b) => s.sortAsc
          ? _compareCustom(a.name ?? '', b.name ?? '')
          : _compareCustom(b.name ?? '', a.name ?? ''));
    } else if (s.sortBy case 'hltbMain' || 'hltbExtras' || 'hltbComplete') {
      double? getVal(Game g) {
        final stats = g.hltbStats;
        if (stats == null) return null;
        final v = switch (s.sortBy) {
          'hltbMain' => stats.mainStory.average,
          'hltbExtras' => stats.extras.average,
          _ => stats.completionist.average,
        };
        return v > 0 ? v : null;
      }
      list.sort((a, b) {
        final aVal = getVal(a);
        final bVal = getVal(b);
        return switch ((aVal, bVal)) {
          (final double a, final double b) => s.sortAsc ? a.compareTo(b) : b.compareTo(a),
          (null, null) => 0,
          (null, _)    => 1,
          (_, null)    => -1,
        };
      });
    } else {
      list.sort((a, b) => s.sortAsc
          ? a.sizeInBytes.compareTo(b.sizeInBytes)
          : b.sizeInBytes.compareTo(a.sizeInBytes));
    }
  }

  double _getUnitDivisor(double bytes, bool isBinary) {
    final gb = isBinary ? 1073741824.0 : 1000000000.0;
    final mb = isBinary ? 1048576.0 : 1000000.0;
    return bytes >= gb ? gb : mb;
  }

  static String formatBytes(double bytes, bool isBinary) => switch ((isBinary, bytes >= (isBinary ? 1073741824 : 1000000000))) {
    (true, true) => '${(bytes / 1073741824).toStringAsFixed(2)} GiB',
    (true, false) => '${(bytes / 1048576).toStringAsFixed(2)} MiB',
    (false, true) => '${(bytes / 1000000000).toStringAsFixed(2)} GB',
    (false, false) => '${(bytes / 1000000).toStringAsFixed(2)} MB',
  };
}
