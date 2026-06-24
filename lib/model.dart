import 'hltb_service.dart';

extension EnumByNameOrNull<T extends Enum> on Iterable<T> {
  T? byNameOrNull(String? name) {
    if (name == null) return null;
    for (final value in this) {
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

class Game({
  final int? idSteam,
  final String? name,
  required final double size,
  required final String unit,
  required final double sizeInBytes,
  final bool? isSoftware,
  final bool? isFree,
  final bool? hasSpanish,
  final SpType? spType,
  final InteractionType? matchmaking, // Matchmaking, MMO o servidores no autohospedables
  final InteractionType? friendPlay, // Lobbies, LAN, local o servidores autohospedables
  final bool? hasAchievements,
  final bool? hasSteamCloud,
  final bool? isGeforceNow,
  final VrSupport? vrSupport,
  final GameStatus status = GameStatus.planned,
  final String? patchUrl,
  final String? userNote,
  final bool hasFetchedSteam = false,
  final bool hasFetchedGfn = false,
  final bool hasFetchedHltb = false,
  final HltbStats? hltbStats,
}) {
  this : assert(
    idSteam != null || name != null,
    'Un juego debe tener idSteam o un nombre',
  );

  /// Normaliza el nombre del juego para comparaciones estrictas.
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
  String get internalId => switch ((idSteam, name)) {
    (final int id, final String n) => '${id}_${normalizeIdName(n)}',
    (final int id, null)           => id.toString(),
    (null, final String n)         => normalizeIdName(n),
    (null, null)                   => '',
  };

  /// Determina el idioma basado en las propiedades.
  GameLanguage get language {
    if (patchUrl case final url? when url.trim().isNotEmpty) return GameLanguage.patched;
    return hasSpanish == true ? GameLanguage.spanish : GameLanguage.english;
  }

  factory fromJson(Map<String, dynamic> json) {
    final size = (json['size'] ?? 0).toDouble() as double;
    final unit = (json['unit'] ?? 'mb').toString().toLowerCase();

    final fetchedSteam = (json['has_fetched_steam'] as bool?) ?? switch (json) {
      // _ when json['has_fetched_steam'] == true => true, // inalcanzable
      // Sin id, marcamos como fetchedSteam=true para que no intente el fetch.
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

    final fetchedHltb = (json['has_fetched_hltb'] as bool?) ??
        (json['id_steam'] == null || json['hltb_stats'] != null);

    return Game(
      idSteam: json['id_steam'] as int?,
      name: json['name'] as String?,
      size: size,
      unit: unit,
      sizeInBytes: _calculateBytes(size, unit),
      isSoftware: json['is_software'] as bool?,
      isFree: json['is_free'] as bool?,
      hasSpanish: json['has_spanish'] as bool?,
      spType: SpType.values.byNameOrNull(json['sp_type'] as String?),
      matchmaking: InteractionType.values.byNameOrNull(json['matchmaking'] as String?),
      friendPlay: InteractionType.values.byNameOrNull(json['friend_play'] as String?),
      hasAchievements: json['has_achievements'] as bool?,
      hasSteamCloud: json['has_steam_cloud'] as bool?,
      isGeforceNow: json['is_geforce_now'] as bool?,
      vrSupport: VrSupport.values.byNameOrNull(json['vr_support'] as String?),
      status: GameStatus.values.byNameOrNull(json['status'] as String?) ?? GameStatus.planned,
      patchUrl: json['patch_url'] as String?,
      userNote: json['user_note'] as String?,
      hasFetchedSteam: fetchedSteam,
      hasFetchedGfn: (json['has_fetched_gfn'] as bool?) ?? false,
      hasFetchedHltb: fetchedHltb,
      hltbStats: json['hltb_stats'] != null ? HltbStats.fromJson(json['hltb_stats'] as Map<String, dynamic>) : null,
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

  /// Aplica un parche parcial desde un Map JSON, preservando los campos no presentes.
  /// La función local `pick<T>` centraliza la semántica de "containsKey o fallback".
  Game updateFromJson(Map<String, dynamic> json) {
    // Type-safe: si el valor existe pero no es T (incluyendo null con T no-nullable),
    // retorna el campo actual en lugar de lanzar.
    T pick<T>(String key, T current) {
      if (!json.containsKey(key)) return current;
      final v = json[key];
      return v is T ? v : current;
    }

    final newSize = json.containsKey('size') ? (json['size'] as num).toDouble() : size;
    final newUnit = json.containsKey('unit') ? json['unit'].toString().toLowerCase() : unit;

    return Game(
      idSteam: pick('id_steam', idSteam),
      name: pick('name', name),
      size: newSize,
      unit: newUnit,
      sizeInBytes: _calculateBytes(newSize, newUnit),
      isSoftware: pick('is_software', isSoftware),
      isFree: pick('is_free', isFree),
      hasSpanish: pick('has_spanish', hasSpanish),
      spType: json.containsKey('sp_type') ? SpType.values.byNameOrNull(json['sp_type'] as String?) : spType,
      matchmaking: json.containsKey('matchmaking') ? InteractionType.values.byNameOrNull(json['matchmaking'] as String?) : matchmaking,
      friendPlay: json.containsKey('friend_play') ? InteractionType.values.byNameOrNull(json['friend_play'] as String?) : friendPlay,
      hasAchievements: pick('has_achievements', hasAchievements),
      hasSteamCloud: pick('has_steam_cloud', hasSteamCloud),
      isGeforceNow: pick('is_geforce_now', isGeforceNow),
      vrSupport: json.containsKey('vr_support') ? VrSupport.values.byNameOrNull(json['vr_support'] as String?) : vrSupport,
      status: json.containsKey('status') ? (GameStatus.values.byNameOrNull(json['status'] as String?) ?? GameStatus.planned) : status,
      patchUrl: pick('patch_url', patchUrl),
      userNote: pick('user_note', userNote),
      hasFetchedSteam: pick('has_fetched_steam', hasFetchedSteam),
      hasFetchedGfn: pick('has_fetched_gfn', hasFetchedGfn),
      hasFetchedHltb: pick('has_fetched_hltb', hasFetchedHltb),
      hltbStats: json.containsKey('hltb_stats') && json['hltb_stats'] != null ? HltbStats.fromJson(json['hltb_stats'] as Map<String, dynamic>) : hltbStats,
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
  }) => Game(
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

  static double _calculateBytes(double size, String unit) => switch (unit) {
    'gb' => size * 1000000000,
    'mb' => size * 1000000,
    'gib' => size * 1073741824,
    'mib' => size * 1048576,
    _ => 0,
  };
}
