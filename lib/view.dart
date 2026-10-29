import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_dimensions.dart';
import 'hltb_service.dart';
import 'launcher_service.dart';
import 'model.dart';
import 'pcgw_service.dart';
import 'state.dart';
import 'steam_service.dart';

final Random _random = Random();
const List<String> _imgExts = ['.png', '.jpg', '.jpeg', '.webp'];
const List<InteractionType> _activeInteractions = [
  InteractionType.coop,
  InteractionType.pvp,
  InteractionType.both,
];

// ==========================================
// TEXTOS Y COLORES DE LOS ENUMS
// ==========================================
extension on GameStatus {
  String get label => switch (this) {
    GameStatus.planned => 'Planeado',
    GameStatus.playing => 'Jugando',
    GameStatus.beaten => 'Terminado',
    GameStatus.completed => 'Platinado',
    GameStatus.paused => 'Suspendido',
    GameStatus.dropped => 'Abandonado',
    GameStatus.discarded => 'Descartado',
  };

  Color color(bool isDark) => switch ((this, isDark)) {
    (GameStatus.completed, true) => const Color(0x26E5E9F0),
    (GameStatus.completed, false) => const Color(0x1ED1D9E6),
    (GameStatus.beaten, true) => const Color(0x263DDB85),
    (GameStatus.beaten, false) => const Color(0x1E3CA059),
    (GameStatus.dropped, _) => const Color(0x26D73A49),
    (GameStatus.paused, true) => const Color(0x26FFB74D),
    (GameStatus.paused, false) => const Color(0x1EE87400),
    (GameStatus.playing, _) => const Color(0x26C597FF),
    (GameStatus.planned, true) => const Color(0x2687A9FF),
    (GameStatus.planned, false) => const Color(0x1E2483E2),
    (GameStatus.discarded, _) => const Color(0x269E9E9E),
  };
}

extension on GameLanguage {
  String get label => switch (this) { GameLanguage.english => 'Inglés', GameLanguage.spanish => 'Español' };
}

extension on SliderDistribution {
  String get label => switch (this) { SliderDistribution.discrete => 'Discreta', SliderDistribution.quadratic => 'Cuadrática', SliderDistribution.cubic => 'Cúbica' };
}

extension on SpType {
  String get label => switch (this) { SpType.native => 'Nativo', SpType.simulated => 'Con Bots / Alternado', SpType.none => 'Sin Solitario' };
}

extension on InteractionType {
  String get label => switch (this) { InteractionType.none => 'Ninguno', InteractionType.coop => 'Cooperativo', InteractionType.pvp => 'Competitivo', InteractionType.both => 'Ambos (Coop + JcJ)' };
}

extension on ExperienceFilter {
  String get label => switch (this) { ExperienceFilter.any => 'Cualquiera', ExperienceFilter.coop => 'Solo Cooperativo', ExperienceFilter.pvp => 'Solo Competitivo', ExperienceFilter.both => 'Ambos' };
}

extension on VrSupport {
  String get label => switch (this) { VrSupport.no => 'Sin VR', VrSupport.yes => 'VR opcional', VrSupport.only => 'Solo VR' };
}

extension on SortBy {
  String get label => switch (this) { SortBy.name => 'Nombre', SortBy.size => 'Peso', SortBy.hltbMain => 'T. Historia', SortBy.hltbExtras => 'T. Extras', SortBy.hltbComplete => 'T. Platinado' };
}

extension on Support {
  String get label => switch (this) { Support.native => 'de serie', Support.limited => 'limitado', Support.hackable => 'con ayuda', Support.no => 'no', Support.unknown => '?' };
}

/// Nombre con el que el filtro enseña cada valor de idioma, solitario o VR.
String _enumLabel(Enum value) => switch (value) {
  GameLanguage() => value.label,
  SpType() => value.label,
  VrSupport() => value.label,
  _ => value.name,
};

String _formatDuration(int? minutes) {
  if (minutes == null || minutes <= 0) return '--';
  return switch ((minutes ~/ 60, minutes % 60)) {
    (0, final mm) => '${mm}m',
    (final hh, 0) => '${hh}h',
    (final hh, final mm) => '${hh}h ${mm}m',
  };
}

/// Cifra del tamaño en [unit], sin decimales cuando es exacta.
String _formatIn(double bytes, SizeUnit unit) {
  final value = bytes / unit.bytes;
  return value == value.toInt() ? value.toInt().toString() : value.toStringAsFixed(2);
}

String? _getEsDeMediaPath(String? basePath, String folder, String? gameName) {
  if (basePath == null || basePath.isEmpty || gameName == null) return null;
  final safeName = gameName.replaceAll(RegExp(r'[/:?*\\<>|]'), '_');
  final dirPath = '$basePath/downloaded_media/steam/$folder';
  if (!Directory(dirPath).existsSync()) return null;

  for (final ext in _imgExts) {
    final path = '$dirPath/$safeName$ext';
    if (File(path).existsSync()) return path;
  }
  return null;
}

Future<void> _openUrl(String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Formatea un recuento de juegos con la unidad singular/plural correcta.
String _games(int n) => n == 1 ? '1 juego' : '$n juegos';

/// Resumen para el SnackBar de éxito tras aplicar un [ImportPlan].
String _importSummary(ImportPlan plan) {
  if (plan.replace) {
    return 'Biblioteca reemplazada: ${_games(plan.incoming)} importados.';
  }
  final parts = [
    if (plan.added > 0) '${_games(plan.added)} añadidos',
    if (plan.merged > 0) '${_games(plan.merged)} ${plan.preserveExisting ? 'actualizados' : 'sobrescritos'}',
  ];
  return parts.isEmpty
      ? 'No había nada que importar.'
      : 'Importación completada: ${parts.join(' y ')}.';
}

/// Diálogo de confirmación (destructivo) que se muestra SOLO cuando la importación borra o
/// sobrescribe datos. Presenta las cifras exactas ya calculadas en el [ImportPlan] y devuelve
/// true si el usuario confirma. Se apila sobre el diálogo de importación: «Cancelar» regresa
/// a él con el contenido intacto.
Future<bool?> _confirmImport(BuildContext context, ImportPlan plan) {
  final scheme = Theme.of(context).colorScheme;
  final message = plan.replace
      ? 'Se eliminarán tus ${_games(plan.deleted)} actuales y se reemplazarán por '
          '${_games(plan.incoming)} del archivo. Esta acción no se puede deshacer.'
      // merge sin preservar, con coincidencias: se reinician las propiedades ausentes.
      : 'De los ${_games(plan.incoming)} del archivo, ${_games(plan.merged)} ya existen y '
          'se sobrescribirán por completo: las propiedades que no vengan en el JSON se reiniciarán '
          'a sus valores por defecto.'
          '${plan.added > 0 ? ' Se añadirán ${_games(plan.added)} nuevos.' : ''}'
          ' Esta acción no se puede deshacer.';
  return showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: const Text('Confirmar importación'),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancelar')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(dctx, true),
          child: Text(plan.replace ? 'Reemplazar' : 'Sobrescribir'),
        ),
      ],
    ),
  );
}

// ==========================================
// VINCULACIÓN CON STEAM
// ==========================================

String _steamFailureMessage(SteamFailure reason) => switch (reason) {
  SteamFailure.badInput => 'Escribe tu SteamID64, tu nombre personalizado o la URL de tu perfil.',
  SteamFailure.notFound => 'No existe ningún perfil de Steam con esos datos.',
  SteamFailure.network => 'No se pudo contactar con Steam. Revisa la conexión.',
  SteamFailure.badKey => 'La API key no es válida.',
  SteamFailure.needsKey => 'Hace falta una API key: Steam ya no deja leer la lista de juegos sin ella.',
  SteamFailure.privateProfile =>
    'El perfil no comparte su lista de juegos. Hazla pública o usa la API key de esa misma cuenta.',
  SteamFailure.emptyLibrary => 'El perfil no tiene ningún juego visible.',
  SteamFailure.notLinked => 'No hay ninguna cuenta de Steam vinculada.',
  SteamFailure.busy => 'Ya hay una importación de Steam en curso.',
};

String _alreadyTracked(int n) => n == 1 ? 'uno ya estaba' : '$n ya estaban';

String _steamSyncMessage(SteamSync result) => switch (result) {
  SteamSyncFailed(:final reason) => 'No se pudo importar la biblioteca de Steam. ${_steamFailureMessage(reason)}',
  SteamSyncDone(added: 0, :final updated) => 'Steam: ningún juego que importar, ${_alreadyTracked(updated)}.',
  SteamSyncDone(:final added, :final updated) =>
    'Steam: ${added == 1 ? 'Un juego importado' : '$added juegos importados'} de tu cuenta'
    '${updated > 0 ? ', ${_alreadyTracked(updated)}' : ''}.',
};

String _formatEpoch(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

enum _LibraryFate { cancel, keep, wipe }

/// Al cambiar de cuenta o desvincular, decide qué pasa con lo ya rastreado: conservarlo
/// y añadir encima lo de la cuenta nueva, o vaciar la biblioteca junto con todos sus datos.
Future<_LibraryFate> _askLibraryFate(BuildContext context, int gameCount, {required bool unlinking}) async {
  final scheme = Theme.of(context).colorScheme;
  final fate = await showDialog<_LibraryFate>(
    context: context,
    builder: (dctx) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(unlinking ? '¿Qué hago con tus juegos?' : '¿Qué hago con la biblioteca actual?'),
      content: Text(
        unlinking
            ? 'Vas a desvincular la cuenta. Puedes conservar ${_games(gameCount)} que ya rastreas '
                'o vaciar la biblioteca con todos sus datos (estados, notas, tiempos y metadatos).'
            : 'Vas a cambiar la vinculación de Steam. Puedes conservar ${_games(gameCount)} que ya '
                'rastreas y añadir encima los de la cuenta nueva, o vaciar la biblioteca con todos '
                'sus datos (estados, notas, tiempos y metadatos) antes de importarla.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dctx, _LibraryFate.cancel), child: const Text('Cancelar')),
        TextButton(onPressed: () => Navigator.pop(dctx, _LibraryFate.keep), child: const Text('Conservar')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(dctx, _LibraryFate.wipe),
          child: const Text('Vaciar'),
        ),
      ],
    ),
  );
  return fate ?? _LibraryFate.cancel;
}

/// Formulario de vinculación. El perfil basta para importar los juegos públicos; la API
/// key (de esa misma cuenta) añade además los que estén marcados como privados.
class _SteamAccountDialog extends StatefulWidget {
  const _SteamAccountDialog();

  @override
  State<_SteamAccountDialog> createState() => _SteamAccountDialogState();
}

