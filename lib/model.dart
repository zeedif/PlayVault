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

/// Intervalo de una sincronización automática, en días: [onOpen] la lanza en cada
/// apertura, [manual] solo cuando se pide y cualquier N > 0 cada N días.
abstract final class SyncInterval {
  static const int onOpen = -1;
  static const int manual = 0;
  static const int maxDays = 365;

  /// Margen para que alternar entre apps no repita la consulta en cada regreso.
  static const Duration reopenGap = Duration(minutes: 30);

  /// Con [byCalendar] los días se cuentan por fecha y no por horas: lo sincronizado a
  /// las 23:59 vuelve a tocar al abrir pasada la medianoche.
  static bool isDue(int days, {required bool byCalendar, required DateTime? last, required DateTime now}) {
    if (days == manual) return false;
    if (last == null) return true;
    if (days == onOpen) return now.difference(last) >= reopenGap;
    if (!byCalendar) return now.difference(last) >= Duration(days: days);
    // En UTC para que un cambio de horario no deje un día en 23 o 25 horas.
    final elapsed = DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(last.year, last.month, last.day));
    return elapsed.inDays >= days;
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

enum GameLanguage { english, spanish }
enum SpType { native, simulated, none }
enum InteractionType { none, coop, pvp, both }
enum VrSupport { no, yes, only }

/// Unidad en la que el usuario expresa un peso. Es la única fuente de los factores de
/// conversión: el slider, el detalle y el resumen formatean a partir de aquí.
enum SizeUnit {
  mb(1000000, 'MB'),
  gb(1000000000, 'GB'),
  mib(1048576, 'MiB'),
  gib(1073741824, 'GiB');

  final double bytes;
  final String label;
  const SizeUnit(this.bytes, this.label);

  bool get isLarge => this == gb || this == gib;

  static SizeUnit of({required bool large, required bool binary}) => switch ((large, binary)) {
    (true, true) => gib,
    (true, false) => gb,
    (false, true) => mib,
    (false, false) => mb,
  };

  /// Unidad con la que se muestra una cifra: la grande en cuanto llega a 1 GB/GiB.
  static SizeUnit forBytes(double bytes, {required bool binary}) =>
      of(large: bytes >= of(large: true, binary: binary).bytes, binary: binary);

  static String format(double bytes, {required bool binary}) {
    final unit = forBytes(bytes, binary: binary);
    return '${(bytes / unit.bytes).toStringAsFixed(2)} ${unit.label}';
  }
}

/// Estado con que PCGamingWiki califica una característica, de mejor a peor.
enum Support {
  native,
  limited,
  hackable,
  no,
  unknown;

  /// Se puede usar, sea de serie o con ayuda.
  bool get works => index <= hackable.index;

  /// El mejor de dos estados, con `null` como ausencia de dato.
  Support? best(Support? other) => other == null || index <= other.index ? this : other;

  /// Título del icono de la tabla ("Native support", "Hackable"...).
  static Support parse(String? title) => switch (title?.toLowerCase()) {
    'native support' => native,
    'limited native support' => limited,
    'hackable' => hackable,
    'no native support' => no,
    _ => unknown,
  };
}

/// Enlace con nombre: una traducción, un mod de VR, un arreglo de audio o un parche.
class WebLink({required final String name, required final String url, final String? note}) {
  factory fromJson(Map<String, dynamic> json) => WebLink(
    name: json['name']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
    note: json['note'] as String?,
  );

  Map<String, dynamic> toJson() => {'name': name, 'url': url, if (note != null) 'note': note};

  /// Lista desde JSON, sin repetir URL: la última aparición gana.
  static List<WebLink> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final byUrl = {
      for (final item in raw.whereType<Map>())
        if (WebLink.fromJson(Map<String, dynamic>.from(item)) case final link when link.url.isNotEmpty)
          link.url: link,
    };
    return byUrl.values.toList();
  }
}

