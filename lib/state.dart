import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'hltb_service.dart';
import 'model.dart';
import 'pcgw_service.dart';
import 'steam_service.dart';

enum TriFilter {
  all,
  yes,
  no;

  /// Si un valor pasa el filtro; `null` cuenta como "no".
  bool admits(bool? value) => switch (this) {
    all => true,
    yes => value == true,
    no => value != true,
  };
}

enum SliderDistribution { discrete, quadratic, cubic }
enum ExperienceFilter { any, coop, pvp, both }

enum SortBy {
  name,
  size,
  hltbMain,
  hltbExtras,
  hltbComplete;

  /// En db.json y en los perfiles el tamaño aparece también como 'peso'.
  static SortBy? parse(String? name) => name == 'peso' ? size : values.byNameOrNull(name);
}

typedef StatusEntry = ({GameStatus status, bool visible});

// ─── IMPORTACIÓN: TIPOS DE RESULTADO ───

/// Plan inmutable de una importación ya analizada: la carga validada (deduplicada
/// por internalId) más el recuento de efectos. Permite mostrar cifras exactas en la
/// confirmación y luego aplicarla SIN volver a parsear ni recalcular.
final class ImportPlan({
  /// internalId → entrada cruda validada del JSON, en orden de aparición.
  /// Ante duplicados dentro del propio archivo, se conserva el último (last-wins).
  required final Map<String, Map<String, dynamic>> byId,

  /// Entradas cuyo internalId aún no existe en la biblioteca.
  required final int added,

  /// Entradas cuyo internalId ya existe (se actualizarán o se sobrescribirán).
  required final int merged,

  /// Juegos que se eliminarán: la biblioteca actual completa cuando [replace]; si no, 0.
  required final int deleted,

  /// Borrar toda la biblioteca antes de importar.
  required final bool replace,

  /// En modo merge, conservar las propiedades ausentes de los juegos coincidentes.
  required final bool preserveExisting,
}) {
  /// Total de entradas válidas y únicas que entrarán.
  int get incoming => byId.length;

  /// ¿La operación destruye datos que el usuario ya tenía?
  ///  · replace                              → borra la biblioteca entera.
  ///  · merge sin preservar, con coincidencias → reinicia las propiedades ausentes
  ///    del JSON en los juegos que ya existían.
  bool get isDestructive =>
      (replace && deleted > 0) || (!replace && !preserveExisting && merged > 0);
}

/// Resultado sellado de [HomeCubit.analyzeImport]. Modela las tres únicas situaciones
/// posibles para que la vista las trate de forma exhaustiva (switch sin `default`),
/// en lugar de propagar `null` o banderas sueltas.
sealed class ImportAnalysis {
  const ImportAnalysis();
}

/// El texto no es JSON válido, o no es una lista / objeto `{"games": [...]}`.
final class InvalidImport extends ImportAnalysis {
  const InvalidImport();
}

/// JSON válido pero sin ninguna entrada con `id_steam` o `name` utilizable.
final class EmptyImport extends ImportAnalysis {
  const EmptyImport();
}

/// Importación lista para confirmar y aplicar; [plan] lleva la carga ya validada.
final class ReadyImport extends ImportAnalysis {
  final ImportPlan plan;
  const ReadyImport(this.plan);
}

// ─── STEAM: RESULTADO DE SINCRONIZACIÓN ───

/// Resultado sellado de [HomeCubit.syncSteamLibrary], para que la vista componga el
/// mensaje sin inspeccionar banderas sueltas.
sealed class SteamSync {
  const SteamSync();
}

final class SteamSyncDone({
  /// Juegos de la cuenta que no estaban en la biblioteca.
  required final int added,

  /// Juegos de la cuenta que ya estaban (conservan sus datos locales).
  required final int updated,
}) extends SteamSync;

final class SteamSyncFailed extends SteamSync {
  final SteamFailure reason;
  const SteamSyncFailed(this.reason);
}

// ─── ESTADO ───

