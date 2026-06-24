import 'hltb_service.dart';

extension EnumByNameOrNull<T extends Enum> on Iterable<T> {
  T? byNameOrNull(String? name) {
    if (name == null) return null;
    for (var value in this) {
      if (value.name == name) return value;
    }
    return null;
  }
}

enum GameStatus {
  planned,
  playing,
  beaten, // Terminado (solo lo principal)
  completed, // Completado al 100% / Platinado
  paused,
  dropped,
  discarded
}

enum GameLanguage { english, spanish, patched }
enum SpType { native, simulated, none }
enum InteractionType { none, coop, pvp, both }
enum VrSupport { no, yes, only, mod }

class Game {
  final int? idSteam;
  final String? name;
  final double size;
  final String unit;
  final double sizeInBytes;
  final bool? isSoftware;
  final bool? isFree;
  final bool? hasSpanish;
  final SpType? spType;
  final InteractionType? matchmaking; // Matchmaking, MMO o servidores no autohospedables
  final InteractionType? friendPlay;  // Lobbies, LAN, local o servidores autohospedables

  final bool? hasAchievements;
  final bool? hasSteamCloud;
  final bool? isGeforceNow;
  final VrSupport? vrSupport;
  final GameStatus status;
  final String? patchUrl;
  final String? userNote;
  final bool hasFetchedSteam;
  final bool hasFetchedGfn;
  final bool hasFetchedHltb;

  final HltbStats? hltbStats;

  const Game({
    this.idSteam,
    this.name,
    required this.size,
    required this.unit,
    required this.sizeInBytes,
    this.isSoftware,
    this.isFree,
    this.hasSpanish,
    this.spType,
    this.matchmaking,
    this.friendPlay,
    this.hasAchievements,
    this.hasSteamCloud,
    this.isGeforceNow,
    this.vrSupport,
    this.status = GameStatus.planned,
    this.patchUrl,
    this.userNote,
    this.hasFetchedSteam = false,
    this.hasFetchedGfn = false,
    this.hasFetchedHltb = false,
    this.hltbStats,
  }) : assert(idSteam != null || name != null, 'Un juego debe tener idSteam o un nombre');