class _SteamAccountDialogState extends State<_SteamAccountDialog> {
  late final HomeCubit _cubit = context.read<HomeCubit>();
  late final _profileCtrl = TextEditingController(text: _cubit.state.steamId ?? '');
  late final _keyCtrl = TextEditingController(text: _cubit.steamApiKey ?? '');
  bool _obscureKey = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _profileCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });

    final key = _keyCtrl.text.trim();
    switch (await _cubit.resolveSteamAccount(_profileCtrl.text, key)) {
      case SteamFail(:final reason):
        if (mounted) {
          setState(() {
            _busy = false;
            _error = _steamFailureMessage(reason);
          });
        }
      case SteamOk(:final value):
        if (!mounted) return;
        var wipe = false;
        // Solo se pregunta si hay algo que perder Y la vinculación deja de ser la misma.
        if (_cubit.state.gameCount > 0 &&
            (value.id64 != _cubit.state.steamId || key != (_cubit.steamApiKey ?? ''))) {
          final fate = await _askLibraryFate(context, _cubit.state.gameCount, unlinking: false);
          if (!mounted || fate == _LibraryFate.cancel) {
            if (mounted) setState(() => _busy = false);
            return;
          }
          wipe = fate == _LibraryFate.wipe;
        }

        await _cubit.linkSteamAccount(value, apiKey: key, wipeLibrary: wipe);
        if (mounted) Navigator.pop(context);
        messenger.showSnackBar(SnackBar(
          content: Text('Cuenta vinculada: ${value.persona ?? value.id64}. Importando biblioteca...'),
          duration: const Duration(minutes: 1),
        ));
        final result = await _cubit.syncSteamLibrary();
        // Sin retirar el aviso de progreso, el resultado esperaría en cola tras él.
        messenger.removeCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(_steamSyncMessage(result))));
    }
  }

  Future<void> _unlink() async {
    var wipe = false;
    if (_cubit.state.gameCount > 0) {
      final fate = await _askLibraryFate(context, _cubit.state.gameCount, unlinking: true);
      if (!mounted || fate == _LibraryFate.cancel) return;
      wipe = fate == _LibraryFate.wipe;
    }
    await _cubit.unlinkSteamAccount(wipeLibrary: wipe);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = _cubit.state;

    return AlertDialog(
      title: const Text('Vincular cuenta de Steam'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.medium,
            children: [
              if (state.hasSteamAccount)
                Container(
                  padding: AppInsets.allMedium,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: AppRadius.small,
                  ),
                  child: Row(
                    spacing: AppSpacing.medium,
                    children: [
                      Icon(Icons.account_circle, color: scheme.primary),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.steamPersona ?? state.steamId!,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              [
                                if (state.steamPersona != null) state.steamId!,
                                if (state.steamSyncedAt case final ts?) 'Última importación: ${_formatEpoch(ts)}',
                              ].join('\n'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _profileCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Perfil de Steam',
                  hintText: 'URL, nombre personalizado o SteamID64',
                  helperText: 'Cuenta de la que se importan los juegos.',
                  border: OutlineInputBorder(borderRadius: AppRadius.small),
                ),
              ),
              TextField(
                controller: _keyCtrl,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'API key',
                  helperText: 'Si es la clave de ese mismo perfil, incluye sus juegos privados.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(borderRadius: AppRadius.small),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureKey ? Icons.visibility_off : Icons.visibility, size: AppIconSize.medium),
                    tooltip: _obscureKey ? 'Mostrar' : 'Ocultar',
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.vpn_key, size: AppIconSize.medium),
                  label: const Text('Obtener una API key'),
                  onPressed: () => _openUrl('https://steamcommunity.com/dev/apikey'),
                ),
              ),
              if (_error case final message?)
                Text(message, style: TextStyle(color: scheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        if (state.hasSteamAccount)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: _busy ? null : _unlink,
            child: const Text('Desvincular'),
          ),
        ListenableBuilder(
          listenable: Listenable.merge([_profileCtrl, _keyCtrl]),
          builder: (ctx, _) => ElevatedButton(
            onPressed: _busy || _profileCtrl.text.trim().isEmpty || _keyCtrl.text.trim().isEmpty
                ? null
                : _link,
            child: _busy
                ? const SizedBox(width: AppIconSize.medium, height: AppIconSize.medium, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Vincular'),
          ),
        ),
      ],
    );
  }
}

/// Abre el detalle de un juego. Dispara la auto-consulta de HLTB (efecto único de
/// "al abrir") aquí, en el sitio de llamada, en lugar de en el initState de un
/// StatefulWidget: el diálogo queda como StatelessWidget puro y no arrastra estado extra.
void _openGameDialog(BuildContext context, Game game) {
  final cubit = context.read<HomeCubit>();
  // Auto-consulta de HLTB al abrir el detalle, si el ajuste está activo y los
  // datos nunca se obtuvieron o superaron el intervalo de refresco configurado.
  if (cubit.state.hltbAutoRefreshOnDetail) {
    final current = cubit.gameById(game.internalId) ?? game;
    if (current.idSteam != null && current.needsHltbRefresh(cubit.state.refreshIntervalDays, byCalendar: cubit.state.hltbRefreshByCalendar)) {
      cubit.refetchHltbForGame(current);
    }
  }
  showDialog(
    context: context,
    builder: (ctx) => _GameDialog(gameId: game.internalId, initialGame: game),
  );
}

// ==========================================
// WIDGET PRINCIPAL
// ==========================================
/// Relanza la sincronización automática cada vez que la app vuelve a primer plano: en
/// móvil rara vez se cierra, así que "al abrir" incluye regresar a ella.
class _AutoSyncScope extends StatefulWidget {
  final Widget child;
  const _AutoSyncScope({required this.child});

  @override
  State<_AutoSyncScope> createState() => _AutoSyncScopeState();
}

class _AutoSyncScopeState extends State<_AutoSyncScope> {
  late final HomeCubit _cubit = context.read<HomeCubit>();
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<SteamSync> _events;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _cubit.runAutoSync);
    _events = _cubit.steamAutoSyncEvents.listen((result) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_steamSyncMessage(result))));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _events.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) => const _AutoSyncScope(child: _HomeScaffold());
}

enum _MenuAction {
  import('Importar biblioteca'),
  export('Exportar biblioteca'),
  clear('Vaciar biblioteca'),
  updateGfn('Sincronizar datos de GeForce NOW'),
  refetchSteam('Sincronizar datos de Steam'),
  refetchHltb('Sincronizar datos de HLTB'),
  refetchPcgw('Sincronizar datos de PCGamingWiki'),
  steamLink('Vincular cuenta de Steam'),
  steamSync('Importar biblioteca de Steam'),
  esDePath('Vincular carpeta de ES-DE');

  final String label;
  const _MenuAction(this.label);
}

class _HomeScaffold extends StatelessWidget {
  const _HomeScaffold();

  @override
  Widget build(BuildContext context) {
    final isLoading = context.select((HomeCubit c) => c.state.isLoading);
    final hasGames = context.select((HomeCubit c) => c.state.gameCount > 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis juegos'),
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.casino_outlined),
            tooltip: 'Juego aleatorio',
            onPressed: () {
              final games = context.read<HomeCubit>().state.filteredGames;
              if (games.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No hay juegos disponibles con los filtros actuales.')),
                );
                return;
              }
              _openGameDialog(context, games[_random.nextInt(games.length)]);
            },
          ),
          PopupMenuButton<_MenuAction>(
            onSelected: (action) => _onMenuAction(context, action),
            itemBuilder: (context) => [
              for (final action in _MenuAction.values)
                if (action != _MenuAction.refetchPcgw || PcgwService.enabled) ...[
                  if (action case _MenuAction.updateGfn || _MenuAction.steamLink) const PopupMenuDivider(),
                  PopupMenuItem(
                    value: action,
                    enabled: action != _MenuAction.steamSync || context.read<HomeCubit>().state.hasSteamAccount,
                    child: Text(action.label),
                  ),
                ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 0,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CompactControls(),
                Divider(height: 1),
              ],
            ),
          ),
          if (isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 12)))
          else if (!hasGames)
            const Expanded(
              child: Padding(
                padding: AppInsets.horizontalLarge,
                child: Center(
                  child: Text(
                    'No hay datos. Importa un JSON o vincula tu cuenta de Steam para comenzar.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else ...[
            const _SummaryText(),
            const Expanded(child: _GamesList()),
          ],
        ],
      ),
    );
  }

  Future<void> _onMenuAction(BuildContext context, _MenuAction action) async {
    final cubit = context.read<HomeCubit>();
    final messenger = ScaffoldMessenger.of(context);
    void notify(String message) => messenger.showSnackBar(SnackBar(content: Text(message)));

    switch (action) {
      case _MenuAction.import:
        _showJsonDialog(context);
      case _MenuAction.export:
        _exportJson(context);
      case _MenuAction.clear:
        _showClearConfirmDialog(context);
      case _MenuAction.updateGfn:
        cubit.fetchGeforceNowDatabase();
        notify('Sincronizando datos de GeForce NOW en segundo plano...');
      case _MenuAction.refetchSteam:
        cubit.refetchSteamAll();
        notify('Sincronizando datos de Steam en segundo plano...');
      case _MenuAction.refetchHltb:
        cubit.refetchHltbAll();
        notify('Sincronizando datos de HLTB en segundo plano...');
      case _MenuAction.refetchPcgw:
        cubit.refetchPcgwAll();
        notify('Sincronizando datos de PCGamingWiki en segundo plano...');
      case _MenuAction.steamLink:
        showDialog(context: context, builder: (_) => const _SteamAccountDialog());
      case _MenuAction.steamSync:
        notify(_steamSyncMessage(await cubit.syncSteamLibrary()));
      case _MenuAction.esDePath:
        if (await FilePicker.getDirectoryPath() case final directory?) {
          cubit.updateFlag(esDePath: directory);
          notify('Carpeta de ES-DE vinculada con éxito.');
        }
    }
  }

  Future<void> _exportJson(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Exportar/Guardar JSON',
        fileName: 'mis_juegos.json',
        bytes: Uint8List.fromList(utf8.encode(context.read<HomeCubit>().exportGamesJson())),
      );

      if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('Archivo guardado con éxito.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error al guardar el archivo: $e')));
    }
  }

  void _showJsonDialog(BuildContext context) {
    final TextEditingController jsonCtrl = TextEditingController();
    String? selectedFileName;
    bool replace = false; // por defecto: añadir/actualizar (no reemplazar toda la biblioteca)
    bool preserveExisting = true; // por defecto: en fusiones, conservar las propiedades ausentes del JSON

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final scheme = Theme.of(context).colorScheme;
          return AlertDialog(
            title: const Text('Importar biblioteca'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AppSpacing.medium,
                  children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: AppInsets.allMedium,
                        shape: AppRadius.smallShape,
                        backgroundColor: scheme.primary.withValues(alpha: 0.05),
                        side: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
                      ),
                      onPressed: () async {
                        try {
                          final result = await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['json', 'txt'],
                          );

                          if (result.singleOrNull?.path case final path?) {
                            final content = await File(path).readAsString();
                            setState(() {
                              selectedFileName = path;
                              jsonCtrl.text = content;
                            });
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Error al leer archivo: $e')),
                            );
                          }
                        }
                      },
                      child: Row(
                        spacing: AppSpacing.medium,
                        children: [
                          Icon(Icons.folder_open, color: scheme.primary, size: AppIconSize.large),
                          Expanded(
                            child: Text(
                              selectedFileName ?? 'Tocar para elegir archivo...',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: selectedFileName == null ? null : scheme.primary,
                                fontWeight: selectedFileName == null ? FontWeight.normal : FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextField(
                      controller: jsonCtrl,
                      maxLines: 12,
                      decoration: InputDecoration(
                        hintText: 'Pega el JSON aquí o selecciónalo desde el botón superior...',
                        contentPadding: AppInsets.allMedium,
                        border: OutlineInputBorder(borderRadius: AppRadius.small),
                      ),
                    ),
                    // Eje 1: reemplazar TODA la biblioteca (borra los juegos que no vengan en el import).
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Reemplazar biblioteca'),
                      subtitle: Text(replace
                          ? 'Se borrarán todos los juegos antes de importar.'
                          : 'Actualmente se añaden los nuevos y se actualizan los existentes.'),
                      value: replace,
                      onChanged: (v) => setState(() => replace = v),
                    ),
                    // Eje 2 (encadenado): en fusiones, qué hacer con las propiedades que el JSON omite
                    // de un juego que YA existe. Si «Reemplazar» está activo no hay nada que conservar
                    // (se borra todo), así que este control se deshabilita y se fuerza visualmente a OFF.
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Conservar propiedades existentes'),
                      subtitle: Text(switch ((replace, preserveExisting)) {
                        (true, _) => 'No aplica al reemplazar: se descarta todo lo anterior.',
                        (false, true) => 'Solo se actualizan las propiedades presentes en el JSON; el resto se mantiene.',
                        (false, false) => 'Las propiedades ausentes del JSON se reinician a sus valores por defecto.',
                      }),
                      value: !replace && preserveExisting,
                      onChanged: replace ? null : (v) => setState(() => preserveExisting = v),
                    ),
                    // Alerta encadenada: al activar «Reemplazar» avisamos de que se pierde lo ya definido.
                    if (replace)
                      Container(
                        padding: AppInsets.allMedium,
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: AppRadius.small,
                        ),
                        child: Row(
                          spacing: AppSpacing.medium,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                            Expanded(
                              child: Text(
                                'No se van a conservar las propiedades que ya tenías definidas de los juegos.',
                                style: TextStyle(color: scheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: jsonCtrl,
                builder: (c, value, _) => ElevatedButton(
                  style: replace
                      ? ElevatedButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        )
                      : null,
                  onPressed: value.text.trim().isEmpty
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final cubit = context.read<HomeCubit>();
                          switch (cubit.analyzeImport(jsonCtrl.text, replace: replace, preserveExisting: preserveExisting)) {
                            case InvalidImport():
                              messenger.showSnackBar(const SnackBar(
                                content: Text('El texto no es un JSON de biblioteca válido.'),
                              ));
                            case EmptyImport():
                              messenger.showSnackBar(const SnackBar(
                                content: Text('El JSON no contiene juegos con id_steam o nombre válidos.'),
                              ));
                            case ReadyImport(:final plan):
                              // Pedimos confirmación extra si la operación destruye datos.
                              if (plan.isDestructive && await _confirmImport(ctx, plan) != true) return; // cancelar: regresa al diálogo intacto
                              await cubit.applyImport(plan);
                              if (ctx.mounted) Navigator.pop(ctx);
                              messenger.showSnackBar(SnackBar(content: Text(_importSummary(plan))));
                          }
                        },
                  child: Text(replace ? 'Reemplazar' : 'Importar'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showClearConfirmDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar todo?'),
        content: const Text('Se borrarán todos los juegos guardados localmente en la app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              context.read<HomeCubit>().clearLibrary();
              Navigator.pop(ctx);
            },
            child: const Text('Limpiar'),
          ),
        ],
      ),
    );
  }
}