class Game({
  final int? idSteam,
  final String? name,
  final double size = 0,
  final SizeUnit unit = SizeUnit.mb,
  final bool? isSoftware,
  final bool? isFree,
  /// Español oficial según la tienda de Steam.
  final bool? hasSpanish,
  /// Traducciones al español ajenas a la tienda: fan translations, parches...
  final List<WebLink> translations = const [],
  final SpType? spType,
  final InteractionType? matchmaking, // Matchmaking, MMO o servidores no autohospedables
  final InteractionType? friendPlay, // Lobbies, LAN, local o servidores autohospedables
  final bool? hasAchievements,
  final bool? hasSteamCloud,
  final bool? isGeforceNow,
  /// VR de serie según Steam o PCGamingWiki; independiente de [vrMods].
  final VrSupport? vrSupport,
  /// Mods o aplicaciones que meten en VR un juego que no lo es de serie.
  final List<WebLink> vrMods = const [],
  /// Arreglos de sonido posicional: DSOAL, OpenAL Soft, HRTF...
  final List<WebLink> audioFixes = const [],
  /// Mejoras imprescindibles de PCGamingWiki: parches no oficiales y similares.
  final List<WebLink> patches = const [],
  /// Control por movimiento: giroscopio del mando o mandos de VR con seguimiento.
  final Support? motion,
  final GameStatus status = GameStatus.planned,
  final String? userNote,
  final bool hasFetchedSteam = false,
  final bool hasFetchedGfn = false,
  /// Si la última sincronización encontró el appid en la cuenta vinculada. `null` mientras
  /// no se haya sincronizado nunca, y en las entradas añadidas a mano sin appid.
  final bool? isOwnedOnSteam,
  final int? hltbFetchedAt,
  final HltbStats? hltbStats,
  /// Título del artículo en PCGamingWiki, una vez localizado.
  final String? pcgwPage,
  final int? pcgwFetchedAt,
}) {
  this : assert(
    idSteam != null || name != null,
    'Un juego debe tener idSteam o un nombre',
  );

  late final double sizeInBytes = size * unit.bytes;

  /// Normaliza el nombre del juego para comparaciones estrictas.
  static String normalizeIdName(String? input) {
    if (input == null) return '';
    return input.toLowerCase()
        .replaceAll(RegExp(r'[™®©]'), '') // Elimina símbolos registrados
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '') // Elimina cualquier texto entre paréntesis
        .trim();
  }

  /// Deriva el internalId a partir de (idSteam, name) SIN instanciar un Game.
  static String internalIdOf(int? idSteam, String? name) => switch ((idSteam, name)) {
    (final int id, final String n) => '${id}_${normalizeIdName(n)}',
    (final int id, null)           => id.toString(),
    (null, final String n)         => normalizeIdName(n),
    (null, null)                   => '',
  };

  /// Identificador único en memoria para ubicar el archivo asociado en la base de datos distribuida.
  /// Incluye el nombre normalizado cuando hay idSteam para diferenciar expansiones
  /// (ej. F.E.A.R. vs F.E.A.R.: Extraction Point) pero evitar duplicados por case-sensitive o tags.
  String get internalId => internalIdOf(idSteam, name);

  /// Idioma de serie; las traducciones de aficionados se cuentan aparte en [hasTranslations].
  GameLanguage get language => hasSpanish == true ? GameLanguage.spanish : GameLanguage.english;

  bool get hasTranslations => translations.isNotEmpty;

  /// VR de serie; sin dato cuenta como [VrSupport.no].
  VrSupport get vr => vrSupport ?? VrSupport.no;

  bool get hasVrMods => vrMods.isNotEmpty;

  /// Indica si los datos de HLTB deben (re)consultarse automáticamente. El software nunca
  /// se auto-consulta (no existe en HLTB). Un juego nunca obtenido se consulta la primera
  /// vez; con [intervalDays] en [SyncInterval.manual] no hay re-consulta periódica.
  bool needsHltbRefresh(int intervalDays, {bool byCalendar = false}) {
    if (isSoftware == true) return false; // las apps no existen en HLTB
    if (hltbFetchedAt == null) return true; // siempre obtener la primera vez
    if (intervalDays <= SyncInterval.manual) return false;
    return SyncInterval.isDue(
      intervalDays,
      byCalendar: byCalendar,
      last: DateTime.fromMillisecondsSinceEpoch(hltbFetchedAt! * 1000),
      now: DateTime.now(),
    );
  }

  /// PCGamingWiki se consulta sola una vez por juego con appid; después, a petición.
  bool get needsPcgwFetch => idSteam != null && isSoftware != true && pcgwFetchedAt == null;

  /// Claves que escribe la cola de Steam: si están todas, el juego ya pasó por ella.
  static const _steamKeys = {
    'name', 'is_software', 'is_free', 'has_spanish', 'sp_type',
    'has_achievements', 'has_steam_cloud', 'vr_support',
  };

  factory fromJson(Map<String, dynamic> json) => Game(
    idSteam: json['id_steam'] as int?,
    name: json['name'] as String?,
    size: (json['size'] as num?)?.toDouble() ?? 0,
    unit: SizeUnit.values.byNameOrNull((json['unit'] as String?)?.toLowerCase()) ?? SizeUnit.mb,
    isSoftware: json['is_software'] as bool?,
    isFree: json['is_free'] as bool?,
    hasSpanish: json['has_spanish'] as bool?,
    translations: WebLink.listFromJson(json['translations']),
    spType: SpType.values.byNameOrNull(json['sp_type'] as String?),
    matchmaking: InteractionType.values.byNameOrNull(json['matchmaking'] as String?),
    friendPlay: InteractionType.values.byNameOrNull(json['friend_play'] as String?),
    hasAchievements: json['has_achievements'] as bool?,
    hasSteamCloud: json['has_steam_cloud'] as bool?,
    isGeforceNow: json['is_geforce_now'] as bool?,
    vrSupport: VrSupport.values.byNameOrNull(json['vr_support'] as String?),
    vrMods: WebLink.listFromJson(json['vr_mods']),
    audioFixes: WebLink.listFromJson(json['audio_fixes']),
    patches: WebLink.listFromJson(json['patches']),
    motion: Support.values.byNameOrNull(json['motion'] as String?),
    status: GameStatus.values.byNameOrNull(json['status'] as String?) ?? GameStatus.planned,
    userNote: json['user_note'] as String?,
    // Sin id no hay nada que pedir a Steam, así que se da por consultado.
    hasFetchedSteam: json['has_fetched_steam'] as bool? ??
        (json['id_steam'] == null || json.keys.toSet().containsAll(_steamKeys)),
    hasFetchedGfn: json['has_fetched_gfn'] as bool? ?? false,
    isOwnedOnSteam: json['is_owned_on_steam'] as bool?,
    hltbFetchedAt: json['hltb_fetched_at'] as int?,
    hltbStats: switch (json['hltb_stats']) {
      final Map<String, dynamic> stats => HltbStats.fromJson(stats),
      _ => null,
    },
    pcgwPage: json['pcgw_page'] as String?,
    pcgwFetchedAt: json['pcgw_fetched_at'] as int?,
  );

  Map<String, dynamic> toJson() => {
    if (idSteam != null) 'id_steam': idSteam,
    if (name != null) 'name': name,
    'size': size,
    'unit': unit.name,
    if (isSoftware != null) 'is_software': isSoftware,
    if (isFree != null) 'is_free': isFree,
    if (hasSpanish != null) 'has_spanish': hasSpanish,
    if (translations.isNotEmpty) 'translations': [for (final l in translations) l.toJson()],
    if (spType != null) 'sp_type': spType!.name,
    if (matchmaking != null) 'matchmaking': matchmaking!.name,
    if (friendPlay != null) 'friend_play': friendPlay!.name,
    if (hasAchievements != null) 'has_achievements': hasAchievements,
    if (hasSteamCloud != null) 'has_steam_cloud': hasSteamCloud,
    if (isGeforceNow != null) 'is_geforce_now': isGeforceNow,
    if (vrSupport != null) 'vr_support': vrSupport!.name,
    if (vrMods.isNotEmpty) 'vr_mods': [for (final l in vrMods) l.toJson()],
    if (audioFixes.isNotEmpty) 'audio_fixes': [for (final l in audioFixes) l.toJson()],
    if (patches.isNotEmpty) 'patches': [for (final l in patches) l.toJson()],
    if (motion != null) 'motion': motion!.name,
    'status': status.name,
    if (userNote != null) 'user_note': userNote,
    'has_fetched_steam': hasFetchedSteam,
    'has_fetched_gfn': hasFetchedGfn,
    if (isOwnedOnSteam != null) 'is_owned_on_steam': isOwnedOnSteam,
    'hltb_fetched_at': hltbFetchedAt,
    if (hltbStats != null) 'hltb_stats': hltbStats!.toJson(),
    if (pcgwPage != null) 'pcgw_page': pcgwPage,
    if (pcgwFetchedAt != null) 'pcgw_fetched_at': pcgwFetchedAt,
  };

  /// Aplica un parche parcial desde un Map JSON, preservando los campos no presentes.
  /// Una clave con `null` sí vacía el campo; una ausente lo deja como estaba.
  Game updateFromJson(Map<String, dynamic> json) => Game.fromJson({...toJson(), ...json});
}