  /// Normaliza el nombre del juego para comparaciones estrictas.
  /// Elimina símbolos de marcas, texto entre paréntesis (ej. "(2013)"), y empareja mayúsculas.
  static String normalizeIdName(String? input) {
    if (input == null) return '';
    return input.toLowerCase()
        .replaceAll(RegExp(r'[™®©]'), '') // Elimina símbolos registrados
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '') // Elimina cualquier texto entre paréntesis
        .trim();
  }

  /// Identificador único en memoria para ubicar el archivo asociado en la base de datos distribuida.
  /// Incluye el nombre normalizado cuando hay idSteam para diferenciar expansiones 
  /// (ej. F.E.A.R. vs F.E.A.R.: Extraction Point) pero evitar duplicados por case-sensitive o tags.
  String get internalId {
    if (idSteam != null) {
      if (name != null) {
        return '${idSteam}_${normalizeIdName(name)}';
      }
      return idSteam.toString();
    }
    return name != null ? normalizeIdName(name) : '';
  }

  /// Determina el idioma basado en las propiedades.
  GameLanguage get language {
    if (patchUrl != null && patchUrl!.trim().isNotEmpty) return GameLanguage.patched;
    if (hasSpanish == true) return GameLanguage.spanish;
    return GameLanguage.english;
  }

  factory Game.fromJson(Map<String, dynamic> json) {
    double s = (json['size'] ?? 0).toDouble();
    String u = (json['unit'] ?? 'mb').toString().toLowerCase();
    double bytes = _calculateBytes(s, u);

    // Inteligencia: Si no hay ID, marcamos como fetch=true para que no intente buscarlo en Steam.
    bool fetchedSteam = json['has_fetched_steam'] ?? switch (json) {
      _ when json['has_fetched_steam'] == true => true,
      _ when json['id_steam'] == null => true,
      {
        'name': _,
        'is_software': _,
        'is_free': _,
        'has_spanish': _,
        'sp_type': _,
        'has_achievements': _,
        'has_steam_cloud': _,
        'vr_support': _,
      } => true,
      _ => false,
    };

    bool fetchedHltb = json['has_fetched_hltb'] ?? switch (json) {
      _ when json['id_steam'] == null => true,
      _ when json['hltb_stats'] != null => true,
      _ => false,
    };

    return Game(
      idSteam: json['id_steam'],
      name: json['name'],
      size: s,
      unit: u,
      sizeInBytes: bytes,
      isSoftware: json['is_software'],
      isFree: json['is_free'],
      hasSpanish: json['has_spanish'],
      spType: SpType.values.byNameOrNull(json['sp_type']),
      matchmaking: InteractionType.values.byNameOrNull(json['matchmaking']),
      friendPlay: InteractionType.values.byNameOrNull(json['friend_play']),
      hasAchievements: json['has_achievements'],
      hasSteamCloud: json['has_steam_cloud'],
      isGeforceNow: json['is_geforce_now'],
      vrSupport: VrSupport.values.byNameOrNull(json['vr_support']),
      status: GameStatus.values.byNameOrNull(json['status']) ?? GameStatus.planned,
      patchUrl: json['patch_url'],
      userNote: json['user_note'],
      hasFetchedSteam: fetchedSteam,
      hasFetchedGfn: json['has_fetched_gfn'] ?? false,
      hasFetchedHltb: fetchedHltb,
      hltbStats: json['hltb_stats'] != null ? HltbStats.fromJson(json['hltb_stats']) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    if (idSteam != null) 'id_steam': idSteam,
    if (name != null) 'name': name,
    'size': size,
    'unit': unit,
    if (isSoftware != null) 'is_software': isSoftware,
    if (isFree != null) 'is_free': isFree,
    if (hasSpanish != null) 'has_spanish': hasSpanish,
    if (spType != null) 'sp_type': spType!.name,
    if (matchmaking != null) 'matchmaking': matchmaking!.name,
    if (friendPlay != null) 'friend_play': friendPlay!.name,
    if (hasAchievements != null) 'has_achievements': hasAchievements,
    if (hasSteamCloud != null) 'has_steam_cloud': hasSteamCloud,
    if (isGeforceNow != null) 'is_geforce_now': isGeforceNow,
    if (vrSupport != null) 'vr_support': vrSupport!.name,
    'status': status.name,
    if (patchUrl != null) 'patch_url': patchUrl,
    if (userNote != null) 'user_note': userNote,
    'has_fetched_steam': hasFetchedSteam,
    'has_fetched_gfn': hasFetchedGfn,
    'has_fetched_hltb': hasFetchedHltb,
    if (hltbStats != null) 'hltb_stats': hltbStats!.toJson(),
  };

  Game updateFromJson(Map<String, dynamic> json) {
    double newSize = json.containsKey('size') ? (json['size'] as num).toDouble() : size;
    String newUnit = json.containsKey('unit') ? json['unit'].toString().toLowerCase() : unit;
    double newBytes = _calculateBytes(newSize, newUnit);

    return Game(
      idSteam: json['id_steam'] ?? idSteam,
      name: json['name'] ?? name,
      size: newSize,
      unit: newUnit,
      sizeInBytes: newBytes,
      isSoftware: json.containsKey('is_software') ? json['is_software'] : isSoftware,
      isFree: json.containsKey('is_free') ? json['is_free'] : isFree,
      hasSpanish: json.containsKey('has_spanish') ? json['has_spanish'] : hasSpanish,
      spType: json.containsKey('sp_type') ? SpType.values.byNameOrNull(json['sp_type']) : spType,
      matchmaking: json.containsKey('matchmaking') ? InteractionType.values.byNameOrNull(json['matchmaking']) : matchmaking,
      friendPlay: json.containsKey('friend_play') ? InteractionType.values.byNameOrNull(json['friend_play']) : friendPlay,
      hasAchievements: json.containsKey('has_achievements') ? json['has_achievements'] : hasAchievements,
      hasSteamCloud: json.containsKey('has_steam_cloud') ? json['has_steam_cloud'] : hasSteamCloud,
      isGeforceNow: json.containsKey('is_geforce_now') ? json['is_geforce_now'] : isGeforceNow,
      vrSupport: json.containsKey('vr_support') ? VrSupport.values.byNameOrNull(json['vr_support']) : vrSupport,
      status: json.containsKey('status') ? (GameStatus.values.byNameOrNull(json['status']) ?? GameStatus.planned) : status,
      patchUrl: json.containsKey('patch_url') ? json['patch_url'] : patchUrl,
      userNote: json.containsKey('user_note') ? json['user_note'] : userNote,
      hasFetchedSteam: json.containsKey('has_fetched_steam') ? json['has_fetched_steam'] : hasFetchedSteam,
      hasFetchedGfn: json.containsKey('has_fetched_gfn') ? json['has_fetched_gfn'] : hasFetchedGfn,
      hasFetchedHltb: json.containsKey('has_fetched_hltb') ? json['has_fetched_hltb'] : hasFetchedHltb,
      hltbStats: json.containsKey('hltb_stats') && json['hltb_stats'] != null
          ? HltbStats.fromJson(json['hltb_stats'])
          : hltbStats,
    );
  }

  Game copyWith({
    int? idSteam,
    String? name,
    double? size,
    String? unit,
    double? sizeInBytes,
    bool? isSoftware,
    bool? isFree,
    bool? hasSpanish,
    SpType? spType,
    InteractionType? matchmaking,
    InteractionType? friendPlay,
    bool? hasAchievements,
    bool? hasSteamCloud,
    bool? isGeforceNow,
    VrSupport? vrSupport,
    GameStatus? status,
    String? patchUrl,
    String? userNote,
    bool? hasFetchedSteam,
    bool? hasFetchedGfn,
    bool? hasFetchedHltb,
    HltbStats? hltbStats,
  }) {
    return Game(
      idSteam: idSteam ?? this.idSteam,
      name: name ?? this.name,
      size: size ?? this.size,
      unit: unit ?? this.unit,
      sizeInBytes: sizeInBytes ?? this.sizeInBytes,
      isSoftware: isSoftware ?? this.isSoftware,
      isFree: isFree ?? this.isFree,
      hasSpanish: hasSpanish ?? this.hasSpanish,
      spType: spType ?? this.spType,
      matchmaking: matchmaking ?? this.matchmaking,
      friendPlay: friendPlay ?? this.friendPlay,
      hasAchievements: hasAchievements ?? this.hasAchievements,
      hasSteamCloud: hasSteamCloud ?? this.hasSteamCloud,
      isGeforceNow: isGeforceNow ?? this.isGeforceNow,
      vrSupport: vrSupport ?? this.vrSupport,
      status: status ?? this.status,
      patchUrl: patchUrl ?? this.patchUrl,
      userNote: userNote ?? this.userNote,
      hasFetchedSteam: hasFetchedSteam ?? this.hasFetchedSteam,
      hasFetchedGfn: hasFetchedGfn ?? this.hasFetchedGfn,
      hasFetchedHltb: hasFetchedHltb ?? this.hasFetchedHltb,
      hltbStats: hltbStats ?? this.hltbStats,
    );
  }

  static double _calculateBytes(double size, String unit) => switch (unit) {
    'gb' => size * 1000000000,
    'mb' => size * 1000000,
    'gib' => size * 1073741824,
    'mib' => size * 1048576,
    _ => 0,
  };
}