class _SummaryText extends StatelessWidget {
  const _SummaryText();

  @override
  Widget build(BuildContext context) {
    final count = context.select((HomeCubit c) => c.state.filteredGames.length);
    final bytes = context.select((HomeCubit c) => c.state.totalBytes);
    final isBinary = context.select((HomeCubit c) => c.state.binaryFormat);

    return Padding(
      padding: AppInsets.verticalSmall,
      child: Text(
        "RESULTADOS: $count | PESO: ${SizeUnit.format(bytes, binary: isBinary)}",
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context) {
    final tooltip = context.select((HomeCubit c) => [
      'Sincronizando:',
      if (c.state.isFetchingGfnDb) '• GeForce NOW: descargando catálogo',
      if (c.state.isSyncingSteamLibrary) '• Steam: leyendo la biblioteca de la cuenta',
      if (c.state.isFetchingSteam) '• Steam: ${c.state.steamQueueSize} pendientes',
      if (c.state.isFetchingHltb) '• HLTB: ${c.state.hltbQueueSize} pendientes',
      if (c.state.isFetchingPcgw) '• PCGamingWiki: ${c.state.pcgwQueueSize} pendientes',
    ].join('\n'));

    return IconButton(
      tooltip: tooltip,
      onPressed: () {},
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: CircularProgressIndicator(
        strokeWidth: 2,
        color: Theme.of(context).colorScheme.primary,
        padding: EdgeInsets.zero,
        strokeAlign: CircularProgressIndicator.strokeAlignInside,
      ),
    );
  }
}

class _CompactControls extends StatelessWidget {
  const _CompactControls();

  @override
  Widget build(BuildContext context) {
    final hasGames = context.select((HomeCubit c) => c.state.gameCount > 0);
    final sortBy = context.select((HomeCubit c) => c.state.sortBy);
    final sortAsc = context.select((HomeCubit c) => c.state.sortAsc);
    final isSyncing = context.select((HomeCubit c) => c.state.isSyncing);
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: AppInsets.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Mínimo del _SliderControls: 440.61619186401332 + 36
          final useTwoRows = hasGames && constraints.maxWidth < 476.62;
          final topRow = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: AppSpacing.small,
            children: [
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.filter_alt, size: AppIconSize.medium),
                  label: const Text('Filtros'),
                  style: OutlinedButton.styleFrom(shape: AppRadius.smallShape),
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (ctx) => const _FilterBottomSheet(),
                  ),
                ),
              ),
              if (isSyncing) const _SyncIndicator(),

              if (hasGames && !useTwoRows)
                const Expanded(
                  child: _SliderControls(),
                )
              else
                const Spacer(),

              IntrinsicWidth(
                child: InputDecorator(
                  decoration: InputDecoration(
                    label: const Padding(
                      padding: EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.tiny),
                      child: Text('Orden'),
                    ),
                    isDense: true,
                    labelStyle: TextStyle(color: primary),
                    floatingLabelStyle: TextStyle(color: primary),
                    contentPadding: EdgeInsets.zero,
                    border: const OutlineInputBorder(gapPadding: 0, borderRadius: AppRadius.small),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<SortBy>(
                      value: sortBy,
                      isDense: true,
                      isExpanded: true,
                      padding: AppInsets.control,
                      borderRadius: AppRadius.small,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: primary,
                      ),
                      icon: Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.small),
                        child: Icon(Icons.sort, size: AppIconSize.medium, color: primary),
                      ),
                      items: [
                        for (final sort in SortBy.values) DropdownMenuItem(value: sort, child: Text(sort.label)),
                      ],
                      onChanged: (val) => context.read<HomeCubit>().updateFlag(sort: val),
                    ),
                  ),
                ),
              ),
              IconButton.outlined(
                tooltip: sortAsc ? 'Orden ascendente' : 'Orden descendente',
                iconSize: 18,
                style: IconButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: AppRadius.smallShape,
                  foregroundColor: primary,
                ).copyWith(
                  side: WidgetStateProperty.resolveWith((states) {
                    final colors = Theme.of(context).colorScheme;
                    if (states.contains(WidgetState.disabled)) {
                      return BorderSide(color: colors.onSurface.withValues(alpha: 0.12));
                    }
                    if (states.contains(WidgetState.focused)) {
                      return BorderSide(color: colors.primary);
                    }
                    return BorderSide(color: colors.outline);
                  }),
                ),
                icon: Icon(sortAsc ? Icons.arrow_upward : Icons.arrow_downward),
                onPressed: () => context.read<HomeCubit>().updateFlag(asc: !sortAsc),
              ),
            ],
          );

          if (useTwoRows) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.small,
              children: [
                topRow,
                const _SliderControls(),
              ],
            );
          }

          return topRow;
        },
      ),
    );
  }
}

class _GamesList extends StatelessWidget {
  const _GamesList();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeCubit, HomeState>(
      buildWhen: (prev, curr) =>
          !identical(prev.filteredGames, curr.filteredGames) ||
          prev.binaryFormat != curr.binaryFormat ||
          prev.esDePath != curr.esDePath,
      builder: (context, state) {
        final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(AppSpacing.medium, 0, AppSpacing.medium, AppSpacing.small),
          itemCount: state.filteredGames.length,
          separatorBuilder: (context, index) => const SizedBox(height: AppSpacing.small),
          itemBuilder: (context, index) {
            final game = state.filteredGames[index];

            final Game(:name, :idSteam, :isSoftware, :language, :isFree, :spType, :friendPlay, :matchmaking, :hasAchievements, :hasSteamCloud, :isGeforceNow, :vr, :hasVrMods, :hasTranslations, :motion, :sizeInBytes, :status) = game;
            final coverPath = _getEsDeMediaPath(state.esDePath, 'covers', name);

            bool offers(InteractionType wanted) => [matchmaking, friendPlay].any((i) => i == wanted || i == InteractionType.both);

            final emojiTags = [
              if (spType case SpType.native) '👤' else if (spType case SpType.simulated) '👥',
              if (_activeInteractions.contains(friendPlay)) '🛋',
              if (_activeInteractions.contains(matchmaking)) '🌍',
              if (offers(InteractionType.coop)) '🤝',
              if (offers(InteractionType.pvp)) '⚔',
              if (hasAchievements == true) '🏆',
              if (hasSteamCloud == true) '☁',
              if (isGeforceNow == true) '🖥',
              if (vr != VrSupport.no || hasVrMods) '🥽',
              if (motion?.works ?? false) '🕹',
            ];
            final textTags = [
              status.label,
              if (isSoftware == true) 'Aplicación',
              language.label,
              if (hasTranslations) 'Parche',
              if (isFree == true) 'Gratis',
            ];

            // Emojis primero y luego los textos, todo separado por viñetas atenuadas.
            final separator = TextSpan(text: '  •  ', style: TextStyle(color: mutedColor, letterSpacing: 0));
            final spans = [
              if (emojiTags.isNotEmpty) TextSpan(text: emojiTags.join(' '), style: const TextStyle(letterSpacing: 2.0)),
              for (final tag in textTags) TextSpan(text: tag),
            ];

            return ListTile(
              shape: AppRadius.smallShape,
              tileColor: status.color(Theme.of(context).brightness == Brightness.dark),
              onLongPress: () => _openGameDialog(context, game),
              contentPadding: AppInsets.horizontalMedium,
              leading: PopupMenuButton<GameStatus>(
                tooltip: 'Cambiar estatus',
                initialValue: status,
                onSelected: (newStatus) => context.read<HomeCubit>().patchGame(game, {'status': newStatus.name}),
                itemBuilder: (ctx) => [
                  for (final s in GameStatus.values) PopupMenuItem(value: s, child: Text(s.label)),
                ],
                child: SizedBox(
                  width: 60, height: 60,
                  child: coverPath != null
                    ? ClipRRect(
                        borderRadius: AppRadius.small,
                        child: Image.file(File(coverPath), fit: BoxFit.contain),
                      )
                    : CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(Icons.videogame_asset, color: Theme.of(context).iconTheme.color),
                      ),
                ),
              ),
              title: Text(
                name ?? 'ID: $idSteam',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              subtitle: Text.rich(
                TextSpan(children: [
                  for (final (i, span) in spans.indexed) ...[if (i > 0) separator, span],
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: Text(
                SizeUnit.format(sizeInBytes, binary: state.binaryFormat),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            );
          },
        );
      },
    );
  }
}

class _DialogSection extends StatelessWidget {
  final Widget child;
  const _DialogSection({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.horizontalMedium,
      child: child,
    );
  }
}

class _DialogDivider extends StatelessWidget {
  const _DialogDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: AppInsets.verticalSmall,
      child: Divider(height: 0),
    );
  }
}