class HomeState({
  final List<Game> filteredGames = const [],
  final int gameCount = 0,
  final double totalBytes = 0,

  // True hasta que _loadLocalState termina la primera carga desde disco.
  // Distingue "cargando" de "cargado y vacío" para la vista.
  final bool isLoading = true,

  // Estado de operaciones en segundo plano
  final bool isFetchingGfnDb = false,
  final int steamQueueSize = 0,
  final int hltbQueueSize = 0,
  final int pcgwQueueSize = 0,
  final bool isSyncingSteamLibrary = false,

  // Configuración y rutas
  final String? esDePath,
  final Map<String, Map<String, dynamic>> filterProfiles = const {},

  // Steam — cuenta vinculada (la API key vive solo en el cubit, nunca en el estado)
  final String? steamId,
  final String? steamPersona,
  final int? steamSyncedAt,
  final int steamCheckDays = SyncInterval.onOpen,
  final bool steamCheckByCalendar = false,

  // HLTB — ajustes de sincronización
  final int refreshIntervalDays = 30, // Días tras los cuales se re-consulta HLTB de cada juego.
  final bool hltbAutoRefreshOnDetail = false, // Consultar HLTB al abrir el detalle de un juego.
  final bool hltbRefreshByCalendar = false,

  // Ordenación
  final SortBy sortBy = SortBy.name,
  final bool sortAsc = true,
  final bool groupByStatus = false,
  required final List<StatusEntry> statusFilters,

  // Filtros — búsqueda y visibilidad
  final String searchQuery = '',
  final Set<GameLanguage> visibleLanguages = const {},
  final Set<SpType> visibleSpTypes = const {},
  final Set<VrSupport> visibleVrTypes = const {},
  final bool includeSoftware = false,
  final bool includeVrMods = true,
  final bool includeTranslations = true,

  // Filtros — características de juego
  final TriFilter friendPlayFilter = TriFilter.all,
  final ExperienceFilter friendPlayExperience = ExperienceFilter.any,
  final TriFilter matchmakingFilter = TriFilter.all,
  final ExperienceFilter matchmakingExperience = ExperienceFilter.any,
  final TriFilter achievementsFilter = TriFilter.all,
  final TriFilter steamCloudFilter = TriFilter.all,
  final TriFilter priceFilter = TriFilter.all,
  final TriFilter geforceNowFilter = TriFilter.all,
  final TriFilter steamOwnershipFilter = TriFilter.all,
  final TriFilter motionFilter = TriFilter.all,

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
  bool get isFetchingPcgw => pcgwQueueSize > 0;
  bool get isSyncing => isFetchingSteam || isFetchingGfnDb || isFetchingHltb || isFetchingPcgw || isSyncingSteamLibrary;
  bool get hasSteamAccount => steamId != null;

  /// Estados que el usuario mantiene visibles, en el orden que les dio.
  List<GameStatus> get visibleStatuses => [
    for (final (:status, :visible) in statusFilters) if (visible) status,
  ];

  HomeState copyWith({
    List<Game>? filteredGames,
    int? gameCount,
    double? totalBytes,
    bool? isLoading,
    bool? isFetchingGfnDb,
    int? steamQueueSize,
    int? hltbQueueSize,
    int? pcgwQueueSize,
    bool? isSyncingSteamLibrary,
    String? esDePath,
    Map<String, Map<String, dynamic>>? filterProfiles,
    String? steamId,
    String? steamPersona,
    int? steamSyncedAt,
    // Único camino para volver los campos de Steam a su valor por defecto: el `??`
    // del resto de copyWith no permite reasignar a null.
    bool resetSteam = false,
    int? steamCheckDays,
    bool? steamCheckByCalendar,
    int? refreshIntervalDays,
    bool? hltbAutoRefreshOnDetail,
    bool? hltbRefreshByCalendar,
    SortBy? sortBy,
    bool? sortAsc,
    bool? groupByStatus,
    List<StatusEntry>? statusFilters,
    String? searchQuery,
    Set<GameLanguage>? visibleLanguages,
    Set<SpType>? visibleSpTypes,
    Set<VrSupport>? visibleVrTypes,
    bool? includeSoftware,
    bool? includeVrMods,
    bool? includeTranslations,
    TriFilter? friendPlayFilter,
    ExperienceFilter? friendPlayExperience,
    TriFilter? matchmakingFilter,
    ExperienceFilter? matchmakingExperience,
    TriFilter? achievementsFilter,
    TriFilter? steamCloudFilter,
    TriFilter? priceFilter,
    TriFilter? geforceNowFilter,
    TriFilter? steamOwnershipFilter,
    TriFilter? motionFilter,
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
    isLoading: isLoading ?? this.isLoading,
    isFetchingGfnDb: isFetchingGfnDb ?? this.isFetchingGfnDb,
    steamQueueSize: steamQueueSize ?? this.steamQueueSize,
    hltbQueueSize: hltbQueueSize ?? this.hltbQueueSize,
    pcgwQueueSize: pcgwQueueSize ?? this.pcgwQueueSize,
    isSyncingSteamLibrary: isSyncingSteamLibrary ?? this.isSyncingSteamLibrary,
    esDePath: esDePath ?? this.esDePath,
    filterProfiles: filterProfiles ?? this.filterProfiles,
    steamId: resetSteam ? null : (steamId ?? this.steamId),
    steamPersona: resetSteam ? null : (steamPersona ?? this.steamPersona),
    steamSyncedAt: resetSteam ? null : (steamSyncedAt ?? this.steamSyncedAt),
    steamCheckDays: steamCheckDays ?? this.steamCheckDays,
    steamCheckByCalendar: steamCheckByCalendar ?? this.steamCheckByCalendar,
    refreshIntervalDays: refreshIntervalDays ?? this.refreshIntervalDays,
    hltbAutoRefreshOnDetail: hltbAutoRefreshOnDetail ?? this.hltbAutoRefreshOnDetail,
    hltbRefreshByCalendar: hltbRefreshByCalendar ?? this.hltbRefreshByCalendar,
    sortBy: sortBy ?? this.sortBy,
    sortAsc: sortAsc ?? this.sortAsc,
    groupByStatus: groupByStatus ?? this.groupByStatus,
    statusFilters: statusFilters ?? this.statusFilters,
    searchQuery: searchQuery ?? this.searchQuery,
    visibleLanguages: visibleLanguages ?? this.visibleLanguages,
    visibleSpTypes: visibleSpTypes ?? this.visibleSpTypes,
    visibleVrTypes: visibleVrTypes ?? this.visibleVrTypes,
    includeSoftware: includeSoftware ?? this.includeSoftware,
    includeVrMods: includeVrMods ?? this.includeVrMods,
    includeTranslations: includeTranslations ?? this.includeTranslations,
    friendPlayFilter: friendPlayFilter ?? this.friendPlayFilter,
    friendPlayExperience: friendPlayExperience ?? this.friendPlayExperience,
    matchmakingFilter: matchmakingFilter ?? this.matchmakingFilter,
    matchmakingExperience: matchmakingExperience ?? this.matchmakingExperience,
    achievementsFilter: achievementsFilter ?? this.achievementsFilter,
    steamCloudFilter: steamCloudFilter ?? this.steamCloudFilter,
    priceFilter: priceFilter ?? this.priceFilter,
    geforceNowFilter: geforceNowFilter ?? this.geforceNowFilter,
    steamOwnershipFilter: steamOwnershipFilter ?? this.steamOwnershipFilter,
    motionFilter: motionFilter ?? this.motionFilter,
    binaryFormat: binaryFormat ?? this.binaryFormat,
    sliderDistribution: sliderDistribution ?? this.sliderDistribution,
    absoluteMinBytes: absoluteMinBytes ?? this.absoluteMinBytes,
    absoluteMaxBytes: absoluteMaxBytes ?? this.absoluteMaxBytes,
    currentMinBytes: currentMinBytes ?? this.currentMinBytes,
    currentMaxBytes: currentMaxBytes ?? this.currentMaxBytes,
  );

  // Cubit solo emite cuando el estado cambia, así que la igualdad decide los rebuilds.
  // Las colecciones se comparan por contenido: la de juegos filtrados por identidad de
  // cada juego, que es como la vista decide si vuelve a construir la lista.
  List<Object?> get _props => [
    filteredGames, gameCount, totalBytes, isLoading, isFetchingGfnDb, steamQueueSize,
    hltbQueueSize, pcgwQueueSize, isSyncingSteamLibrary, esDePath, filterProfiles, steamId,
    steamPersona, steamSyncedAt, steamCheckDays, steamCheckByCalendar, refreshIntervalDays,
    hltbAutoRefreshOnDetail, hltbRefreshByCalendar, sortBy, sortAsc, groupByStatus,
    statusFilters, searchQuery, visibleLanguages, visibleSpTypes, visibleVrTypes,
    includeSoftware, includeVrMods, includeTranslations, friendPlayFilter, friendPlayExperience, matchmakingFilter,
    matchmakingExperience, achievementsFilter, steamCloudFilter, priceFilter,
    geforceNowFilter, steamOwnershipFilter, motionFilter, binaryFormat, sliderDistribution,
    absoluteMinBytes, absoluteMaxBytes, currentMinBytes, currentMaxBytes,
  ];

  static const _equality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HomeState && _equality.equals(other._props, _props);

  @override
  int get hashCode => _equality.hash(_props);
}

// ─── CUBIT ───

class HomeCubit extends Cubit<HomeState> {
  // Tabla de verdad en memoria: fuente canónica para todos los hilos de tarea.
  // Los workers de cola leen/escriben aquí directamente sin depender del snapshot de HomeState.
  final Map<String, Game> _gamesById = {};

  // Mapeo en memoria para relacionar cada juego (internalId) con su archivo físico .json UUID.
  final Map<String, String> _gameFiles = {};

  // Cadenas de escritura por archivo: serializa las writes al mismo archivo sin bloquear la cola.
  final Map<String, Future<void>> _writeChain = {};

  // Colas fire-and-forget: lista de internalIds pendientes + flag de worker activo.
  final List<String> _steamQueue = [];
  // Confirmación de logros: `GetItems` los omite en bastantes fichas y `appdetails`,
  // que sí los declara, solo acepta un appid por llamada.
  final List<String> _achievementsQueue = [];
  bool _isSteamQueueRunning = false;
  // Pedidos juego a juego desde la interfaz: van antes que la cola general.
  final List<String> _hltbPriorityQueue = [];
  // Ordenada por antigüedad de la última consulta; ver [_enqueueHltbByAge].
  final List<String> _hltbQueue = [];
  bool _isHltbQueueRunning = false;
  final List<String> _pcgwQueue = [];
  bool _isPcgwQueueRunning = false;
  bool _isGfnQueueRunning = false;
  // Pasada de GFN pedida mientras otra corría; `true` si debe revisar todos los juegos.
  bool? _gfnQueuedPass;
  ({Set<int> steamIds, Set<String> titleKeys})? _gfnCatalog;
  bool _isAutoSyncRunning = false;

  /// NVIDIA amplía el catálogo cada semana: refrescarlo antes rara vez aporta nada.
  static const Duration _gfnCatalogTtl = Duration(days: 7);

  /// Escrituras a disco simultáneas como máximo, para no saturar el sistema de archivos.
  static const int _writeBatchSize = 50;

  // Sin broadcast: retiene lo importado antes de que la vista llegue a suscribirse.
  final StreamController<SteamSync> _steamAutoSyncEvents = StreamController();

  /// Resultados de la importación automática de Steam que merecen aviso: juegos nuevos
  /// o un fallo que no se arregla solo (clave, privacidad). La red caída se calla.
  Stream<SteamSync> get steamAutoSyncEvents => _steamAutoSyncEvents.stream;

  // API key de Steam: fuera de HomeState para que no viaje en cada emit ni entre
  // en los perfiles de filtro. Se persiste junto al resto de la cuenta en db.json.
  String? _steamApiKey;

  HomeCubit() : super(HomeState(
    // Configuración inicial: todos los statuses visibles en el orden del enum.
    statusFilters: [for (final s in GameStatus.values) (status: s, visible: true)],
    visibleLanguages: GameLanguage.values.toSet(),
    visibleSpTypes: SpType.values.toSet(),
    visibleVrTypes: VrSupport.values.toSet(),
  )) {
    _loadLocalState();
  }

  Game? gameById(String id) => _gamesById[id];

  /// Clave guardada, para prerrellenar el formulario de vinculación.
  String? get steamApiKey => _steamApiKey;

  static int get _nowEpoch => DateTime.now().millisecondsSinceEpoch ~/ 1000;

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

  /// NOT late final: vaciar la biblioteca borra el directorio; hay que
  /// comprobar y recrearlo en cada acceso.
  Future<Directory> get _gamesDir async {
    final dir = Directory('${await _basePath}/games');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ─── AJUSTES: SERIALIZACIÓN ───

  static Set<T>? _parseEnumSet<T extends Enum>(Iterable<T> values, dynamic list) {
    if (list is! List) return null;
    final set = {for (final e in list) ?values.byNameOrNull(e?.toString())};
    return set.isEmpty ? null : set;
  }

  /// Parsea statusFilters desde JSON.
  /// Garantiza que todos los valores del enum estén presentes:
  /// los que falten en el JSON se añaden al final con visible=true.
  static List<StatusEntry>? _parseStatusFilters(dynamic raw) {
    if (raw is! List) return null;
    final parsed = <StatusEntry>[
      for (final e in raw)
        if (e case {'status': final String name, 'visible': final bool visible})
          if (GameStatus.values.byNameOrNull(name) case final status?) (status: status, visible: visible),
    ];
    if (parsed.isEmpty) return null;
    final seen = {for (final e in parsed) e.status};
    return [
      ...parsed,
      // Statuses añadidos al enum después del guardado quedan visibles al final
      for (final s in GameStatus.values)
        if (!seen.contains(s)) (status: s, visible: true),
    ];
  }

  static Map<String, dynamic> _extractFilters(HomeState s) => {
    'searchQuery': s.searchQuery,
    'visibleLanguages': [for (final e in s.visibleLanguages) e.name],
    'visibleSpTypes': [for (final e in s.visibleSpTypes) e.name],
    'visibleVrTypes': [for (final e in s.visibleVrTypes) e.name],
    'includeSoftware': s.includeSoftware,
    'includeVrMods': s.includeVrMods,
    'includeTranslations': s.includeTranslations,
    'binaryFormat': s.binaryFormat,
    'matchmakingFilter': s.matchmakingFilter.name,
    'matchmakingExperience': s.matchmakingExperience.name,
    'friendPlayFilter': s.friendPlayFilter.name,
    'friendPlayExperience': s.friendPlayExperience.name,
    'achievementsFilter': s.achievementsFilter.name,
    'steamCloudFilter': s.steamCloudFilter.name,
    'priceFilter': s.priceFilter.name,
    'geforceNowFilter': s.geforceNowFilter.name,
    'steamOwnershipFilter': s.steamOwnershipFilter.name,
    'motionFilter': s.motionFilter.name,
    'sliderDistribution': s.sliderDistribution.name,
    'sortBy': s.sortBy.name,
    'sortAsc': s.sortAsc,
    'groupByStatus': s.groupByStatus,
    'statusFilters': [for (final e in s.statusFilters) {'status': e.status.name, 'visible': e.visible}],
    'currentMinBytes': s.currentMinBytes,
    'currentMaxBytes': s.currentMaxBytes,
  };

  /// Inverso de [_extractFilters]: lo que falte o venga mal conserva el valor actual.
  static HomeState _restoreFilters(HomeState current, Map<String, dynamic> profile) => current.copyWith(
    searchQuery: profile['searchQuery'] as String?,
    visibleLanguages: _parseEnumSet(GameLanguage.values, profile['visibleLanguages']),
    visibleSpTypes: _parseEnumSet(SpType.values, profile['visibleSpTypes']),
    visibleVrTypes: _parseEnumSet(VrSupport.values, profile['visibleVrTypes']),
    includeSoftware: profile['includeSoftware'] as bool?,
    includeVrMods: profile['includeVrMods'] as bool?,
    includeTranslations: profile['includeTranslations'] as bool?,
    binaryFormat: profile['binaryFormat'] as bool?,
    matchmakingFilter: TriFilter.values.byNameOrNull(profile['matchmakingFilter'] as String?),
    matchmakingExperience: ExperienceFilter.values.byNameOrNull(profile['matchmakingExperience'] as String?),
    friendPlayFilter: TriFilter.values.byNameOrNull(profile['friendPlayFilter'] as String?),
    friendPlayExperience: ExperienceFilter.values.byNameOrNull(profile['friendPlayExperience'] as String?),
    achievementsFilter: TriFilter.values.byNameOrNull(profile['achievementsFilter'] as String?),
    steamCloudFilter: TriFilter.values.byNameOrNull(profile['steamCloudFilter'] as String?),
    priceFilter: TriFilter.values.byNameOrNull(profile['priceFilter'] as String?),
    geforceNowFilter: TriFilter.values.byNameOrNull(profile['geforceNowFilter'] as String?),
    steamOwnershipFilter: TriFilter.values.byNameOrNull(profile['steamOwnershipFilter'] as String?),
    motionFilter: TriFilter.values.byNameOrNull(profile['motionFilter'] as String?),
    sliderDistribution: SliderDistribution.values.byNameOrNull(profile['sliderDistribution'] as String?),
    sortBy: SortBy.parse(profile['sortBy'] as String?),
    sortAsc: profile['sortAsc'] as bool?,
    groupByStatus: profile['groupByStatus'] as bool?,
    statusFilters: _parseStatusFilters(profile['statusFilters']),
    currentMinBytes: (profile['currentMinBytes'] as num?)?.toDouble(),
    currentMaxBytes: (profile['currentMaxBytes'] as num?)?.toDouble(),
  );

  /// Todo lo que va a `db.json`. Los filtros se guardan igual que en un perfil; la
  /// cuenta de Steam y los intervalos de sincronización van aparte para que cargar
  /// un perfil no cambie ni las credenciales ni cuándo se sincroniza.
  Map<String, dynamic> _extractSettings(HomeState s) => {
    ..._extractFilters(s),
    'filterProfiles': s.filterProfiles,
    if (s.esDePath != null) 'esDePath': s.esDePath,
    'refreshIntervalDays': s.refreshIntervalDays,
    'hltbAutoRefreshOnDetail': s.hltbAutoRefreshOnDetail,
    'hltbRefreshByCalendar': s.hltbRefreshByCalendar,
    'steamCheckDays': s.steamCheckDays,
    'steamCheckByCalendar': s.steamCheckByCalendar,
    if (s.steamId != null) 'steamId': s.steamId,
    if (s.steamPersona != null) 'steamPersona': s.steamPersona,
    if (_steamApiKey != null) 'steamApiKey': _steamApiKey,
    if (s.steamSyncedAt != null) 'steamSyncedAt': s.steamSyncedAt,
  };

  HomeState _restoreSettings(HomeState current, Map<String, dynamic> settings) {
    _steamApiKey = settings['steamApiKey'] as String?;
    return _restoreFilters(current, settings).copyWith(
      filterProfiles: switch (settings['filterProfiles']) {
        final Map profiles => {
          for (final MapEntry(:key, :value) in profiles.entries)
            if (key is String && value is Map) key: Map<String, dynamic>.from(value),
        },
        _ => null,
      },
      esDePath: settings['esDePath'] as String?,
      refreshIntervalDays: (settings['refreshIntervalDays'] as num?)?.toInt(),
      hltbAutoRefreshOnDetail: settings['hltbAutoRefreshOnDetail'] as bool?,
      hltbRefreshByCalendar: settings['hltbRefreshByCalendar'] as bool?,
      steamCheckDays: (settings['steamCheckDays'] as num?)?.toInt().clamp(SyncInterval.onOpen, SyncInterval.maxDays),
      steamCheckByCalendar: settings['steamCheckByCalendar'] as bool?,
      steamId: settings['steamId'] as String?,
      steamPersona: settings['steamPersona'] as String?,
      steamSyncedAt: (settings['steamSyncedAt'] as num?)?.toInt(),
    );
  }

  // ─── CARGA / GUARDADO LOCAL ───

  /// Lee en paralelo todos los archivos de juego individuales de `games/` y puebla
  /// `_gamesById` y `_gameFiles` (internalId → filename). No encola nada: el caller
  /// decide las colas una vez conocidos los ajustes.
  Future<void> _loadGamesFromDisk() async {
    final gamesDir = await _gamesDir; // el getter garantiza que el directorio existe
    final files = gamesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));

    final loaded = await Future.wait(files.map((file) async {
      try {
        return (file.uri.pathSegments.last, Game.fromJson(jsonDecode(await file.readAsString())));
      } catch (e) {
        debugPrint('Error loading game file ${file.path}: $e');
        return null;
      }
    }));

    for (final (filename, game) in loaded.nonNulls) {
      _gamesById[game.internalId] = game;
      _gameFiles[game.internalId] = filename;
    }
  }

  /// Lee y decodifica `db.json`. Devuelve el mapa `settings` en crudo, o null si el
  /// archivo no existe o está corrupto.
  Future<Map<String, dynamic>?> _loadSettingsFromDisk() async {
    final file = await _localFile;
    if (!await file.exists()) return null;
    try {
      if (jsonDecode(await file.readAsString()) case {'settings': final Map<String, dynamic> settings}) return settings;
    } catch (e) {
      debugPrint('Error al cargar estado local: $e');
    }
    return null;
  }

  /// Carga el estado inicial desde disco. Los archivos de juego individuales en `games/`,
  /// la configuración en `db.json` y el catálogo GFN son fuentes de disco independientes:
  /// se lanzan a la vez y se esperan después, de modo que el arranque cueste el máximo de
  /// las tres esperas de I/O en lugar de su suma. Todo lo que pide red se delega en [runAutoSync].
  Future<void> _loadLocalState() async {
    final gamesFuture = _loadGamesFromDisk();
    final settingsFuture = _loadSettingsFromDisk();
    final gfnCatalogFuture = _readGfnCatalog();

    await gamesFuture;
    final settings = await settingsFuture;
    final loaded = settings == null ? state : _restoreSettings(state, settings);

    emit(_applyFilters(_updateLimits(loaded)).copyWith(isLoading: false));

    _gfnCatalog = await gfnCatalogFuture;
    // Revisar todos cuesta solo memoria y escribe únicamente lo que cambia, así que
    // también repara una pasada anterior que se cortara a mitad de escritura.
    _startGfnComparisonQueue(all: true);
    runAutoSync();
  }

  Future<void> _saveLocalState(HomeState currentState) async {
    final file = await _localFile;
    await file.writeAsString(jsonEncode({'settings': _extractSettings(currentState)}));
  }

  // ─── SINCRONIZACIÓN AUTOMÁTICA ───

  /// Puesta al día sin intervención, al abrir la app y al volver a ella. Cada fuente
  /// decide por su propia marca de tiempo si le toca, así que repetirla solo gasta red
  /// cuando algo caducó.
  Future<void> runAutoSync() async {
    if (_isAutoSyncRunning || state.isLoading) return;
    _isAutoSyncRunning = true;
    try {
      _enqueueSteam(_gamesById.values.where((g) => !g.hasFetchedSteam));
      _startSteamQueue();

      final gfn = _refreshGfnCatalogIfDue();
      // Antes que HLTB y PCGW, para que los juegos recién importados encabecen su cola.
      await _syncSteamLibraryIfDue();
      _enqueueHltbRefreshes(_gamesById.values);
      _startHltbQueue();
      _enqueuePcgw(_gamesById.values.where((g) => g.needsPcgwFetch));
      _startPcgwQueue();
      await gfn;
    } finally {
      _isAutoSyncRunning = false;
    }
  }

  Future<void> _syncSteamLibraryIfDue() async {
    if (state.steamId == null || _steamApiKey == null) return;
    final due = SyncInterval.isDue(
      state.steamCheckDays,
      byCalendar: state.steamCheckByCalendar,
      last: switch (state.steamSyncedAt) {
        final int ts => DateTime.fromMillisecondsSinceEpoch(ts * 1000),
        null => null,
      },
      now: DateTime.now(),
    );
    if (!due) return;

    final result = await syncSteamLibrary();
    if (_steamAutoSyncEvents.isClosed) return;
    switch (result) {
      case SteamSyncDone(:final added) when added > 0:
      case SteamSyncFailed(reason: SteamFailure.badKey || SteamFailure.privateProfile || SteamFailure.emptyLibrary):
        _steamAutoSyncEvents.add(result);
      case SteamSyncDone() || SteamSyncFailed():
        break;
    }
  }

  Future<void> _refreshGfnCatalogIfDue() async {
    final file = await _gfnLocalFile;
    if (await file.exists() && DateTime.now().difference(await file.lastModified()) < _gfnCatalogTtl) return;
    await fetchGeforceNowDatabase();
  }

  @override
  Future<void> close() {
    _steamAutoSyncEvents.close();
    return super.close();
  }

  // ─── NÚCLEO DE PARCHEO ───

  /// Escribe a disco la versión en memoria del juego, serializando por archivo: dos
  /// parches seguidos al mismo juego nunca se solapan, y juegos distintos se escriben
  /// en paralelo. Un juego eliminado mientras esperaba su turno no recrea su archivo.
  Future<void> _persist(String internalId) {
    final previous = _writeChain[internalId] ?? Future<void>.value();
    return _writeChain[internalId] = previous.then((_) async {
      final game = _gamesById[internalId];
      if (game == null) return;
      try {
        final filename = _gameFiles[internalId] ??= '${const Uuid().v4()}.json';
        await File('${(await _gamesDir).path}/$filename').writeAsString(jsonEncode(game.toJson()));
      } catch (e) {
        debugPrint('Disk write error [$internalId]: $e');
      }
    });
  }

  /// Para workers de cola: aplica el parche sobre la versión más fresca en memoria y
  /// dispara la escritura, sin emitir, para acumular N cambios antes de refiltrar una
  /// sola vez. Un juego que salió de `_gamesById` mientras el worker esperaba la red
  /// se descarta en lugar de reañadirlo.
  void _patch(Game game, Map<String, dynamic> patch) {
    final current = _gamesById[game.internalId];
    if (patch.isEmpty || current == null) return;
    _gamesById[game.internalId] = current.updateFromJson(patch);
    _persist(game.internalId);
  }

  /// Para la interfaz: memoria, disco y un emit. Un peso movido puede desplazar los
  /// extremos del slider, que se guardan con los ajustes; el resto de parches no los toca.
  void patchGame(Game game, Map<String, dynamic> patch) {
    _patch(game, patch);
    if (patch.containsKey('size') || patch.containsKey('unit')) {
      final newState = _applyFilters(_updateLimits(state));
      emit(newState);
      _saveLocalState(newState);
    } else {
      emit(_applyFilters(state));
    }
  }

  // ─── IMPORTACIÓN / EXPORTACIÓN ───

  String exportGamesJson() {
    final sorted = _gamesById.values.sortedBy((g) => _sortKey(g.name));
    if (sorted.isEmpty) return '[]';
    return '[\n  ${sorted.map((g) => jsonEncode(g.toJson())).join(',\n  ')}\n]';
  }

  /// Analiza un JSON de importación SIN aplicarlo ni construir ningún [Game]: valida y
  /// deduplica las entradas por internalId y cuenta los efectos (añadidos/fusionados/
  /// eliminados). Es O(M) sobre las M entradas del archivo, sin recorrer la biblioteca.
  /// Devuelve un [ImportAnalysis] sellado; el [ImportPlan] resultante se pasa tal cual a
  /// [applyImport], de modo que la importación se parsea UNA sola vez.
  ///
  ///  · [replace]          borra toda la biblioteca antes de importar.
  ///  · [preserveExisting] en modo merge, conserva las propiedades ausentes del JSON en
  ///                       los juegos que ya existían (si es false, se reinician).
  ImportAnalysis analyzeImport(String jsonString, {required bool replace, required bool preserveExisting}) {
    final List<dynamic> rawList;
    try {
      rawList = switch (jsonDecode(jsonString)) {
        {'games': final List l} => l,
        final List l => l,
        _ => throw const FormatException('shape'),
      };
    } catch (_) {
      return const InvalidImport();
    }
    return _planFrom(rawList, replace: replace, preserveExisting: preserveExisting);
  }

  /// Valida, deduplica y cuenta los efectos de una lista de entradas crudas ya decodificada.
  /// Compartido por [analyzeImport] y por la sincronización con Steam.
  ImportAnalysis _planFrom(List<dynamic> rawList, {required bool replace, required bool preserveExisting}) {
    // Deduplicación intra-lote por internalId (last-wins). El Map conserva el orden
    // de primera aparición. NO se construye ningún Game aquí. id_steam/name, si están
    // presentes, deben tener el tipo que Game.fromJson espera; de lo contrario la
    // entrada es inservible y se descarta.
    final byId = <String, Map<String, dynamic>>{
      for (final raw in rawList.whereType<Map<String, dynamic>>())
        if ((raw['id_steam'], raw['name']) case (final int? idSteam, final String? name)
            when idSteam != null || (name != null && name.trim().isNotEmpty))
          Game.internalIdOf(idSteam, name): raw,
    };
    if (byId.isEmpty) return const EmptyImport();

    // Tras el borrado total nada preexiste: todo entra como nuevo.
    final merged = replace ? 0 : byId.keys.where(_gamesById.containsKey).length;
    return ReadyImport(ImportPlan(
      byId: byId,
      added: byId.length - merged,
      merged: merged,
      deleted: replace ? _gamesById.length : 0,
      replace: replace,
      preserveExisting: preserveExisting,
    ));
  }

  /// Aplica un [ImportPlan] ya analizado, SIN volver a parsear el JSON. Construye cada
  /// [Game] exactamente una vez y muta `_gamesById` in situ, de modo que el coste es
  /// O(M) sobre las entradas importadas. Persiste a disco en lotes paralelos.
  Future<void> applyImport(ImportPlan plan) async {
    if (plan.replace) await _wipeAllGames();

    final imported = [
      for (final MapEntry(key: id, value: raw) in plan.byId.entries)
        // Merge (updateFromJson) sólo si existe Y se preservan campos.
        _gamesById[id] = switch (_gamesById[id]) {
          final Game current when plan.preserveExisting => current.updateFromJson(raw),
          _ => Game.fromJson(raw),
        },
    ];

    _enqueueSteam(imported.where((g) => !g.hasFetchedSteam));
    _enqueueHltbRefreshes(imported);
    _enqueuePcgw(imported.where((g) => g.needsPcgwFetch));

    final newState = _applyFilters(_updateLimits(state));
    emit(newState);
    await _saveLocalState(newState);

    for (final batch in imported.slices(_writeBatchSize)) {
      await Future.wait(batch.map((g) => _persist(g.internalId)));
      await Future.delayed(Duration.zero); // ceder el event loop entre lotes
    }

    _startSteamQueue();
    _startHltbQueue();
    _startPcgwQueue();
    _startGfnComparisonQueue();
  }

  /// Borra toda la biblioteca: elimina los .json del disco y limpia índices y colas.
  /// Las colas se vacían ANTES de tocar disco, para que ningún worker vuelva a
  /// registrar un juego recién eliminado.
  Future<void> _wipeAllGames() async {
    for (final queue in [_steamQueue, _achievementsQueue, _hltbQueue, _hltbPriorityQueue, _pcgwQueue]) {
      queue.clear();
    }
    _gameFiles.clear();
    _writeChain.clear();
    _gamesById.clear();
    final gamesDir = await _gamesDir;
    for (final f in gamesDir.listSync().whereType<File>()) {
      if (f.path.endsWith('.json')) await f.delete();
    }
  }

  Future<void> clearLibrary() async {
    await _wipeAllGames();
    final newState = _applyFilters(_updateLimits(state));
    emit(newState);
    await _saveLocalState(newState);
  }

  // ─── CUENTA DE STEAM ───

  /// Traduce lo que el usuario escriba (URL de perfil, nombre personalizado o SteamID64)
  /// a una cuenta canónica, validando la clave. No toca el estado: la vista confirma antes.
  Future<SteamResult<SteamAccount>> resolveSteamAccount(String input, String? apiKey) =>
      SteamService.resolveAccount(input, apiKey);

  /// Vincula la cuenta resuelta. Con [wipeLibrary] borra antes la biblioteca entera
  /// (juegos y todos sus datos); sin él, los juegos actuales se conservan y la
  /// sincronización posterior solo añade los que falten.
  Future<void> linkSteamAccount(SteamAccount account, {String? apiKey, bool wipeLibrary = false}) async {
    if (wipeLibrary) await _wipeAllGames();
    _steamApiKey = switch (apiKey?.trim()) {
      final String key when key.isNotEmpty => key,
      _ => null,
    };

    // resetSteam limpia la marca de sincronización y los datos de la cuenta anterior.
    var newState = state.copyWith(resetSteam: true).copyWith(
      steamId: account.id64,
      steamPersona: account.persona,
    );
    if (wipeLibrary) newState = _applyFilters(_updateLimits(newState));
    emit(newState);
    await _saveLocalState(newState);
  }

  Future<void> unlinkSteamAccount({bool wipeLibrary = false}) async {
    if (wipeLibrary) await _wipeAllGames();
    _steamApiKey = null;
    // La pertenencia deja de tener con qué contrastarse, así que se borra en lugar de
    // conservar una marca que ya no responde a ninguna cuenta.
    for (final game in _gamesById.values.toList()) {
      if (game.isOwnedOnSteam != null) _patch(game, {'is_owned_on_steam': null});
    }
    final newState = _applyFilters(_updateLimits(state.copyWith(resetSteam: true, steamOwnershipFilter: TriFilter.all)));
    emit(newState);
    await _saveLocalState(newState);
  }

  /// Si el filtro de pertenencia tiene algo que separar: hace falta una cuenta vinculada
  /// y que la sincronización haya llegado a marcar algún juego.
  bool get hasSteamOwnershipData =>
      state.steamId != null && _gamesById.values.any((g) => g.isOwnedOnSteam != null);

  /// Trae la biblioteca de la cuenta vinculada y añade lo que falte: los appids ya
  /// rastreados se omiten (conservan sus datos) y los nuevos entran solo con appid y
  /// nombre, para que las colas de Steam, GFN, HLTB y PCGW completen el resto en segundo plano.
  Future<SteamSync> syncSteamLibrary() async {
    final steamId = state.steamId;
    if (steamId == null) return const SteamSyncFailed(SteamFailure.notLinked);
    if (state.isSyncingSteamLibrary) return const SteamSyncFailed(SteamFailure.busy);
    emit(state.copyWith(isSyncingSteamLibrary: true));

    final List<SteamOwnedGame> owned;
    switch (await SteamService.fetchOwnedGames(steamId, _steamApiKey)) {
      case SteamFail(:final reason):
        emit(state.copyWith(isSyncingSteamLibrary: false));
        return SteamSyncFailed(reason);
      case SteamOk(:final value):
        owned = value;
    }

    // Un appid ya rastreado se deja intacto: reimportarlo (solo appid y nombre)
    // duplicaría la entrada si el nombre local difiere, porque el internalId
    // se deriva del nombre.
    final tracked = {for (final g in _gamesById.values) ?g.idSteam};
    final rawList = [
      for (final (:appId, :name) in owned)
        if (!tracked.contains(appId)) <String, dynamic>{'id_steam': appId, 'name': ?name},
    ];
    _markSteamOwnership({for (final (:appId, name: _) in owned) appId});
    emit(state.copyWith(isSyncingSteamLibrary: false, steamSyncedAt: _nowEpoch));

    if (_planFrom(rawList, replace: false, preserveExisting: true) case ReadyImport(:final plan)) {
      await applyImport(plan); // persiste biblioteca y ajustes, y arranca las colas
      // Steam no informa del peso: los juegos nuevos entran a 0 bytes y quedarían
      // fuera del rango si el usuario ya había subido el mínimo del slider.
      if (state.currentMinBytes > state.absoluteMinBytes) updateRange(state.absoluteMinBytes, state.currentMaxBytes);
      return SteamSyncDone(added: plan.added, updated: owned.length - plan.added);
    }

    // Nada que importar: la cuenta no aporta ningún appid que falte.
    await _saveLocalState(state);
    return SteamSyncDone(added: 0, updated: owned.length);
  }

  /// Marca qué juegos siguen en la cuenta contrastando sus appids contra [ownedAppIds],
  /// en memoria y sin peticiones. Solo se escribe el juego cuyo valor cambia, así que una
  /// biblioteca estable no toca disco por muchas entradas que tenga la cuenta.
  ///
  /// Nada se borra: la biblioteca también admite juegos añadidos a mano, así que uno que
  /// desaparece de la cuenta (un reembolso) queda marcado, no eliminado.
  void _markSteamOwnership(Set<int> ownedAppIds) {
    for (final game in _gamesById.values.toList()) {
      if (game.idSteam case final appId?) {
        final owned = ownedAppIds.contains(appId);
        if (game.isOwnedOnSteam != owned) _patch(game, {'is_owned_on_steam': owned});
      }
    }
  }

  // ─── GEFORCE NOW API & DB QUEUE ───

  /// Descarga el catálogo de GeForce NOW vía GraphQL paginado y persiste en `gfn_db.json`
  /// los appids de Steam y claves de título de las entradas de tipo GAME. Solo escribe si
  /// la paginación llegó al final, para no marcar como no disponibles juegos que sí lo están.
  /// Después recompara la biblioteca entera contra el catálogo nuevo.
  Future<void> fetchGeforceNowDatabase() async {
    if (state.isFetchingGfnDb) return;
    emit(state.copyWith(isFetchingGfnDb: true));

    final client = HttpClient();
    try {
      final steamIds = <int>{};
      final titleKeys = <String>{};
      var after = '';
      var hasNextPage = true;

      while (hasNextPage) {
        final request = await client.postUrl(Uri.parse('https://api-prod.nvidia.com/services/gfngames/v1/gameList'));
        request.headers
          ..set('Content-Type', 'application/json')
          ..set('Accept', 'application/json');
        request.write('''
        {
          apps(country: "US", language: "en_US", after: "$after") {
            pageInfo { hasNextPage endCursor }
            items { title type variants { appStore storeId } }
          }
        }
        ''');

        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain();
          return;
        }
        final data = jsonDecode(await response.transform(utf8.decoder).join())?['data']?['apps'];
        if (data == null) return;

        hasNextPage = data['pageInfo']?['hasNextPage'] as bool? ?? false;
        after = data['pageInfo']?['endCursor'] as String? ?? '';

        for (final item in (data['items'] as List? ?? []).whereType<Map>()) {
          // El catálogo intercala DLC, clientes de tienda y prerrequisitos con los juegos.
          if (item['type']?.toString().toUpperCase() != 'GAME') continue;

          if (item['title']?.toString() case final title? when title.isNotEmpty) {
            titleKeys.add(HltbService.nameKey(title));
          }
          for (final variant in (item['variants'] as List? ?? []).whereType<Map>()) {
            if (variant['appStore']?.toString().toUpperCase() case 'STEAM' || '11') {
              if (int.tryParse(variant['storeId']?.toString() ?? '') case final storeId?) steamIds.add(storeId);
            }
          }
        }
      }

      if (steamIds.isEmpty) return;
      await (await _gfnLocalFile).writeAsString(jsonEncode({
        'steam_ids': steamIds.toList(),
        'title_keys': titleKeys.toList(),
      }));
      _gfnCatalog = (steamIds: steamIds, titleKeys: titleKeys);
      _startGfnComparisonQueue(all: true);
    } catch (e) {
      debugPrint('Error obteniendo GFN DB: $e');
    } finally {
      client.close();
      emit(state.copyWith(isFetchingGfnDb: false));
    }
  }

  /// Catálogo guardado en disco, o null si aún no se ha descargado ninguno.
  Future<({Set<int> steamIds, Set<String> titleKeys})?> _readGfnCatalog() async {
    final file = await _gfnLocalFile;
    if (!await file.exists()) return null;
    try {
      return switch (jsonDecode(await file.readAsString())) {
        {'steam_ids': final List ids, 'title_keys': final List keys} => (
          steamIds: {for (final e in ids) ?int.tryParse(e.toString())},
          titleKeys: {for (final e in keys) e.toString()},
        ),
        // Catálogo guardado por versiones anteriores: lista plana de appids, sin títulos.
        final List ids => (
          steamIds: {for (final e in ids) ?int.tryParse(e.toString())},
          titleKeys: <String>{},
        ),
        _ => null,
      };
    } catch (e) {
      debugPrint('Error leyendo el catálogo GFN: $e');
      return null;
    }
  }

  /// Compara contra el catálogo los juegos con `hasFetchedGfn=false`, o todos con [all].
  /// Una petición que llega mientras otra pasada corre se acumula y se atiende al acabar.
  Future<void> _startGfnComparisonQueue({bool all = false}) async {
    if (_isGfnQueueRunning) {
      _gfnQueuedPass = (_gfnQueuedPass ?? false) || all;
      return;
    }
    _isGfnQueueRunning = true;
    try {
      for (bool? pass = all; pass != null; pass = _gfnQueuedPass, _gfnQueuedPass = null) {
        await _compareWithGfnCatalog(all: pass);
      }
    } catch (e) {
      debugPrint('Error en cola de comparación GFN: $e');
    } finally {
      _isGfnQueueRunning = false;
    }
  }

  /// Aplica los cambios en un único emit y solo escribe los juegos cuyo valor cambia, así
  /// que refrescar el catálogo apenas toca disco aunque la biblioteca sea grande.
  ///
  /// Un juego con appid se resuelve solo por appid: jugarlo en GFN exige que la variante
  /// de Steam esté en el catálogo, y el título por sí solo daría falsos positivos con los
  /// juegos que GFN sirve únicamente desde otra tienda. Los que no tienen appid se
  /// resuelven por título normalizado.
  Future<void> _compareWithGfnCatalog({required bool all}) async {
    final catalog = _gfnCatalog;
    if (catalog == null || catalog.steamIds.isEmpty) return;

    final changed = <String>[];
    for (final g in _gamesById.values.toList()) {
      if (!all && g.hasFetchedGfn) continue;
      final inGfn = switch (g) {
        Game(idSteam: final appId?) => catalog.steamIds.contains(appId),
        Game(name: final name?) when catalog.titleKeys.isNotEmpty => catalog.titleKeys.contains(HltbService.nameKey(name)),
        _ => g.isGeforceNow,
      };
      final patch = {
        if (inGfn != g.isGeforceNow) 'is_geforce_now': inGfn,
        if (!g.hasFetchedGfn) 'has_fetched_gfn': true,
      };
      if (patch.isEmpty) continue;
      _gamesById[g.internalId] = g.updateFromJson(patch);
      changed.add(g.internalId);
    }
    if (changed.isEmpty) return;
    emit(_applyFilters(state));

    for (final batch in changed.slices(_writeBatchSize)) {
      await Future.wait(batch.map(_persist));
      await Future.delayed(Duration.zero); // ceder el event loop para que Flutter renderice
    }
  }

  // ─── COLA DE STEAM API ───

  void _enqueueSteam(Iterable<Game> games, {bool priority = false}) {
    for (final game in games) {
      if (game.idSteam == null) continue;
      _steamQueue.remove(game.internalId);
      priority ? _steamQueue.insert(0, game.internalId) : _steamQueue.add(game.internalId);
    }
  }

  /// Appids por llamada a `GetItems/v1`. La API corta por encima de 250, así que el lote
  /// se queda por debajo para dejar margen a appids de más dígitos.
  static const int _steamBatchSize = 200;

  int get _pendingSteamCount => _steamQueue.length + _achievementsQueue.length;

  void _emitSteamProgress() => emit(_applyFilters(state.copyWith(steamQueueSize: _pendingSteamCount)));

  /// Procesa la cola de Steam por lotes: pide los metadatos de hasta [_steamBatchSize]
  /// juegos en una sola llamada a `GetItems/v1` y aplica todos los parches en un emit.
  /// Los juegos cuyo lote no declara logros pasan a [_achievementsQueue], que los
  /// confirma de uno en uno. Un 429 devuelve el lote a la cola y pausa 60 s.
  Future<void> _startSteamQueue() async {
    if (_isSteamQueueRunning) return;
    _isSteamQueueRunning = true;
    _emitSteamProgress();

    final client = HttpClient();
    try {
      // Los logros se confirman después de los lotes pero dentro del bucle, para que un
      // juego encolado mientras se drenan entre en el siguiente lote.
      while (_steamQueue.isNotEmpty || _achievementsQueue.isNotEmpty) {
        if (_steamQueue.isEmpty) {
          await _drainAchievementsQueue(client);
          continue;
        }
        // Los juegos que ya tienen todos los campos se resuelven sin red.
        final batch = <int, Game>{};
        while (_steamQueue.isNotEmpty && batch.length < _steamBatchSize) {
          // El juego pudo eliminarse (biblioteca vaciada) o no tener appid: se salta.
          final game = _gamesById[_steamQueue.removeAt(0)];
          if (game?.idSteam case final appId?) {
            if (_needsSteamFetch(game!)) {
              batch[appId] = game;
            } else {
              _patch(game, {'has_fetched_steam': true});
            }
          }
        }
        if (batch.isEmpty) {
          _emitSteamProgress();
          continue;
        }

        final inputJson = jsonEncode({
          'context': {'language': 'spanish', 'country_code': 'US'},
          'data_request': {'include_basic_info': true, 'include_supported_languages': true},
          'ids': [for (final appId in batch.keys) {'appid': appId}],
        });
        final uri = Uri.parse(
          'https://api.steampowered.com/IStoreBrowseService/GetItems/v1?input_json=${Uri.encodeComponent(inputJson)}',
        );

        final List items;
        try {
          final response = await (await client.getUrl(uri)).close();
          if (response.statusCode == 429) {
            await response.drain();
            _enqueueSteam(batch.values, priority: true);
            _emitSteamProgress();
            await Future.delayed(const Duration(seconds: 60));
            continue;
          }
          if (response.statusCode != 200) {
            await response.drain();
            // La tanda no se puede resolver: se marca vista para no reintentarla en bucle.
            for (final game in batch.values) {
              _patch(game, {'has_fetched_steam': true});
            }
            _emitSteamProgress();
            continue;
          }
          final payload = jsonDecode(await response.transform(utf8.decoder).join());
          items = payload['response']?['store_items'] as List? ?? const [];
        } catch (e) {
          debugPrint('Steam API error de red: $e');
          // Los juegos del lote vuelven a la cola: el fallo es de red, no del dato.
          _enqueueSteam(batch.values, priority: true);
          break;
        }

        for (final item in items.whereType<Map<String, dynamic>>()) {
          // Otro worker pudo actualizar el juego, o pudo eliminarse, mientras
          // esperábamos la respuesta. Si no existe, se descarta sin reañadirlo.
          final game = switch (batch[item['appid']]) {
            final Game g => _gamesById[g.internalId],
            null => null,
          };
          if (game == null) continue;
          if (item['success'] != 1) {
            _patch(game, {'has_fetched_steam': true});
            continue;
          }
          final patch = _buildSteamPatch(game, item);
          _patch(game, patch);
          if (patch['has_achievements'] == false) _achievementsQueue.add(game.internalId);
        }

        // Un appid que la API no devuelve queda marcado igual para no repetir el lote.
        for (final game in batch.values) {
          if (_gamesById[game.internalId] case final pending? when !pending.hasFetchedSteam) {
            _patch(pending, {'has_fetched_steam': true});
          }
        }

        _emitSteamProgress();
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    } finally {
      client.close();
      _isSteamQueueRunning = false;
      _emitSteamProgress();
    }
  }

  /// Confirma los logros contra `appdetails`, que solo acepta un appid por llamada, y
  /// cede en cuanto haya lotes pendientes porque rinden mucho más por petición.
  /// Un fallo deja el valor que dio `GetItems`.
  Future<void> _drainAchievementsQueue(HttpClient client) async {
    while (_achievementsQueue.isNotEmpty && _steamQueue.isEmpty) {
      final game = _gamesById[_achievementsQueue.removeAt(0)];
      if (game?.idSteam case final appId?) {
        try {
          final response = await (await client.getUrl(Uri.parse(
            'https://store.steampowered.com/api/appdetails?appids=$appId&filters=achievements',
          ))).close();
          if (response.statusCode != 200) {
            await response.drain(); // un 429 aquí no merece pausar la cola entera
          } else {
            // La respuesta viene indexada por el appid consultado.
            final decoded = jsonDecode(await response.transform(utf8.decoder).join());
            final entry = decoded is Map ? decoded['$appId'] : null;
            if (entry case {'success': true, 'data': {'achievements': {'total': final int total}}} when total > 0) {
              _patch(game!, {'has_achievements': true});
            }
          }
        } catch (e) {
          debugPrint('Error en fallback de logros para $appId: $e');
        }
        _emitSteamProgress();
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    }
  }

  /// Un juego se consulta si se pidió refrescarlo o si le falta algún campo de Steam.
  bool _needsSteamFetch(Game game) => game.hasFetchedSteam || switch (game) {
    Game(name: null) || Game(isSoftware: null) || Game(isFree: null) || Game(hasSpanish: null) ||
    Game(spType: null) || Game(hasSteamCloud: null) || Game(vrSupport: null) ||
    Game(matchmaking: null) || Game(friendPlay: null) || Game(hasAchievements: null) => true,
    _ => false,
  };

  /// Construye el parche Steam a partir de la respuesta de la API. Sin efectos secundarios.
  /// En la primera consulta lo ya definido a mano manda sobre la tienda; al re-consultar
  /// manda la tienda, salvo en el solitario simulado, que solo puede venir del usuario.
  Map<String, dynamic> _buildSteamPatch(Game game, Map<String, dynamic> item) {
    final isRefetch = game.hasFetchedSteam;
    T keep<T>(T? current, T fetched) => isRefetch ? fetched : current ?? fetched;

    final patch = <String, dynamic>{'has_fetched_steam': true};

    // La tienda publica algunos nombres con espacios de sobra (" Wanba Warriors").
    if (item['name']?.toString().trim() case final name? when name.isNotEmpty) {
      if (game.name == null || Game.normalizeIdName(game.name) == Game.normalizeIdName(name)) patch['name'] = name;
    }
    if (item['type'] case final int type) patch['is_software'] = keep(game.isSoftware, type != 0);
    if (item['is_free'] case final bool isFree) patch['is_free'] = keep(game.isFree, isFree);

    // Idiomas: elanguage==5 (Español de España), elanguage==27 (Español de Hispanoamérica).
    if (item['supported_languages'] case final List languages) {
      final hasSpanish = languages.any((l) => switch (l) {
        {'elanguage': 5 || 27, 'supported': true} ||
        {'elanguage': 5 || 27, 'subtitles': true} ||
        {'elanguage': 5 || 27, 'full_audio': true} => true,
        _ => false,
      });
      patch['has_spanish'] = keep(game.hasSpanish, hasSpanish);
    }

    // Categorías: divididas en 3 sub-arrays: supported_players, features y controllers.
    final categories = item['categories'];
    final ids = <int>{
      ...?(categories?['supported_player_categoryids'] as List?)?.whereType<int>(),
      ...?(categories?['feature_categoryids'] as List?)?.whereType<int>(),
    };

    if (ids.isNotEmpty) {
      final vr = switch (ids) {
        _ when ids.contains(54) => VrSupport.only, // 54: VR Only
        _ when ids.contains(31) || ids.contains(53) => VrSupport.yes, // 31: VR Support, 53: VR Supported
        _ => VrSupport.no,
      };
      patch['vr_support'] = vr.name;

      final spType = ids.contains(2) ? SpType.native : SpType.none; // 2: Single-player
      patch['sp_type'] = (game.spType == SpType.simulated ? SpType.simulated : spType).name;

      patch['has_steam_cloud'] = keep(game.hasSteamCloud, ids.contains(23)); // 23: Steam Cloud
      patch['has_achievements'] = keep(game.hasAchievements, ids.contains(22)); // 22: Steam Achievements

      final hasPvp = ids.contains(36) || ids.contains(49); // 36: Online PvP, 49: PvP
      final hasCoop = ids.contains(9) || ids.contains(38); // 9: Co-op, 38: Online Co-op
      final isOnline = ids.contains(1) || ids.contains(20) || ids.contains(27); // 1: Multi-player, 20: MMO, 27: Cross-Platform
      if (game.matchmaking == null && (hasPvp || hasCoop || isOnline)) {
        patch['matchmaking'] = switch ((hasPvp, hasCoop)) {
          (true, false) => InteractionType.pvp,
          (false, true) => InteractionType.coop,
          _ => InteractionType.both,
        }.name;
      }

      final hasLocalPvp = ids.contains(37) || ids.contains(47); // 37: Shared PvP, 47: LAN PvP
      final hasLocalCoop = ids.contains(39) || ids.contains(48); // 39: Shared Co-op, 48: LAN Co-op
      final hasLocal = ids.contains(24) || ids.contains(44); // 24: Shared Screen, 44: Remote Play Together
      if (game.friendPlay == null && (hasLocalPvp || hasLocalCoop || hasLocal)) {
        patch['friend_play'] = switch ((hasLocalPvp || (hasLocal && hasPvp), hasLocalCoop || (hasLocal && hasCoop))) {
          (true, true) => InteractionType.both,
          (true, false) => InteractionType.pvp,
          (false, _) => InteractionType.coop,
        }.name;
      }
    }

    // Las etiquetas de tipo describen cómo se juega, y no aplican al software: los hay
    // de servidor, de un solo uso y pensados para varios a la vez. En vez de deducirles un
    // tipo que no tienen, quedan todas en `none`.
    if ((patch['is_software'] ?? game.isSoftware) == true) {
      patch['sp_type'] = SpType.none.name;
      patch['matchmaking'] = InteractionType.none.name;
      patch['friend_play'] = InteractionType.none.name;
    }

    return patch;
  }

  // ─── COLA DE HLTB API ───

  /// Mantiene la cola general de la consulta más antigua a la más reciente, con los nunca
  /// consultados delante. Como cada consulta sella su fecha, una cola cortada a medias
  /// retoma en la siguiente apertura justo donde se quedó en lugar de repetir los mismos.
  void _enqueueHltbByAge(Iterable<String> internalIds) {
    final queued = {..._hltbQueue, ..._hltbPriorityQueue};
    final fresh = internalIds.where(queued.add).toList();
    if (fresh.isEmpty) return;
    _hltbQueue
      ..addAll(fresh)
      ..sortBy<num>((id) => _gamesById[id]?.hltbFetchedAt ?? -1);
  }

  void _enqueueHltbRefreshes(Iterable<Game> games) => _enqueueHltbByAge([
    for (final g in games)
      if (g.needsHltbRefresh(state.refreshIntervalDays, byCalendar: state.hltbRefreshByCalendar)) g.internalId,
  ]);

  int get _pendingHltbCount => _hltbPriorityQueue.length + _hltbQueue.length;

  /// Procesa la cola de HLTB de forma secuencial: delega en `HltbService.fetchGameStats`
  /// y aplica el parche resultante leyendo siempre la versión más fresca del juego en memoria.
  Future<void> _startHltbQueue() async {
    if (_isHltbQueueRunning) return;
    _isHltbQueueRunning = true;
    emit(state.copyWith(hltbQueueSize: _pendingHltbCount));

    // Dedup por id de HLTB dentro de esta pasada: si varios juegos comparten el mismo
    // id conocido de HLTB, se reutiliza la respuesta ya obtenida en vez de repetir la
    // petición (una sola consulta en lugar de una por juego).
    final sessionCache = <String, HltbStats>{};

    while (_pendingHltbCount > 0) {
      final internalId = (_hltbPriorityQueue.isNotEmpty ? _hltbPriorityQueue : _hltbQueue).removeAt(0);
      final game = _gamesById[internalId];
      if (game == null || (game.name == null && game.hltbStats?.id == null)) {
        emit(state.copyWith(hltbQueueSize: _pendingHltbCount));
        continue;
      }

      try {
        final knownId = game.hltbStats?.id;
        // Reutiliza el resultado cacheado por id conocido; si no, consulta a HLTB.
        final lookup = switch (knownId != null ? sessionCache[knownId] : null) {
          final HltbStats cached => HltbFound(cached),
          _ => await HltbService.fetchGameStats(game.name, knownId, game.idSteam?.toString(), game.hltbFetchedAt != null),
        };

        // `_patch` relee el juego: pudo actualizarse o eliminarse mientras esperábamos.
        switch (lookup) {
          case HltbFound(:final stats):
            if (stats.id case final fid?) sessionCache[fid] = stats;
            _patch(game, {'hltb_stats': stats.toJson(), 'hltb_fetched_at': _nowEpoch});
          // HLTB respondió y no lo tiene: se sella la fecha igual, para no repetir la
          // búsqueda en cada arranque.
          case HltbNotFound():
            _patch(game, {'hltb_fetched_at': _nowEpoch});
          // No se pudo preguntar: se deja sin sellar para reintentar en el próximo ciclo.
          case HltbUnavailable():
            break;
        }
      } catch (e) {
        debugPrint('HLTB Error general: $e');
        break;
      }

      emit(_applyFilters(state.copyWith(hltbQueueSize: _pendingHltbCount)));
    }

    _isHltbQueueRunning = false;
    emit(_applyFilters(state.copyWith(hltbQueueSize: 0)));
  }

  // ─── COLA DE PCGAMINGWIKI ───

  void _enqueuePcgw(Iterable<Game> games, {bool priority = false}) {
    if (!PcgwService.enabled) return;
    for (final game in games) {
      _pcgwQueue.remove(game.internalId);
      priority ? _pcgwQueue.insert(0, game.internalId) : _pcgwQueue.add(game.internalId);
    }
  }

  /// Procesa la cola de PCGamingWiki de uno en uno, a un ritmo de una ficha por segundo.
  /// Si la wiki deja de responder, el resto espera en la cola a la próxima sincronización
  /// en lugar de insistir.
  Future<void> _startPcgwQueue() async {
    if (_isPcgwQueueRunning) return;
    _isPcgwQueueRunning = true;

    queue:
    while (_pcgwQueue.isNotEmpty) {
      emit(state.copyWith(pcgwQueueSize: _pcgwQueue.length));
      final internalId = _pcgwQueue.removeAt(0);
      final game = _gamesById[internalId];
      if (game == null) continue;

      switch (await PcgwService.fetch(game.idSteam, game.name)) {
        case PcgwFound(:final data):
          _patch(game, _buildPcgwPatch(game, data));
        case PcgwNotFound():
          _patch(game, {'pcgw_fetched_at': _nowEpoch});
        case PcgwUnavailable():
          _pcgwQueue.insert(0, internalId);
          break queue;
      }
      emit(_applyFilters(state));
      await Future.delayed(const Duration(seconds: 1));
    }

    _isPcgwQueueRunning = false;
    emit(_applyFilters(state.copyWith(pcgwQueueSize: 0)));
  }

  /// Lo encontrado se suma a lo que ya hubiera (enlaces importados a mano incluidos);
  /// una URL repetida se queda con la versión de la wiki. La VR de serie solo se
  /// completa cuando Steam no la declara: los mods ya cuentan por sí solos.
  Map<String, dynamic> _buildPcgwPatch(Game game, PcgwData data) {
    List<Map<String, dynamic>> merge(List<WebLink> current, List<WebLink> found) =>
        [for (final link in current.followedBy(found)) link.toJson()];
    return {
      'pcgw_page': data.page,
      'pcgw_fetched_at': _nowEpoch,
      'translations': merge(game.translations, data.translations),
      'vr_mods': merge(game.vrMods, data.vrMods),
      'audio_fixes': merge(game.audioFixes, data.audioFixes),
      'patches': merge(game.patches, data.patches),
      if (data.vrNative && game.vrSupport != VrSupport.only) 'vr_support': VrSupport.yes.name,
      if (data.motion case final motion?) 'motion': motion.name,
    };
  }

  // ─── RE-FETCH ───

  void refetchSteamAll() {
    _enqueueSteam(_gamesById.values);
    _startSteamQueue();
  }

  void refetchHltbAll() {
    _enqueueHltbByAge(_gamesById.keys);
    _startHltbQueue();
  }

  void refetchPcgwAll() {
    _enqueuePcgw(_gamesById.values.where((g) => g.idSteam != null && g.isSoftware != true));
    _startPcgwQueue();
  }

  // Individual, con prioridad inmediata: pedido desde el detalle de un juego.

  void refetchSteamForGame(Game game) {
    _enqueueSteam([game], priority: true);
    _startSteamQueue();
  }

  void refetchGfnForGame(Game game) {
    if (game.idSteam == null) return;
    patchGame(game, {'has_fetched_gfn': false});
    _startGfnComparisonQueue();
  }

  void refetchHltbForGame(Game game) {
    _hltbQueue.remove(game.internalId);
    _hltbPriorityQueue
      ..remove(game.internalId)
      ..insert(0, game.internalId);
    _startHltbQueue();
  }

  void refetchPcgwForGame(Game game) {
    _enqueuePcgw([game], priority: true);
    _startPcgwQueue();
  }

  // ─── FILTROS Y AJUSTES ───

  void updateRange(double minBytes, double maxBytes) {
    final minB = minBytes.clamp(state.absoluteMinBytes, state.absoluteMaxBytes);
    final maxB = maxBytes.clamp(minB, state.absoluteMaxBytes);
    final newState = _applyFilters(state.copyWith(currentMinBytes: minB, currentMaxBytes: maxB));
    emit(newState);
    _saveLocalState(newState);
  }

  void updateFlag({
    bool? software,
    bool? vrMods,
    bool? translations,
    bool? binary,
    SortBy? sort,
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
    TriFilter? steamOwnershipFilter,
    TriFilter? motionFilter,
    SliderDistribution? sliderDistribution,
    String? esDePath,
    int? refreshIntervalDays,
    bool? hltbAutoRefreshOnDetail,
    bool? hltbRefreshByCalendar,
    int? steamCheckDays,
    bool? steamCheckByCalendar,
  }) {
    var newState = state.copyWith(
      includeSoftware: software,
      includeVrMods: vrMods,
      includeTranslations: translations,
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
      steamOwnershipFilter: steamOwnershipFilter,
      motionFilter: motionFilter,
      sliderDistribution: sliderDistribution,
      esDePath: esDePath,
      refreshIntervalDays: refreshIntervalDays,
      hltbAutoRefreshOnDetail: hltbAutoRefreshOnDetail,
      hltbRefreshByCalendar: hltbRefreshByCalendar,
      steamCheckDays: steamCheckDays,
      steamCheckByCalendar: steamCheckByCalendar,
    );
    // El formato binario redondea los extremos del slider a otra unidad.
    if (binary != null) newState = _updateLimits(newState);
    newState = _applyFilters(newState);
    final syncChanged = newState.steamCheckDays != state.steamCheckDays ||
        newState.steamCheckByCalendar != state.steamCheckByCalendar ||
        newState.refreshIntervalDays != state.refreshIntervalDays ||
        newState.hltbRefreshByCalendar != state.hltbRefreshByCalendar;
    emit(newState);
    _saveLocalState(newState);
    if (syncChanged) runAutoSync();
  }

  void toggleStatusFilter(GameStatus status, bool isEnabled) => updateFlag(statusFilters: [
    for (final e in state.statusFilters)
      (status: e.status, visible: e.status == status ? isEnabled : e.visible),
  ]);

  /// Muestra u oculta un valor de los filtros de idioma, solitario o VR.
  void toggleVisible(Enum value, bool isEnabled) {
    Set<T> toggled<T>(Set<T> current, T v) => isEnabled ? {...current, v} : ({...current}..remove(v));
    switch (value) {
      case GameLanguage():
        updateFlag(visibleLanguages: toggled(state.visibleLanguages, value));
      case SpType():
        updateFlag(visibleSpTypes: toggled(state.visibleSpTypes, value));
      case VrSupport():
        updateFlag(visibleVrTypes: toggled(state.visibleVrTypes, value));
    }
  }

  // ─── PERFILES DE FILTRO ───

  void saveFilterProfile(String name) {
    if (name.trim().isEmpty) return;
    final newState = state.copyWith(filterProfiles: {...state.filterProfiles, name.trim(): _extractFilters(state)});
    emit(newState);
    _saveLocalState(newState);
  }

  void loadFilterProfile(String name) {
    final profile = state.filterProfiles[name];
    if (profile == null) return;
    // El catálogo no cambió: solo hay que recalcular el redondeo si el perfil cambia binaryFormat.
    final newState = _applyFilters(_updateLimits(_restoreFilters(state, profile)));
    emit(newState);
    _saveLocalState(newState);
  }

  void deleteFilterProfile(String name) {
    final newState = state.copyWith(filterProfiles: {...state.filterProfiles}..remove(name));
    emit(newState);
    _saveLocalState(newState);
  }

  // ─── MOTOR DE FILTRADO Y ORDENACIÓN ───

  /// Calcula los límites absolutos del slider de tamaño según todos los juegos en memoria,
  /// redondeados a la unidad (MB/GB o MiB/GiB) de cada extremo. Si el rango seleccionado
  /// por el usuario está en su valor inicial (0-1), se expande a los nuevos límites; si ya
  /// fue ajustado, se preserva adaptándolo al nuevo rango.
  HomeState _updateLimits(HomeState s) {
    if (_gamesById.isEmpty) {
      return s.copyWith(absoluteMinBytes: 0, absoluteMaxBytes: 1, currentMinBytes: 0, currentMaxBytes: 1);
    }
    final sizes = _gamesById.values.map((g) => g.sizeInBytes);
    final (min, max) = (sizes.min, sizes.max);
    final minUnit = SizeUnit.forBytes(min, binary: s.binaryFormat).bytes;
    final maxUnit = SizeUnit.forBytes(max, binary: s.binaryFormat).bytes;
    final absMin = (min / minUnit).floor() * minUnit;
    var absMax = (max / maxUnit).ceil() * maxUnit;
    if (absMin == absMax) absMax += maxUnit;

    final isInitialRange = s.currentMinBytes == 0 && s.currentMaxBytes <= 1;
    final cMin = isInitialRange ? absMin : s.currentMinBytes.clamp(absMin, absMax);
    return s.copyWith(
      absoluteMinBytes: absMin,
      absoluteMaxBytes: absMax,
      currentMinBytes: cMin,
      currentMaxBytes: isInitialRange ? absMax : s.currentMaxBytes.clamp(cMin, absMax),
    );
  }

  static String _sortKey(String? text) => HltbService.removeDiacritics(text ?? '').replaceAll('.', '');

  /// DRY para los filtros de interacción (matchmaking y friendPlay).
  static bool _matchesInteraction(InteractionType? actual, TriFilter filter, ExperienceFilter exp) {
    final active = actual != null && actual != InteractionType.none;
    if (!filter.admits(active)) return false;
    if (filter == TriFilter.no) return true;
    return switch (exp) {
      ExperienceFilter.any => true,
      ExperienceFilter.coop => actual == InteractionType.coop || actual == InteractionType.both,
      ExperienceFilter.pvp => actual == InteractionType.pvp || actual == InteractionType.both,
      ExperienceFilter.both => actual == InteractionType.both,
    };
  }

  HomeState _applyFilters(HomeState s) {
    // Patrón de búsqueda compilado una vez por pasada; null si no hay búsqueda.
    final search = switch (s.searchQuery.trim()) {
      '' => null,
      final query => RegExp(
        HltbService.removeDiacritics(query).split(RegExp(r' +')).map(RegExp.escape).join(r'\s+'),
        caseSensitive: false,
      ),
    };
    final visibleStatuses = s.visibleStatuses;

    bool passes(Game g) =>
        (search == null || search.hasMatch(HltbService.removeDiacritics(g.name ?? ''))) &&
        (s.includeSoftware || g.isSoftware != true) &&
        (g.spType == null || s.visibleSpTypes.contains(g.spType)) &&
        (s.visibleVrTypes.contains(g.vr) || (s.includeVrMods && g.hasVrMods)) &&
        _matchesInteraction(g.matchmaking, s.matchmakingFilter, s.matchmakingExperience) &&
        _matchesInteraction(g.friendPlay, s.friendPlayFilter, s.friendPlayExperience) &&
        s.steamCloudFilter.admits(g.hasSteamCloud) &&
        s.achievementsFilter.admits(g.hasAchievements) &&
        s.priceFilter.admits(g.isFree) &&
        s.motionFilter.admits(g.motion?.works) &&
        // Un juego parcheado al español se conserva fuera de GFN: el parche no corre allí.
        (s.geforceNowFilter.admits(g.isGeforceNow) || g.hasTranslations) &&
        // Sin marcar (null) no se afirma nada, así que queda fuera de los dos lados.
        switch (s.steamOwnershipFilter) {
          TriFilter.all => true,
          TriFilter.yes => g.isOwnedOnSteam == true,
          TriFilter.no => g.isOwnedOnSteam == false,
        } &&
        (s.visibleLanguages.contains(g.language) || (s.includeTranslations && g.hasTranslations)) &&
        visibleStatuses.contains(g.status) &&
        g.sizeInBytes >= s.currentMinBytes &&
        g.sizeInBytes <= s.currentMaxBytes;

    final filtered = _gamesById.values.where(passes).toList();
    final sorted = s.groupByStatus
        // Agrupado: cada estado ordenado por su cuenta, en el orden que el usuario les dio.
        ? [for (final status in visibleStatuses) ..._sorted(filtered.where((g) => g.status == status), s)]
        : _sorted(filtered, s);

    // Las colas refiltran tras cada paso aunque no cambie ningún juego: conservar la
    // misma lista deja que la vista (que compara por identidad) se salte el rebuild.
    return s.copyWith(
      filteredGames: listEquals(sorted, s.filteredGames) ? s.filteredGames : sorted,
      totalBytes: filtered.fold<double>(0, (sum, g) => sum + g.sizeInBytes),
      gameCount: _gamesById.length,
    );
  }

  /// `sortedBy` calcula la clave una vez por juego, no en cada comparación.
  static List<Game> _sorted(Iterable<Game> games, HomeState s) {
    if (s.sortBy case SortBy.name || SortBy.size) {
      final sorted = s.sortBy == SortBy.name
          ? games.sortedBy((g) => _sortKey(g.name))
          : games.sortedBy<num>((g) => g.sizeInBytes);
      return s.sortAsc ? sorted : sorted.reversed.toList();
    }
    // Por tiempo de HLTB: sin tiempo registrado van siempre al final, suba o baje el orden.
    return games.sortedByCompare(
      (g) => switch (g.hltbStats) {
        null => 0,
        HltbStats(:final mainStory) when s.sortBy == SortBy.hltbMain => mainStory.average,
        HltbStats(:final extras) when s.sortBy == SortBy.hltbExtras => extras.average,
        HltbStats(:final completionist) => completionist.average,
      },
      (a, b) => switch ((a, b)) {
        (0, 0) => 0,
        (0, _) => 1,
        (_, 0) => -1,
        _ => s.sortAsc ? a.compareTo(b) : b.compareTo(a),
      },
    );
  }
}