/// Opción del diálogo con icono y texto en negrita: enlaces, lanzadores y acciones.
class _DialogAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? note;
  final VoidCallback onPressed;
  const _DialogAction({required this.icon, required this.label, this.note, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      padding: AppInsets.allMedium,
      onPressed: onPressed,
      child: Row(
        spacing: AppSpacing.medium,
        children: [
          Icon(icon, size: AppIconSize.medium),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
                if (note case final text?)
                  Text(text, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GameDialog extends StatelessWidget {
  final String gameId;
  final Game initialGame;

  const _GameDialog({required this.gameId, required this.initialGame});

  @override
  Widget build(BuildContext context) {
    final dialogWidth = MediaQuery.sizeOf(context).shortestSide - 48.0;
    final esDePath = context.read<HomeCubit>().state.esDePath;
    final titlePath = _getEsDeMediaPath(esDePath, 'marquees', initialGame.name);
    final Game(:name, :idSteam) = initialGame;

    return SimpleDialog(
      clipBehavior: Clip.antiAlias,
      titlePadding: EdgeInsets.zero,
      contentPadding: AppInsets.verticalMedium,
      constraints: BoxConstraints(minWidth: dialogWidth, maxWidth: dialogWidth),
      children: [
        // 1. Título
        Padding(
          padding: AppInsets.horizontalMedium,
          child: titlePath != null
              ? Image.file(File(titlePath), height: 96, fit: BoxFit.contain)
              : Text(
                  name ?? 'ID: $idSteam',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
        ),
        const _DialogDivider(),

        // 2. Estatus
        _GameDialogStatus(gameId: gameId),
        const _DialogDivider(),

        // 3. Chips de información
        _DialogSection(child: _GameDialogChips(gameId: gameId, fallback: initialGame)),
        const _DialogDivider(),

        // 4. Propiedades
        _DialogSection(child: _GameDialogProperties(gameId: gameId, fallback: initialGame)),
        const _DialogDivider(),

        // 5. HLTB
        _GameDialogHltb(gameId: gameId, fallback: initialGame),
        const _DialogDivider(),

        // 6. Notas rápidas
        _DialogSection(child: _UserNoteField(gameId: gameId, initialNote: initialGame.userNote)),

        // 7. Enlaces y lanzadores
        if (idSteam != null) ...[
          const _DialogDivider(),
          _GameLaunchOptions(appId: idSteam),
          _DialogAction(
            icon: Icons.link,
            label: 'Ver en Steam',
            onPressed: () => _openUrl('https://store.steampowered.com/app/$idSteam/'),
          ),
        ],
        _GameDialogLinks(gameId: gameId, fallback: initialGame),

        // 8. Botones de re-fetch
        const _DialogDivider(),
        _DialogSection(child: _GameDialogButtons(gameId: gameId)),
      ],
    );
  }
}

// ── Lanzadores externos ──
class _GameLaunchOptions extends StatefulWidget {
  final int appId;
  const _GameLaunchOptions({required this.appId});

  @override
  State<_GameLaunchOptions> createState() => _GameLaunchOptionsState();
}

class _GameLaunchOptionsState extends State<_GameLaunchOptions> {
  late final Future<Map<GameLauncher, String>> _installed = detectInstalledLaunchers();

  Future<void> _launch(GameLauncher launcher, String package) async {
    try {
      await launcher.launch(package, widget.appId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo abrir ${launcher.label}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _installed,
      builder: (context, snapshot) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final MapEntry(key: launcher, value: package) in (snapshot.data ?? const {}).entries)
            _DialogAction(
              icon: Icons.play_arrow,
              label: 'Jugar en ${launcher.label}',
              onPressed: () => _launch(launcher, package),
            ),
        ],
      ),
    );
  }
}

// ── Enlaces de PCGamingWiki ──
/// Traducciones, mods de VR, arreglos de audio y parches, cada grupo con su cabecera.
/// Todo llega de la wiki o del JSON importado; aquí solo se abre el enlace.
class _GameDialogLinks extends StatelessWidget {
  final String gameId;
  final Game fallback;
  const _GameDialogLinks({required this.gameId, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final (pcgwPage, translations, vrMods, audioFixes, patches) = context.select((HomeCubit c) {
      final g = c.gameById(gameId) ?? fallback;
      return (g.pcgwPage, g.translations, g.vrMods, g.audioFixes, g.patches);
    });
    final groups = [
      (Icons.translate, 'Traducciones al español', translations),
      (Icons.view_in_ar, 'VR con mod o aplicación', vrMods),
      (Icons.surround_sound, 'Sonido posicional (DSOAL / OpenAL)', audioFixes),
      (Icons.build, 'Parches y mejoras', patches),
    ];
    if (pcgwPage == null && groups.every((g) => g.$3.isEmpty)) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pcgwPage case final page?)
          _DialogAction(icon: Icons.menu_book, label: 'Ver en PCGamingWiki', onPressed: () => _openUrl(PcgwService.pageUrl(page))),
        for (final (icon, title, links) in groups)
          if (links.isNotEmpty) ...[
            const _DialogDivider(),
            Padding(
              padding: AppInsets.horizontalMedium,
              child: Row(spacing: AppSpacing.medium, children: [
                Icon(icon, size: AppIconSize.medium),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
            for (final link in links)
              _DialogAction(icon: Icons.open_in_new, label: link.name, note: link.note, onPressed: () => _openUrl(link.url)),
          ],
      ],
    );
  }
}

// ── Estatus ──
class _GameDialogStatus extends StatelessWidget {
  final String gameId;
  const _GameDialogStatus({required this.gameId});

  @override
  Widget build(BuildContext context) {
    final status = context.select<HomeCubit, GameStatus>(
      (c) => c.gameById(gameId)?.status ?? GameStatus.planned,
    );
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in GameStatus.values)
          SimpleDialogOption(
            padding: AppInsets.allMedium,
            onPressed: () {
              final cubit = context.read<HomeCubit>();
              if (cubit.gameById(gameId) case final g?) cubit.patchGame(g, {'status': option.name});
            },
            child: Row(
              spacing: AppSpacing.medium,
              children: [
                const SizedBox(width: AppSpacing.medium),
                Text(
                  option.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: option == status ? FontWeight.bold : FontWeight.normal,
                    color: option == status ? primary : null,
                  ),
                ),
                if (option == status) ...[
                  const Spacer(),
                  Icon(Icons.check, size: AppIconSize.medium, color: primary),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

// ── Chips de información ──
class _GameDialogChips extends StatelessWidget {
  final String gameId;
  final Game fallback;
  const _GameDialogChips({required this.gameId, required this.fallback});

  @override
  Widget build(BuildContext context) {
    // Un record con solo lo que se pinta: guardar la nota del juego no reconstruye esto.
    final (language, hasTranslations, isSoftware, isFree, hasAchievements, hasSteamCloud, isGeforceNow, motion, isOwnedOnSteam) =
        context.select((HomeCubit c) {
      final g = c.gameById(gameId) ?? fallback;
      return (g.language, g.hasTranslations, g.isSoftware, g.isFree, g.hasAchievements, g.hasSteamCloud, g.isGeforceNow, g.motion, g.isOwnedOnSteam);
    });
    return Wrap(
      spacing: AppSpacing.small,
      runSpacing: AppSpacing.small,
      children: [
        _InfoChip(icon: Icons.language, label: language.label),
        if (hasTranslations) const _InfoChip(icon: Icons.translate, label: 'Parche'),
        if (isSoftware == true) const _InfoChip(icon: Icons.apps, label: 'Aplicación'),
        if (isFree == true) const _InfoChip(icon: Icons.money_off, label: 'Gratuito'),
        if (hasAchievements == true) const _InfoChip(icon: Icons.emoji_events, label: 'Logros'),
        if (hasSteamCloud == true) const _InfoChip(icon: Icons.cloud, label: 'Steam Cloud'),
        if (isGeforceNow == true) const _InfoChip(icon: Icons.cast, label: 'GeForce NOW'),
        if (motion case final support? when support.works) _InfoChip(icon: Icons.screen_rotation, label: 'Movimiento ${support.label}'),
        // Solo se avisa de la ausencia: que un juego esté en la cuenta es lo normal.
        if (isOwnedOnSteam == false) const _InfoChip(icon: Icons.no_accounts, label: 'Fuera de la cuenta'),
      ],
    );
  }
}

// ── Propiedades editables ──
class _GameDialogProperties extends StatelessWidget {
  final String gameId;
  final Game fallback;
  const _GameDialogProperties({required this.gameId, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final (spType, matchmaking, friendPlay, vr, hasVrMods) = context.select((HomeCubit c) {
      final g = c.gameById(gameId) ?? fallback;
      return (g.spType, g.matchmaking, g.friendPlay, g.vr, g.hasVrMods);
    });

    void update(String key, Enum? value) {
      if (value == null) return;
      final cubit = context.read<HomeCubit>();
      cubit.patchGame(cubit.gameById(gameId) ?? fallback, {key: value.name});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.medium,
      children: [
        _GameSizeRow(gameId: gameId, fallback: fallback),

        if (spType == SpType.none)
          const _ReadOnlyRow(icon: Icons.person, label: "Solitario:", value: "Sin modo solitario")
        else
          _DropdownRow<SpType>(
            icon: Icons.person,
            label: "Solitario:",
            value: spType,
            items: [
              if (spType == null) const DropdownMenuItem(value: SpType.none, child: Text('No aplica')),
              const DropdownMenuItem(value: SpType.native, child: Text('Nativo')),
              const DropdownMenuItem(value: SpType.simulated, child: Text('Con Bots / Alternado')),
            ],
            onChanged: (val) => update('sp_type', val),
          ),

        if (matchmaking == InteractionType.none)
          const _ReadOnlyRow(icon: Icons.public, label: "Matchmaking:", value: "Sin matchmaking")
        else
          _DropdownRow<InteractionType>(
            icon: Icons.public,
            label: "Matchmaking:",
            value: matchmaking,
            items: [for (final t in _activeInteractions) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (val) => update('matchmaking', val),
          ),

        if (friendPlay == InteractionType.none)
          const _ReadOnlyRow(icon: Icons.chair, label: "Salas/Local:", value: "Sin multijugador local")
        else
          _DropdownRow<InteractionType>(
            icon: Icons.chair,
            label: "Salas/Local:",
            value: friendPlay,
            items: [for (final t in _activeInteractions) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (val) => update('friend_play', val),
          ),

        // Lo de serie lo dice Steam y los mods se listan abajo: no hay nada que editar.
        _ReadOnlyRow(icon: Icons.view_in_ar, label: "VR:", value: hasVrMods ? '${vr.label} + mods' : vr.label),
      ],
    );
  }
}

// ── Peso editable ──
/// Steam no publica el tamaño de instalación: lo importado desde la cuenta entra a 0
/// bytes y se ajusta a mano con el mismo par cifra + unidad que el slider de la lista,
/// conservando la cifra escrita al cambiar de unidad.
class _GameSizeRow extends StatefulWidget {
  final String gameId;
  final Game fallback;
  const _GameSizeRow({required this.gameId, required this.fallback});

  @override
  State<_GameSizeRow> createState() => _GameSizeRowState();
}

class _GameSizeRowState extends State<_GameSizeRow> {
  late final HomeCubit _cubit = context.read<HomeCubit>();
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  late final Game _initial = _cubit.gameById(widget.gameId) ?? widget.fallback;
  late double _bytes = _initial.sizeInBytes;
  // La unidad es elección del usuario, no se deduce de la cifra: 0,5 GB o un campo
  // vacío no deben devolver el selector a MB.
  late bool _large = _initial.unit.isLarge;

  SizeUnit _unit(bool large) => SizeUnit.of(large: large, binary: _cubit.state.binaryFormat);

  @override
  void initState() {
    super.initState();
    _ctrl.text = _formatIn(_bytes, _unit(_large));
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit(_large);
    });
  }

  @override
  void dispose() {
    // Cerrar el diálogo con el campo enfocado no dispara el listener de foco.
    if (_focus.hasFocus) _save(_large);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Guarda lo escrito y devuelve el peso resultante. Sin cifra válida se conserva el
  /// peso guardado y solo cambia la unidad.
  double _save(bool large) {
    final unit = _unit(large);
    final value = double.tryParse(_ctrl.text.replaceAll(',', '.')) ?? _bytes / unit.bytes;

    final game = _cubit.gameById(widget.gameId) ?? widget.fallback;
    // Se compara en bytes con la tolerancia del redondeo a 2 decimales, no por nombre:
    // perder el foco sin editar no debe reescribir el archivo.
    final edited = (value * unit.bytes - game.sizeInBytes).abs() > unit.bytes * 0.005;
    if (edited || large != game.unit.isLarge) {
      _cubit.patchGame(game, {'size': value, 'unit': unit.name});
    }
    return edited ? value * unit.bytes : game.sizeInBytes;
  }

  void _commit(bool large) {
    final bytes = _save(large);
    setState(() {
      _bytes = bytes;
      _large = large;
    });
    _ctrl.text = _formatIn(bytes, _unit(large));
  }

  @override
  Widget build(BuildContext context) {
    final isBinary = context.select((HomeCubit c) => c.state.binaryFormat);
    final valueStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold);

    return BlocListener<HomeCubit, HomeState>(
      listenWhen: (p, c) => p.binaryFormat != c.binaryFormat,
      listener: (_, s) => _ctrl.text = _formatIn(_bytes, SizeUnit.of(large: _large, binary: s.binaryFormat)),
      child: Row(
        spacing: AppSpacing.small,
        children: [
          const Icon(Icons.sd_storage, size: AppIconSize.medium),
          const Text('Peso:'),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: valueStyle,
              decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: '0'),
              // En táctil, tocar fuera no quita el foco por defecto y el peso no se guardaría.
              onTapOutside: (_) => _focus.unfocus(),
              onSubmitted: (_) => _focus.unfocus(),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<bool>(
              value: _large,
              isDense: true,
              iconSize: 18,
              borderRadius: AppRadius.small,
              style: valueStyle,
              items: [
                for (final large in const [false, true])
                  DropdownMenuItem(value: large, child: Text(SizeUnit.of(large: large, binary: isBinary).label)),
              ],
              onChanged: (large) {
                if (large != null) _commit(large);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── HLTB ──
class _GameDialogHltb extends StatelessWidget {
  final String gameId;
  final Game fallback;
  const _GameDialogHltb({required this.gameId, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final hltbStats = context.select<HomeCubit, HltbStats?>(
      (c) => (c.gameById(gameId) ?? fallback).hltbStats,
    );
    if (hltbStats == null) return const SizedBox.shrink();

    final HltbStats(:mainStory, :extras, :completionist, :allPlayStyles) = hltbStats;
    final headerColor = Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
    final borderSide = BorderSide(color: Theme.of(context).colorScheme.outline, width: 0.8);

    Widget td(String text, {bool isHeader = false, bool isLabel = false, bool trailing = false}) {
      final child = Padding(
        padding: EdgeInsets.fromLTRB(
          isLabel ? AppSpacing.tiny : 0,
          isHeader ? 0 : AppSpacing.small,
          trailing ? AppSpacing.tiny : 0,
          isHeader ? 0 : AppSpacing.small,
        ),
        child: Text(
          text,
          textAlign: isLabel ? TextAlign.left : TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: isHeader || isLabel ? FontWeight.bold : null,
          ),
        ),
      );
      return isLabel ? ColoredBox(color: headerColor, child: child) : child;
    }

    // El tiempo "clásico" se omite: las cuatro cifras restantes ya cubren el rango útil.
    TableRow row(String label, HltbTime time) => TableRow(children: [
      td(label, isLabel: true),
      td(_formatDuration(time.average)),
      td(_formatDuration(time.median)),
      td(_formatDuration(time.rushed)),
      td(_formatDuration(time.leisure), trailing: true),
    ]);

    return _DialogSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.medium,
        children: [
          const Row(spacing: AppSpacing.medium, children: [
            Icon(Icons.timer, size: AppIconSize.medium),
            Text('Tiempos Estimados (HowLongToBeat)', style: TextStyle(fontWeight: FontWeight.w600)),
          ]),
          Table(
            border: TableBorder(
              top: borderSide, right: borderSide, bottom: borderSide, left: borderSide,
              horizontalInside: borderSide, borderRadius: AppRadius.small,
            ),
            columnWidths: const {
              0: FlexColumnWidth(1.4),
              1: FlexColumnWidth(1.1),
              2: FlexColumnWidth(1.1),
              3: FlexColumnWidth(1.1),
              4: FlexColumnWidth(1.1),
            },
            children: [
              TableRow(
                decoration: BoxDecoration(color: headerColor),
                children: [
                  const SizedBox.shrink(),
                  td('Promedio', isHeader: true),
                  td('Mediana', isHeader: true),
                  td('Rápido', isHeader: true),
                  td('Relajado', isHeader: true, trailing: true),
                ],
              ),
              if (!mainStory.isEmpty) row('Historia', mainStory),
              if (!extras.isEmpty) row('+ Extras', extras),
              if (!completionist.isEmpty) row('Platinado', completionist),
              if (!allPlayStyles.isEmpty) row('Todos los estilos', allPlayStyles),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Botones de re-fetch ──
class _GameDialogButtons extends StatelessWidget {
  final String gameId;
  const _GameDialogButtons({required this.gameId});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<HomeCubit>();
    final hasAppId = context.select<HomeCubit, bool>((c) => c.gameById(gameId)?.idSteam != null);
    final sources = [
      if (hasAppId) ('Steam', cubit.refetchSteamForGame),
      if (hasAppId) ('GFN', cubit.refetchGfnForGame),
      ('HLTB', cubit.refetchHltbForGame),
      if (PcgwService.enabled) ('PCGW', cubit.refetchPcgwForGame),
    ];

    return Wrap(
      spacing: AppSpacing.small,
      runSpacing: AppSpacing.small,
      children: [
        for (final (label, refetch) in sources)
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: AppIconSize.small),
            label: Text(label),
            style: OutlinedButton.styleFrom(
              shape: AppRadius.smallShape, visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontWeight: FontWeight.bold),
              padding: AppInsets.control,
            ),
            onPressed: () {
              if (cubit.gameById(gameId) case final g?) {
                refetch(g);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Re-consultando $label en segundo plano...')));
              }
            },
          ),
      ],
    );
  }
}

// =======================
// WIDGETS AUXILIARES
// =======================

class _ReadOnlyRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ReadOnlyRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: AppSpacing.small,
      children: [
        Icon(icon, size: AppIconSize.medium),
        Text(label),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: AppSpacing.small,
      children: [
        Icon(icon, size: AppIconSize.medium),
        Text(label),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              isExpanded: true,
              isDense: true,
              iconSize: 18,
              borderRadius: AppRadius.small,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              value: value,
              hint: const Text('Sin datos'),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppInsets.control,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.small,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.small,
        children: [
          Icon(icon, size: AppIconSize.small),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _UserNoteField extends StatefulWidget {
  final String gameId;
  final String? initialNote;
  const _UserNoteField({required this.gameId, this.initialNote});

  @override
  State<_UserNoteField> createState() => _UserNoteFieldState();
}

class _UserNoteFieldState extends State<_UserNoteField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialNote);
  late final FocusNode _focusNode = FocusNode()..addListener(_onFocusChange);
  Timer? _debounce;
  bool _pendingSave = false;

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _pendingSave) {
      _debounce?.cancel();
      _save();
    }
  }

  @override
  void dispose() {
    if (_pendingSave) {
      _debounce?.cancel();
      _save();
    }
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    _pendingSave = false;
    final cubit = context.read<HomeCubit>();
    if (cubit.gameById(widget.gameId) case final g?) cubit.patchGame(g, {'user_note': _ctrl.text});
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: (_) => _focusNode.unfocus(),
      child: TextField(
        controller: _ctrl,
        focusNode: _focusNode,
        maxLines: null,
        maxLength: 126,
        decoration: InputDecoration(
          labelText: 'Nota rápida',
          prefixIcon: const Icon(Icons.edit_note, size: AppIconSize.large),
          border: OutlineInputBorder(borderRadius: AppRadius.small),
        ),
        onChanged: (val) {
          _pendingSave = true;
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 1500), _save);
        },
      ),
    );
  }
}

// ==========================================
// PIEZAS REUTILIZABLES DE LA HOJA DE FILTROS
// ==========================================

/// Chip de selección única, sin marca de verificación y compacto.
ChoiceChip _choiceChip(String label, {required bool selected, required VoidCallback onSelected}) => ChoiceChip(
  label: Text(label),
  selected: selected,
  showCheckmark: false,
  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  onSelected: (v) { if (v) onSelected(); },
);

Wrap _triFilterWrap({
  required TriFilter value,
  required String yesLabel,
  required String noLabel,
  required ValueChanged<TriFilter> onSelected,
}) => Wrap(
  spacing: AppSpacing.small, runSpacing: AppSpacing.small,
  children: [
    for (final (label, option) in [('Todos', TriFilter.all), (yesLabel, TriFilter.yes), (noLabel, TriFilter.no)])
      _choiceChip(label, selected: value == option, onSelected: () => onSelected(option)),
  ],
);

/// Grupo de 3 chips (Todos / Sí / No) que observa un único TriFilter del estado.
class _TriFilterChips extends StatelessWidget {
  final String yesLabel;
  final String noLabel;
  final TriFilter Function(HomeState) selector;
  final ValueChanged<TriFilter> onSelected;
  const _TriFilterChips({
    required this.yesLabel,
    required this.noLabel,
    required this.selector,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final value = context.select<HomeCubit, TriFilter>((c) => selector(c.state));
    return _triFilterWrap(value: value, yesLabel: yesLabel, noLabel: noLabel, onSelected: onSelected);
  }
}

/// Grupo de interacción (Salas/Local, Matchmaking): filtro tri-estado + fila de
/// experiencia condicional. Un único select combinado hace que se reconstruya solo
/// cuando cambia su propio filtro o su experiencia.
class _InteractionFilterGroup extends StatelessWidget {
  final String title;
  final String yesLabel;
  final String noLabel;
  final TriFilter Function(HomeState) selectFilter;
  final ExperienceFilter Function(HomeState) selectExperience;
  final ValueChanged<TriFilter> onFilterChanged;
  final ValueChanged<ExperienceFilter> onExperienceChanged;

  const _InteractionFilterGroup({
    required this.title,
    required this.yesLabel,
    required this.noLabel,
    required this.selectFilter,
    required this.selectExperience,
    required this.onFilterChanged,
    required this.onExperienceChanged,
  });

  @override
  Widget build(BuildContext context) {
    final (filter, experience) = context.select<HomeCubit, (TriFilter, ExperienceFilter)>(
      (c) => (selectFilter(c.state), selectExperience(c.state)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.small,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        _triFilterWrap(value: filter, yesLabel: yesLabel, noLabel: noLabel, onSelected: onFilterChanged),
        if (filter != TriFilter.no)
          Wrap(
            spacing: AppSpacing.small, runSpacing: AppSpacing.small,
            children: [
              for (final exp in ExperienceFilter.values)
                _choiceChip(exp.label, selected: experience == exp, onSelected: () => onExperienceChanged(exp)),
            ],
          ),
      ],
    );
  }
}

/// Chips de distribución del slider, observando solo sliderDistribution.
class _SliderDistributionChips extends StatelessWidget {
  const _SliderDistributionChips();

  @override
  Widget build(BuildContext context) {
    final current = context.select((HomeCubit c) => c.state.sliderDistribution);
    return Wrap(
      spacing: AppSpacing.small, runSpacing: AppSpacing.small,
      children: [
        for (final dist in SliderDistribution.values)
          _choiceChip(
            dist.label,
            selected: current == dist,
            onSelected: () => context.read<HomeCubit>().updateFlag(sliderDistribution: dist),
          ),
      ],
    );
  }
}

/// Campo de búsqueda. El ValueListenableBuilder sobre el controller aísla el
/// rebuild: teclear solo actualiza este campo (y su botón de limpiar), no toda la hoja.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  const _SearchField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Buscar título...',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(borderRadius: AppRadius.small),
            suffixIcon: value.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      controller.clear();
                      context.read<HomeCubit>().updateFlag(searchQuery: '');
                    },
                  )
                : null,
          ),
          onChanged: (val) => context.read<HomeCubit>().updateFlag(searchQuery: val),
        );
      },
    );
  }
}

/// Gestor de perfiles de filtro. Mantiene el nombre en edición como estado local,
/// de modo que teclearlo solo reconstruye este bloque, no la hoja entera.
class _ProfileManager extends StatefulWidget {
  final TextEditingController searchController;
  const _ProfileManager({required this.searchController});

  @override
  State<_ProfileManager> createState() => _ProfileManagerState();
}

class _ProfileManagerState extends State<_ProfileManager> {
  String _profileName = '';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.small,
      children: [
        Text('Perfil de filtros', style: Theme.of(context).textTheme.titleMedium),
        BlocBuilder<HomeCubit, HomeState>(
          buildWhen: (p, c) => p.filterProfiles != c.filterProfiles,
          builder: (ctx, state) {
            final profiles = state.filterProfiles;
            final profileExists = profiles.containsKey(_profileName.trim());
            return Row(
              spacing: AppSpacing.small,
              children: [
                Expanded(
                  child: Autocomplete<String>(
                    optionsBuilder: (TextEditingValue value) {
                      if (value.text.isEmpty) return profiles.keys;
                      return profiles.keys.where(
                        (k) => k.toLowerCase().contains(value.text.toLowerCase()),
                      );
                    },
                    onSelected: (String selection) {
                      setState(() => _profileName = selection);
                    },
                    fieldViewBuilder: (ctx2, ctrl, focus, onSubmit) {
                      return TextField(
                        controller: ctrl,
                        focusNode: focus,
                        onChanged: (v) => setState(() => _profileName = v),
                        decoration: InputDecoration(
                          labelText: 'Nombre del perfil',
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: AppRadius.small),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.save),
                  tooltip: 'Guardar perfil',
                  onPressed: _profileName.trim().isNotEmpty
                      ? () => context.read<HomeCubit>().saveFilterProfile(_profileName)
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Cargar perfil',
                  onPressed: profileExists
                      ? () {
                          context.read<HomeCubit>().loadFilterProfile(_profileName.trim());
                          widget.searchController.text = context.read<HomeCubit>().state.searchQuery;
                        }
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Eliminar perfil',
                  onPressed: profileExists
                      ? () {
                          context.read<HomeCubit>().deleteFilterProfile(_profileName.trim());
                          setState(() => _profileName = '');
                        }
                      : null,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ==========================================
// BOTTOM SHEET DE FILTROS
// ==========================================

class _HltbRefreshControls extends StatelessWidget {
  const _HltbRefreshControls();

  @override
  Widget build(BuildContext context) {
    final countsDays = context.select((HomeCubit c) => c.state.refreshIntervalDays > 0);
    return Wrap(
      spacing: AppSpacing.medium,
      runSpacing: AppSpacing.small,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _DaysStepper(
          label: 'Cada',
          // Sin "al abrir": re-consultaría la biblioteca entera, varias páginas por juego.
          min: SyncInterval.manual,
          max: SyncInterval.maxDays,
          specialLabels: const {SyncInterval.manual: 'Manual'},
          selector: (s) => s.refreshIntervalDays,
          onCommit: (cubit, days) => cubit.updateFlag(refreshIntervalDays: days),
        ),
        if (countsDays)
          _BooleanFilterChip(
            label: 'Por fecha de calendario',
            selector: (c) => c.state.hltbRefreshByCalendar,
            onToggled: (val) => context.read<HomeCubit>().updateFlag(hltbRefreshByCalendar: val),
          ),
        _BooleanFilterChip(
          label: 'Consultar al abrir detalle',
          selector: (c) => c.state.hltbAutoRefreshOnDetail,
          onToggled: (val) => context.read<HomeCubit>().updateFlag(hltbAutoRefreshOnDetail: val),
        ),
      ],
    );
  }
}

/// Contar por fecha solo cambia algo con un intervalo de días; al abrir y manual no lo usan.
class _SteamLibraryCheckControls extends StatelessWidget {
  const _SteamLibraryCheckControls();

  @override
  Widget build(BuildContext context) {
    final countsDays = context.select((HomeCubit c) => c.state.steamCheckDays > 0);
    return Wrap(
      spacing: AppSpacing.medium,
      runSpacing: AppSpacing.small,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _DaysStepper(
          label: 'Frecuencia',
          min: SyncInterval.onOpen,
          max: SyncInterval.maxDays,
          specialLabels: const {SyncInterval.onOpen: 'Al abrir', SyncInterval.manual: 'Manual'},
          selector: (s) => s.steamCheckDays,
          onCommit: (cubit, days) => cubit.updateFlag(steamCheckDays: days),
        ),
        if (countsDays)
          _BooleanFilterChip(
            label: 'Por fecha de calendario',
            selector: (c) => c.state.steamCheckByCalendar,
            onToggled: (val) => context.read<HomeCubit>().updateFlag(steamCheckByCalendar: val),
          ),
      ],
    );
  }
}

/// Selector de un intervalo en días en una sola línea: un valor numérico editable al
/// centro con flechas −/+ que recorren [min, max] en ciclo. Escribir permite saltar a
/// cualquier entero sin ir de uno en uno. Los valores de [specialLabels] se muestran
/// por su nombre en lugar de como "N días".
class _DaysStepper extends StatefulWidget {
  final String label;
  final int min;
  final int max;
  final Map<int, String> specialLabels;
  final int Function(HomeState) selector;
  // Recibe el cubit porque también se confirma desde dispose, sin context utilizable.
  final void Function(HomeCubit cubit, int days) onCommit;

  const _DaysStepper({
    required this.label,
    required this.min,
    this.max = 365,
    this.specialLabels = const {},
    required this.selector,
    required this.onCommit,
  });

  @override
  State<_DaysStepper> createState() => _DaysStepperState();
}

class _HoldRepeatButton extends StatefulWidget {
  final Widget icon;
  final ValueChanged<int> onStep; // magnitud del paso: 1, 2, 5 o 10
  final String tooltip;
  const _HoldRepeatButton({
    required this.icon,
    required this.onStep,
    required this.tooltip,
  });

  @override
  State<_HoldRepeatButton> createState() => _HoldRepeatButtonState();
}

class _HoldRepeatButtonState extends State<_HoldRepeatButton> {
  Timer? _delay;
  Timer? _repeat;
  int _ticks = 0;

  // ~0.5 s de 1 en 1, luego de 2 en 2, de 5 en 5 y finalmente de 10 en 10.
  static int _stepForTicks(int t) => switch (t) {
    < 6 => 1,
    < 12 => 2,
    < 20 => 5,
    _ => 10,
  };

  void _start() {
    _stop();
    _ticks = 0;
    widget.onStep(1); // primer paso inmediato (también cubre el toque simple)
    _delay = Timer(const Duration(milliseconds: 350), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 90), (_) {
        _ticks++;
        widget.onStep(_stepForTicks(_ticks));
      });
    });
  }

  void _stop() {
    _delay?.cancel();
    _delay = null;
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _start(),
      onTapUp: (_) => _stop(),
      onTapCancel: _stop,
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(child: widget.icon),
        ),
      ),
    );
  }
}

class _MaxValueFormatter extends TextInputFormatter {
  final int max;
  const _MaxValueFormatter(this.max);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue; // permitir borrar del todo
    final value = int.tryParse(newValue.text);
    if (value == null || value > max) return oldValue; // rechazar
    return newValue;
  }
}

class _DaysStepperState extends State<_DaysStepper> {
  late final HomeCubit _cubit = context.read<HomeCubit>(); // guardado para poder volcar en dispose sin usar context
  late int _days = widget.selector(_cubit.state).clamp(_min, _max);
  late final TextEditingController _ctrl = TextEditingController(text: _fieldText(_days));
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);
  Timer? _commitDebounce;

  int get _min => widget.min;
  int get _max => widget.max;

  // Un valor con nombre deja el campo vacío para que lo muestre el hint.
  String _fieldText(int value) => widget.specialLabels.containsKey(value) ? '' : '$value';

  @override
  void dispose() {
    _commitDebounce?.cancel();
    _commitNow(); // vuelca cualquier cambio pendiente antes de irse
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // Ciclo modular sobre [_min, _max] para cualquier delta (positivo o negativo).
  int _cycle(int v, int delta) {
    final range = _max - _min + 1;
    final shifted = (v - _min + delta) % range;
    return _min + (shifted + range) % range;
  }

  void _setDays(int value, {bool syncField = true}) {
    if (!mounted) return;
    setState(() => _days = value);
    if (syncField) {
      final text = _fieldText(value);
      if (_ctrl.text != text) _ctrl.text = text;
    }
    _commitDebounce?.cancel();
    _commitDebounce = Timer(const Duration(milliseconds: 400), _commitNow);
  }

  void _bump(int delta) => _setDays(_cycle(_days, delta));

  void _onFocusChange() {
    if (!_focus.hasFocus) {
      // Al perder foco (incluye tocar fuera vía TapRegion) reconciliamos el
      // texto (vacío/parcial → último válido) y confirmamos de inmediato.
      final parsed = int.tryParse(_ctrl.text.trim());
      _setDays((parsed ?? _days).clamp(_min, _max));
      _commitNow();
    }
  }

  void _commitNow() {
    _commitDebounce?.cancel();
    if (widget.selector(_cubit.state) != _days) widget.onCommit(_cubit, _days);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final numberStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: cs.onSurfaceVariant,
    );

    final special = widget.specialLabels[_days];

    // Ancho fijo para 3 dígitos (o para el nombre del valor), medido con el estilo real.
    final painter = TextPainter(
      text: TextSpan(text: special ?? '000', style: numberStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final baseBorder = OutlineInputBorder(
      gapPadding: 0,
      borderRadius: AppRadius.small,
      borderSide: BorderSide(color: cs.outlineVariant),
    );

    return TapRegion(
      onTapOutside: (_) {
        if (_focus.hasFocus) _focus.unfocus();
      },
      child: IntrinsicWidth(
        child: InputDecorator(
          decoration: InputDecoration(
            label: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.tiny),
              child: Text(widget.label),
            ),
            filled: true,
            fillColor: cs.surface,
            floatingLabelStyle: TextStyle(color: cs.onSurfaceVariant),
            isDense: true,
            labelStyle: TextStyle(color: cs.primary),
            contentPadding: EdgeInsets.zero,
            border: baseBorder,
            enabledBorder: baseBorder,
            focusedBorder: baseBorder,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _HoldRepeatButton(
                tooltip: 'Menos días',
                icon: Icon(Icons.remove, size: AppIconSize.medium, color: cs.onSurfaceVariant),
                onStep: (magnitude) => _bump(-magnitude),
              ),
              SizedBox(
                width: painter.width + 10,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    _MaxValueFormatter(_max),
                  ],
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: special,
                    hintStyle: numberStyle,
                  ),
                  style: numberStyle,
                  onChanged: (text) {
                    // No reescribimos el campo mientras escribe (syncField: false).
                    if (int.tryParse(text) case final v?) _setDays(v.clamp(_min, _max), syncField: false);
                  },
                  onSubmitted: (_) => _focus.unfocus(),
                ),
              ),
              if (special == null)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.tiny),
                  child: Text(_days == 1 ? 'día' : 'días', style: numberStyle),
                ),
              _HoldRepeatButton(
                tooltip: 'Más días',
                icon: Icon(Icons.add, size: AppIconSize.medium, color: cs.onSurfaceVariant),
                onStep: (magnitude) => _bump(magnitude),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterBottomSheet extends StatefulWidget {
  const _FilterBottomSheet();

  @override
  State<_FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<_FilterBottomSheet> {
  late final TextEditingController _searchCtrl = TextEditingController(text: context.read<HomeCubit>().state.searchQuery);

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Widget _buildGroup(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.small,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        child,
      ],
    );
  }

  /// Un chip por valor del enum, cada uno observando solo su propia visibilidad.
  Widget _enumGroup<T extends Enum>(String title, List<T> values, Set<T> Function(HomeState) visible, {List<Widget> extra = const []}) => _buildGroup(
    title,
    Wrap(
      spacing: AppSpacing.small, runSpacing: AppSpacing.small,
      children: [for (final value in values) _EnumFilterChip(value: value, visible: visible), ...extra],
    ),
  );

  Widget _triGroup(String title, String yesLabel, String noLabel, TriFilter Function(HomeState) selector, ValueChanged<TriFilter> onSelected) =>
      _buildGroup(title, _TriFilterChips(yesLabel: yesLabel, noLabel: noLabel, selector: selector, onSelected: onSelected));

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<HomeCubit>();
    // No se suscribe a estado volátil ni hace setState al teclear: se ejecuta una vez al
    // abrir y cada grupo hijo gestiona su propio rebuild.
    return Padding(
      padding: AppInsets.allLarge + EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.large,
          children: [
            _ProfileManager(searchController: _searchCtrl),
            _buildGroup('Búsqueda', _SearchField(controller: _searchCtrl)),
            _enumGroup('Idiomas', GameLanguage.values, (s) => s.visibleLanguages, extra: [
              _BooleanFilterChip(label: 'Parche', selector: (c) => c.state.includeTranslations, onToggled: (val) => cubit.updateFlag(translations: val)),
            ]),
            _enumGroup('Solitario', SpType.values, (s) => s.visibleSpTypes),
            _enumGroup('VR', VrSupport.values, (s) => s.visibleVrTypes, extra: [
              _BooleanFilterChip(label: 'Mods VR', selector: (c) => c.state.includeVrMods, onToggled: (val) => cubit.updateFlag(vrMods: val)),
            ]),

            _InteractionFilterGroup(
              title: 'Salas / Local',
              yesLabel: 'Con Salas/Local',
              noLabel: 'Sin Salas/Local',
              selectFilter: (s) => s.friendPlayFilter,
              selectExperience: (s) => s.friendPlayExperience,
              onFilterChanged: (t) => cubit.updateFlag(friendPlayFilter: t),
              onExperienceChanged: (e) => cubit.updateFlag(friendPlayExperience: e),
            ),

            _InteractionFilterGroup(
              title: 'Matchmaking',
              yesLabel: 'Con Matchmaking',
              noLabel: 'Sin Matchmaking',
              selectFilter: (s) => s.matchmakingFilter,
              selectExperience: (s) => s.matchmakingExperience,
              onFilterChanged: (t) => cubit.updateFlag(matchmakingFilter: t),
              onExperienceChanged: (e) => cubit.updateFlag(matchmakingExperience: e),
            ),

            _triGroup('Logros de Steam', 'Con Logros', 'Sin Logros', (s) => s.achievementsFilter, (t) => cubit.updateFlag(achievementsFilter: t)),
            _triGroup('Steam Cloud', 'Soporta Cloud', 'Sin Cloud', (s) => s.steamCloudFilter, (t) => cubit.updateFlag(steamCloudFilter: t)),
            _triGroup('Precio', 'Gratuitos', 'De Pago', (s) => s.priceFilter, (t) => cubit.updateFlag(priceFilter: t)),
            _triGroup('GeForce NOW', 'En GFN', 'No en GFN', (s) => s.geforceNowFilter, (t) => cubit.updateFlag(geforceNowFilter: t)),
            _triGroup('Movimiento', 'Giroscopio o mandos VR', 'Sin movimiento', (s) => s.motionFilter, (t) => cubit.updateFlag(motionFilter: t)),

            // Sin cuenta vinculada, o con una que no aportó ningún juego, el filtro
            // dejaría ambos lados vacíos.
            if (context.select<HomeCubit, bool>((c) => c.hasSteamOwnershipData))
              _triGroup('Cuenta de Steam', 'En la cuenta', 'No en la cuenta', (s) => s.steamOwnershipFilter, (t) => cubit.updateFlag(steamOwnershipFilter: t)),

            _buildGroup(
              'Otras características',
              Wrap(
                spacing: AppSpacing.small, runSpacing: AppSpacing.small,
                children: [
                  _BooleanFilterChip(
                    label: 'Incluir aplicaciones',
                    selector: (c) => c.state.includeSoftware,
                    onToggled: (val) => cubit.updateFlag(software: val),
                  ),
                  _BooleanFilterChip(
                    label: 'Formato binario (MiB/GiB)',
                    selector: (c) => c.state.binaryFormat,
                    onToggled: (val) => cubit.updateFlag(binary: val),
                  ),
                ],
              ),
            ),

            if (context.select<HomeCubit, bool>((c) => c.state.hasSteamAccount))
              _buildGroup('Sincronizar biblioteca de Steam', const _SteamLibraryCheckControls()),

            _buildGroup('Sincronizar con HowLongToBeat', const _HltbRefreshControls()),
            _buildGroup('Distribución del Slider', const _SliderDistributionChips()),

            BlocBuilder<HomeCubit, HomeState>(
              buildWhen: (p, c) => p.groupByStatus != c.groupByStatus || !identical(p.statusFilters, c.statusFilters),
              builder: (ctx, state) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.small,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('Estatus', style: Theme.of(ctx).textTheme.titleMedium),
                      const Spacer(),
                      FilterChip(
                        label: const Text('Agrupar'),
                        selected: state.groupByStatus,
                        showCheckmark: false,
                        visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        avatar: Icon(
                          state.groupByStatus ? Icons.layers : Icons.layers_outlined,
                          size: AppIconSize.medium,
                        ),
                        onSelected: (v) => cubit.updateFlag(groupByStatus: v),
                      ),
                    ],
                  ),
                  _StatusChipGrid(config: state.statusFilters),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.medium),
          ],
        ),
      ),
    );
  }
}

/// Chip de visibilidad de un valor de idioma, solitario o VR.
class _EnumFilterChip<T extends Enum> extends StatelessWidget {
  final T value;
  final Set<T> Function(HomeState) visible;
  const _EnumFilterChip({required this.value, required this.visible});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select((HomeCubit c) => visible(c.state).contains(value));
    return FilterChip(
      showCheckmark: false,
      label: Text(_enumLabel(value)),
      selected: isSelected,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => context.read<HomeCubit>().toggleVisible(value, val),
    );
  }
}

class _BooleanFilterChip extends StatelessWidget {
  final String label;
  final bool Function(HomeCubit) selector;
  final ValueChanged<bool> onToggled;

  const _BooleanFilterChip({required this.label, required this.selector, required this.onToggled});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select(selector);
    return FilterChip(
      showCheckmark: false,
      label: Text(label),
      selected: isSelected,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: onToggled,
    );
  }
}

class _StatusChipGrid extends StatefulWidget {
  const _StatusChipGrid({required this.config});
  final List<StatusEntry> config;

  @override
  State<_StatusChipGrid> createState() => _StatusChipGridState();
}

class _StatusChipGridState extends State<_StatusChipGrid> {
  late List<StatusEntry> _preview = List.of(widget.config);
  GameStatus? _dragging;

  @override
  void didUpdateWidget(_StatusChipGrid old) {
    super.didUpdateWidget(old);
    if (_dragging == null && !listEquals(widget.config, old.config)) {
      _preview = List.of(widget.config);
    }
  }

  void _moveTo(GameStatus from, GameStatus to) {
    final fi = _preview.indexWhere((e) => e.status == from);
    final ti = _preview.indexWhere((e) => e.status == to);
    if (fi < 0 || ti < 0 || fi == ti) return;
    setState(() => _preview.insert(ti, _preview.removeAt(fi)));
  }

  void _commit() {
    if (_dragging == null) return;
    context.read<HomeCubit>().updateFlag(statusFilters: List.of(_preview));
    setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.small,
      runSpacing: AppSpacing.small,
      children: [
        for (final entry in _preview)
          _DraggableStatusChip(
            key: ValueKey(entry.status),
            status: entry.status,
            currentlyDragging: _dragging,
            onDragStarted: () => setState(() => _dragging = entry.status),
            onHover: (from) => _moveTo(from, entry.status),
            onDrop: _commit,
          ),
      ],
    );
  }
}

// ── Chip arrastrable individual ─────────────────────────────────────────────

class _DraggableStatusChip extends StatelessWidget {
  const _DraggableStatusChip({
    required super.key,
    required this.status,
    required this.currentlyDragging,
    required this.onDragStarted,
    required this.onHover,
    required this.onDrop,
  });

  final GameStatus status;
  final GameStatus? currentlyDragging;
  final VoidCallback onDragStarted;
  final ValueChanged<GameStatus> onHover;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final chip = _StatusFilterChip(status: status);
    final feedback = Material(
      type: MaterialType.transparency,
      elevation: 4,
      shadowColor: Theme.of(context).colorScheme.shadow,
      child: _StatusFilterChip(status: status),
    );

    return DragTarget<GameStatus>(
      onWillAcceptWithDetails: (d) {
        if (d.data != currentlyDragging || d.data == status) return false;
        onHover(d.data);
        return true;
      },
      onAcceptWithDetails: (_) {},
      builder: (ctx, candidates, _) {
        final isTarget = candidates.isNotEmpty && currentlyDragging != status;
        return AnimatedScale(
          scale: isTarget ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          child: LongPressDraggable<GameStatus>(
            data: status,
            delay: const Duration(milliseconds: 250),
            feedback: feedback,
            childWhenDragging: Opacity(opacity: 0.35, child: chip),
            onDragStarted: onDragStarted,
            onDragEnd: (_) => onDrop(),
            child: chip,
          ),
        );
      },
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  final GameStatus status;
  const _StatusFilterChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = context.select<HomeCubit, bool>(
      (c) => c.state.visibleStatuses.contains(status),
    );
    final color = status.color(Theme.of(context).brightness == Brightness.dark);

    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status.label),
          const SizedBox(width: AppSpacing.tiny),
          Icon(
            Icons.drag_indicator,
            size: AppIconSize.medium,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
        ],
      ),
      selected: isSelected,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => context.read<HomeCubit>().toggleStatusFilter(status, val),
      backgroundColor: color.withValues(alpha: 0.25),
      selectedColor: color.withValues(alpha: 0.55),
    );
  }
}

// ==========================================
// CONTROLES DE SLIDERS AISLADOS Y OPTIMIZADOS
// ==========================================

/// Redondea un peso a la unidad entera que le toca (MB por debajo de 1 GB, GB a partir).
double _snapToUnit(double bytes, {required bool binary}) {
  final unit = SizeUnit.forBytes(bytes, binary: binary).bytes;
  return (bytes / unit).roundToDouble() * unit;
}

/// Paradas del slider discreto: una por MB hasta 1 GB y una por GB en adelante, entre
/// los límites absolutos. Se recalculan solo cuando cambian los límites o el formato.
class _DiscreteStepCache {
  (double, double, bool)? _key;
  List<double> _steps = const [];

  List<double> getSteps(HomeState state) {
    final key = (state.absoluteMinBytes, state.absoluteMaxBytes, state.binaryFormat);
    if (key == _key) return _steps;
    _key = key;

    final (min, max, binary) = key;
    final mb = SizeUnit.of(large: false, binary: binary).bytes;
    final gb = SizeUnit.of(large: true, binary: binary).bytes;
    double step(double bytes) => bytes < gb ? mb : gb;

    final steps = [min];
    var current = _snapToUnit(min, binary: binary);
    if (current <= min) current += step(current);
    for (var safety = 0; current < max && safety < 50000; safety++) {
      steps.add(current);
      current += step(current);
    }
    if (steps.last < max) steps.add(max);
    return _steps = steps;
  }
}

class _SliderControls extends StatefulWidget {
  const _SliderControls();
  @override
  State<_SliderControls> createState() => _SliderControlsState();
}

class _SliderControlsState extends State<_SliderControls> {
  final TextEditingController minCtrl = TextEditingController();
  final TextEditingController maxCtrl = TextEditingController();
  final FocusNode minFocus = FocusNode();
  final FocusNode maxFocus = FocusNode();

  final _DiscreteStepCache _stepCache = _DiscreteStepCache();

  Timer? _debounceTimer;
  bool _isDragging = false;
  late double _localMinBytes;
  late double _localMaxBytes;
  // Unidad de cada extremo, deducida del valor: GB en cuanto llega a 1 GB.
  bool _minLarge = false;
  bool _maxLarge = false;

  bool get _isInteracting => _isDragging || minFocus.hasFocus || maxFocus.hasFocus;

  @override
  void initState() {
    super.initState();
    minFocus.addListener(() => _onFieldBlur(minFocus, minCtrl, true));
    maxFocus.addListener(() => _onFieldBlur(maxFocus, maxCtrl, false));
    final initial = context.read<HomeCubit>().state;
    _localMinBytes = initial.currentMinBytes;
    _localMaxBytes = initial.currentMaxBytes;
    _updateTextFields(initial.currentMinBytes, initial.currentMaxBytes, initial.binaryFormat);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    minCtrl.dispose();
    maxCtrl.dispose();
    minFocus.dispose();
    maxFocus.dispose();
    super.dispose();
  }

  void _onFieldBlur(FocusNode focus, TextEditingController ctrl, bool isMin) {
    if (mounted && !focus.hasFocus) _submitManualEntry(ctrl, isMin, isMin ? _minLarge : _maxLarge);
  }

  void _updateTextFields(double minB, double maxB, bool isBinary) {
    final minUnit = SizeUnit.forBytes(minB, binary: isBinary);
    final maxUnit = SizeUnit.forBytes(maxB, binary: isBinary);
    _minLarge = minUnit.isLarge;
    _maxLarge = maxUnit.isLarge;
    final minStr = _formatIn(minB, minUnit);
    final maxStr = _formatIn(maxB, maxUnit);
    if (minCtrl.text != minStr) minCtrl.text = minStr;
    if (maxCtrl.text != maxStr) maxCtrl.text = maxStr;
  }

  /// El slider solo recorre unidades enteras, así que la entrada manual también. Un campo
  /// vacío recupera la cifra que mostraba y la aplica en la unidad elegida.
  void _submitManualEntry(TextEditingController ctrl, bool isMin, bool large) {
    _debounceTimer?.cancel();

    final cubit = context.read<HomeCubit>();
    final binary = cubit.state.binaryFormat;
    final currentBytes = isMin ? _localMinBytes : _localMaxBytes;
    final shownUnit = SizeUnit.of(large: isMin ? _minLarge : _maxLarge, binary: binary);
    final value = (int.tryParse(ctrl.text) ?? (currentBytes / shownUnit.bytes).round()) * SizeUnit.of(large: large, binary: binary).bytes;
    cubit.updateRange(isMin ? value : _localMinBytes, isMin ? _localMaxBytes : value);

    // Se toma lo que quedó en el estado: si el valor salió de los límites y se recortó a
    // lo que ya había, no hay emit que corrija el campo.
    setState(() {
      _localMinBytes = cubit.state.currentMinBytes;
      _localMaxBytes = cubit.state.currentMaxBytes;
      _updateTextFields(_localMinBytes, _localMaxBytes, binary);
    });
  }

  void _onSliderChanged(double calcMin, double calcMax, bool isBinary) {
    setState(() {
      _localMinBytes = calcMin;
      _localMaxBytes = calcMax;
    });
    _updateTextFields(calcMin, calcMax, isBinary);

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) context.read<HomeCubit>().updateRange(_localMinBytes, _localMaxBytes);
    });
  }

  void _onSliderChangeEnd() {
    setState(() => _isDragging = false);
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
      context.read<HomeCubit>().updateRange(_localMinBytes, _localMaxBytes);
    }
  }

  /// Posición [0, 1] del slider para un peso. En modo discreto es la parada más
  /// cercana (búsqueda binaria); en los continuos, la fracción del rango con la curva.
  double _bytesToSlider(double bytes, HomeState state, List<double> steps) {
    if (state.sliderDistribution == SliderDistribution.discrete) {
      if (steps.length <= 1 || bytes <= steps.first) return 0.0;
      if (bytes >= steps.last) return 1.0;

      var low = 0;
      var high = steps.length - 1;
      while (low <= high) {
        final mid = (low + high) >> 1;
        if (steps[mid] == bytes) return mid / (steps.length - 1);
        if (steps[mid] < bytes) {
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      final nearest = (bytes - steps[high]).abs() < (steps[low] - bytes).abs() ? high : low;
      return nearest / (steps.length - 1);
    }

    final HomeState(absoluteMinBytes: minB, absoluteMaxBytes: maxB) = state;
    if (bytes <= minB) return 0.0;
    if (bytes >= maxB) return 1.0;
    final fraction = (bytes - minB) / (maxB - minB);
    return switch (state.sliderDistribution) {
      SliderDistribution.quadratic => sqrt(fraction),
      SliderDistribution.cubic => pow(fraction, 1 / 3).toDouble(),
      SliderDistribution.discrete => fraction,
    };
  }

  double _sliderToBytes(double sliderVal, HomeState state, List<double> steps) {
    if (state.sliderDistribution == SliderDistribution.discrete) {
      if (steps.isEmpty) return state.absoluteMinBytes;
      return steps[(sliderVal * (steps.length - 1)).round().clamp(0, steps.length - 1)];
    }

    final HomeState(absoluteMinBytes: minB, absoluteMaxBytes: maxB) = state;
    if (sliderVal <= 0.0) return minB;
    if (sliderVal >= 1.0) return maxB;
    final fraction = switch (state.sliderDistribution) {
      SliderDistribution.quadratic => pow(sliderVal, 2).toDouble(),
      SliderDistribution.cubic => pow(sliderVal, 3).toDouble(),
      SliderDistribution.discrete => sliderVal,
    };
    return minB + fraction * (maxB - minB);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<HomeCubit, HomeState>(
      listenWhen: (prev, curr) =>
          prev.currentMinBytes != curr.currentMinBytes ||
          prev.currentMaxBytes != curr.currentMaxBytes ||
          prev.binaryFormat != curr.binaryFormat ||
          prev.absoluteMaxBytes != curr.absoluteMaxBytes,
      listener: (context, state) {
        if (!_isInteracting) {
          setState(() {
            _localMinBytes = state.currentMinBytes;
            _localMaxBytes = state.currentMaxBytes;
          });
          _updateTextFields(_localMinBytes, _localMaxBytes, state.binaryFormat);
        }
      },
      child: BlocBuilder<HomeCubit, HomeState>(
        buildWhen: (prev, curr) =>
            prev.absoluteMinBytes != curr.absoluteMinBytes ||
            prev.absoluteMaxBytes != curr.absoluteMaxBytes ||
            prev.binaryFormat != curr.binaryFormat ||
            prev.sliderDistribution != curr.sliderDistribution,
        builder: (context, state) {
          final steps = _stepCache.getSteps(state);
          final tMin = _bytesToSlider(_localMinBytes, state, steps).clamp(0.0, 1.0);
          final tMax = _bytesToSlider(_localMaxBytes, state, steps).clamp(0.0, 1.0);

          return Column(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.small,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildEditableLimit(minCtrl, minFocus, true, state.binaryFormat),
                  _buildEditableLimit(maxCtrl, maxFocus, false, state.binaryFormat),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3.0,
                  rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 10),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: RangeSlider(
                  padding: EdgeInsets.zero,
                  values: RangeValues(tMin, tMax),
                  min: 0.0, max: 1.0,
                  onChangeStart: (_) => setState(() => _isDragging = true),
                  onChanged: (values) => _onSliderChanged(
                    _snapToUnit(_sliderToBytes(values.start, state, steps), binary: state.binaryFormat),
                    _snapToUnit(_sliderToBytes(values.end, state, steps), binary: state.binaryFormat),
                    state.binaryFormat,
                  ),
                  onChangeEnd: (_) => _onSliderChangeEnd(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEditableLimit(TextEditingController ctrl, FocusNode focus, bool isMin, bool isBinary) {
    final primary = Theme.of(context).colorScheme.primary;
    return TapRegion(
      // Guardar queda en manos del listener de foco, sea cual sea la forma de perderlo.
      onTapOutside: (_) {
        if (focus.hasFocus) focus.unfocus();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        spacing: AppSpacing.small,
        children: [
          IntrinsicWidth(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: primary),
              onSubmitted: (_) => focus.unfocus(),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<bool>(
              value: isMin ? _minLarge : _maxLarge,
              isDense: true, iconSize: 20,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: primary),
              items: [
                for (final large in const [false, true])
                  DropdownMenuItem(value: large, child: Text(SizeUnit.of(large: large, binary: isBinary).label)),
              ],
              onChanged: (large) {
                if (large != null) _submitManualEntry(ctrl, isMin, large);
              },
            ),
          ),
        ],
      ),
    );
  }
}
