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

import 'hltb_service.dart';
import 'model.dart';
import 'state.dart';
import 'steam_service.dart';

final Random _random = Random();
const List<String> _imgExts = ['.png', '.jpg', '.jpeg', '.webp'];
const List<InteractionType> _activeInteractions = [
  InteractionType.coop,
  InteractionType.pvp,
  InteractionType.both,
];
const _roundedShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6)));

// ==========================================
// FUNCIONES PARA UI DE STATUS, IDIOMAS Y CURVA
// ==========================================
String _statusName(GameStatus s) => switch (s) {
  GameStatus.planned => 'Planeado',
  GameStatus.playing => 'Jugando',
  GameStatus.beaten => 'Terminado',
  GameStatus.completed => 'Platinado',
  GameStatus.paused => 'Suspendido',
  GameStatus.dropped => 'Abandonado',
  GameStatus.discarded => 'Descartado',
};

Color _statusColor(GameStatus s, bool isDark) => switch ((s, isDark)) {
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

String _langName(GameLanguage l) => switch (l) { GameLanguage.english => 'Inglés', GameLanguage.spanish => 'Español', GameLanguage.patched => 'Parcheado' };
String _distName(SliderDistribution d) => switch (d) { SliderDistribution.discrete => 'Discreta', SliderDistribution.quadratic => 'Cuadrática', SliderDistribution.cubic => 'Cúbica' };
String _spTypeName(SpType s) => switch (s) { SpType.native => 'Nativo', SpType.simulated => 'Con Bots / Alternado', SpType.none => 'Sin Solitario' };
String _interactionName(InteractionType i) => switch (i) { InteractionType.none => 'Ninguno', InteractionType.coop => 'Cooperativo', InteractionType.pvp => 'Competitivo', InteractionType.both => 'Ambos (Coop + JcJ)' };
String _expName(ExperienceFilter e) => switch (e) { ExperienceFilter.any => 'Cualquiera', ExperienceFilter.coop => 'Solo Cooperativo', ExperienceFilter.pvp => 'Solo Competitivo', ExperienceFilter.both => 'Ambos' };
String _vrName(VrSupport v) => switch (v) { VrSupport.no => 'Sin VR', VrSupport.yes => 'VR opcional', VrSupport.only => 'Solo VR', VrSupport.mod => 'Mod VR' };

String _formatDuration(int? minutes) {
  if (minutes == null || minutes <= 0) return '--';
  final hh = minutes ~/ 60;
  final mm = minutes % 60;
  return switch ((hh, mm)) {
    (0, _) => '${mm}m',
    (_, 0) => '${hh}h',
    _ => '${hh}h ${mm}m',
  };
}

/// Unidad con la que se muestra un tamaño: MB/GB, o MiB/GiB si el ajuste es binario.
({double divisor, String name}) _unitData(double bytes, bool isBinary) =>
    switch ((isBinary, bytes >= (isBinary ? 1073741824.0 : 1000000000.0))) {
      (true, true) => (divisor: 1073741824.0, name: "GiB"),
      (true, false) => (divisor: 1048576.0, name: "MiB"),
      (false, true) => (divisor: 1000000000.0, name: "GB"),
      (false, false) => (divisor: 1000000.0, name: "MB"),
    };

/// Cifra del tamaño en su unidad, sin decimales cuando es exacta.
String _formatUnitValue(double bytes, bool isBinary) {
  final value = bytes / _unitData(bytes, isBinary).divisor;
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

/// Formatea un recuento de juegos con la unidad singular/plural correcta.
String _games(int n) => n == 1 ? '1 juego' : '$n juegos';

/// Resumen para el SnackBar de éxito tras aplicar un [ImportPlan].
String _importSummary(ImportPlan plan) {
  if (plan.replace) {
    return 'Biblioteca reemplazada: ${_games(plan.incoming)} importados.';
  }
  final parts = <String>[];
  if (plan.added > 0) parts.add('${_games(plan.added)} añadidos');
  if (plan.merged > 0) {
    parts.add(plan.preserveExisting
        ? '${_games(plan.merged)} actualizados'
        : '${_games(plan.merged)} sobrescritos');
  }
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
  final String message;
  if (plan.replace) {
    message = 'Se eliminarán tus ${_games(plan.deleted)} actuales y se reemplazarán por '
        '${_games(plan.incoming)} del archivo. Esta acción no se puede deshacer.';
  } else {
    // merge sin preservar, con coincidencias: se reinician las propiedades ausentes.
    final added = plan.added > 0 ? ' Se añadirán ${_games(plan.added)} nuevos.' : '';
    message = 'De los ${_games(plan.incoming)} del archivo, ${_games(plan.merged)} ya existen y '
        'se sobrescribirán por completo: las propiedades que no vengan en el JSON se reiniciarán '
        'a sus valores por defecto.$added Esta acción no se puede deshacer.';
  }
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

String _steamSyncMessage(SteamSync result) => switch (result) {
  SteamSyncFailed(:final reason) => _steamFailureMessage(reason),
  SteamSyncDone(added: 0, updated: 0) => 'Steam: no se encontró ningún juego.',
  SteamSyncDone(added: 0, :final updated) => 'Steam: sin novedades, los ${_games(updated)} ya estaban.',
  SteamSyncDone(:final added, :final updated) =>
    'Steam: ${_games(added)} añadidos${updated > 0 ? ' y $updated ya estaban' : ''}.',
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
            spacing: 12.0,
            children: [
              if (state.hasSteamAccount)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    spacing: 12,
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
              TextField(
                controller: _keyCtrl,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'API key',
                  helperText: 'Si es la clave de ese mismo perfil, incluye sus juegos privados.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscureKey ? Icons.visibility_off : Icons.visibility, size: 20),
                    tooltip: _obscureKey ? 'Mostrar' : 'Ocultar',
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.vpn_key, size: 16),
                  label: const Text('Obtener una API key'),
                  onPressed: () async {
                    final uri = Uri.parse('https://steamcommunity.com/dev/apikey');
                    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
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
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
    if (current.idSteam != null && current.needsHltbRefresh(cubit.state.refreshIntervalDays)) {
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
class HomeView extends StatelessWidget {
  const HomeView({super.key});

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
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'import') {
                _showJsonDialog(context);
              } else if (value == 'export') {
                _exportJson(context);
              } else if (value == 'clear') {
                _showClearConfirmDialog(context);
              } else if (value == 'update_gfn') {
                context.read<HomeCubit>().fetchGeforceNowDatabase();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sincronizando datos de GeForce NOW en segundo plano...')),
                );
              } else if (value == 'refetch_steam') {
                context.read<HomeCubit>().refetchSteamAll();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sincronizando datos de Steam en segundo plano...')),
                );
              } else if (value == 'refetch_hltb') {
                context.read<HomeCubit>().refetchHltbAll();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sincronizando datos de HLTB en segundo plano...')),
                );
              } else if (value == 'steam_link') {
                showDialog(context: context, builder: (_) => const _SteamAccountDialog());
              } else if (value == 'steam_sync') {
                final messenger = ScaffoldMessenger.of(context);
                final result = await context.read<HomeCubit>().syncSteamLibrary();
                messenger.showSnackBar(SnackBar(content: Text(_steamSyncMessage(result))));
              } else if (value == 'esde_path') {
                String? selectedDirectory = await FilePicker.getDirectoryPath();
                if (selectedDirectory != null && context.mounted) {
                  context.read<HomeCubit>().updateFlag(esDePath: selectedDirectory);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Carpeta de ES-DE vinculada con éxito.')),
                  );
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'import', child: Text('Importar biblioteca')),
              const PopupMenuItem(value: 'export', child: Text('Exportar biblioteca')),
              const PopupMenuItem(value: 'clear', child: Text('Vaciar biblioteca')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'update_gfn', child: Text('Sincronizar datos de GeForce NOW')),
              const PopupMenuItem(value: 'refetch_steam', child: Text('Sincronizar datos de Steam')),
              const PopupMenuItem(value: 'refetch_hltb', child: Text('Sincronizar datos de HLTB')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'steam_link', child: Text('Vincular cuenta de Steam')),
              PopupMenuItem(
                value: 'steam_sync',
                enabled: context.read<HomeCubit>().state.hasSteamAccount,
                child: const Text('Importar biblioteca de Steam'),
              ),
              const PopupMenuItem(value: 'esde_path', child: Text('Vincular carpeta de ES-DE')),
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
              child: Center(child: Text('No hay datos. Importa un JSON o vincula tu cuenta de Steam para comenzar.')),
            )
          else ...[
            const _SummaryText(),
            const Expanded(child: _GamesList()),
          ],
        ],
      ),
    );
  }

  Future<void> _exportJson(BuildContext context) async {
    try {
      final jsonString = context.read<HomeCubit>().exportGamesJson();
      final bytes = Uint8List.fromList(utf8.encode(jsonString));
      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Exportar/Guardar JSON',
        fileName: 'mis_juegos.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes
      );

      if (outputFile != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Archivo guardado con éxito.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar el archivo: $e')));
      }
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
                  spacing: 12.0,
                  children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        backgroundColor: scheme.primary.withValues(alpha: 0.05),
                        side: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
                      ),
                      onPressed: () async {
                        try {
                          FilePickerResult? result = await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['json', 'txt'],
                          );

                          if (result != null && result.files.single.path != null) {
                            final file = File(result.files.single.path!);
                            final content = await file.readAsString();
                            setState(() {
                              selectedFileName = result.files.single.path;
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
                        spacing: 12,
                        children: [
                          Icon(Icons.folder_open, color: scheme.primary, size: 24),
                          Expanded(
                            child: Text(
                              selectedFileName ?? 'Tocar para elegir archivo...',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: selectedFileName == null
                                  ? Theme.of(context).textTheme.bodyMedium?.color
                                  : scheme.primary,
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
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
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
                      subtitle: Text(replace
                          ? 'No aplica al reemplazar: se descarta todo lo anterior.'
                          : (preserveExisting
                              ? 'Solo se actualizan las propiedades presentes en el JSON; el resto se mantiene.'
                              : 'Las propiedades ausentes del JSON se reinician a sus valores por defecto.')),
                      value: !replace && preserveExisting,
                      onChanged: replace ? null : (v) => setState(() => preserveExisting = v),
                    ),
                    // Alerta encadenada: al activar «Reemplazar» avisamos de que se pierde lo ya definido.
                    if (replace)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          spacing: 12,
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
                builder: (c, value, _) {
                  final enabled = value.text.trim().isNotEmpty;
                  return ElevatedButton(
                    style: replace
                        ? ElevatedButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          )
                        : null,
                    onPressed: enabled
                        ? () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final cubit = context.read<HomeCubit>();
                            final analysis = cubit.analyzeImport(
                              jsonCtrl.text,
                              replace: replace,
                              preserveExisting: preserveExisting,
                            );
                            switch (analysis) {
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
                                if (plan.isDestructive) {
                                  final confirmed = await _confirmImport(ctx, plan);
                                  if (confirmed != true) return; // cancelar: regresa al diálogo intacto
                                }
                                await cubit.applyImport(plan);
                                if (ctx.mounted) Navigator.pop(ctx);
                                messenger.showSnackBar(
                                  SnackBar(content: Text(_importSummary(plan))),
                                );
                            }
                          }
                        : null,
                    child: Text(replace ? 'Reemplazar' : 'Importar'),
                  );
                },
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
        content: const Text('Se borrará el JSON guardado localmente en la app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              context.read<HomeCubit>().clearJson();
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        "RESULTADOS: $count | PESO: ${HomeCubit.formatBytes(bytes, isBinary)}",
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SyncIndicator extends StatelessWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context) {
    final isFetching = context.select((HomeCubit c) => c.state.isFetchingSteam);
    final isFetchingGfn = context.select((HomeCubit c) => c.state.isFetchingGfnDb);
    final isFetchingHltb = context.select((HomeCubit c) => c.state.isFetchingHltb);
    final isSyncingLibrary = context.select((HomeCubit c) => c.state.isSyncingSteamLibrary);
    final pendingCount = context.select((HomeCubit c) => c.state.steamQueueSize);
    final pendingHltbCount = context.select((HomeCubit c) => c.state.hltbQueueSize);

    return IconButton(
      tooltip: [
        'Sincronizando:',
        if (isFetchingGfn) '• GeForce NOW: descargando catálogo',
        if (isSyncingLibrary) '• Steam: leyendo la biblioteca de la cuenta',
        if (isFetching) '• Steam: $pendingCount pendientes',
        if (isFetchingHltb) '• HLTB: $pendingHltbCount pendientes',
      ].join('\n'),
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
    final isSyncing = context.select((HomeCubit c) =>
        c.state.isFetchingSteam ||
        c.state.isFetchingGfnDb ||
        c.state.isFetchingHltb ||
        c.state.isSyncingSteamLibrary);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Mínimo del _SliderControls: 440.61619186401332 + 36
          final useTwoRows = hasGames && constraints.maxWidth < 476.62;
          final topRow = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 6,
            children: [
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.filter_alt, size: 18),
                  label: const Text('Filtros'),
                  style: OutlinedButton.styleFrom(shape: _roundedShape),
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
                      padding: EdgeInsetsDirectional.symmetric(horizontal: 4),
                      child: Text('Orden'),
                    ),
                    isDense: true,
                    labelStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
                    floatingLabelStyle: TextStyle(color: Theme.of(context).colorScheme.primary),
                    contentPadding: EdgeInsets.zero,
                    border: const OutlineInputBorder(gapPadding: 0, borderRadius: BorderRadius.all(Radius.circular(6))),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: sortBy,
                      isDense: true,
                      isExpanded: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      borderRadius: BorderRadius.circular(6),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      icon: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.sort, size: 18, color: Theme.of(context).colorScheme.primary),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'name', child: Text('Nombre')),
                        DropdownMenuItem(value: 'peso', child: Text('Peso')),
                        DropdownMenuItem(value: 'hltbMain', child: Text('T. Historia')),
                        DropdownMenuItem(value: 'hltbExtras', child: Text('T. Extras')),
                        DropdownMenuItem(value: 'hltbComplete', child: Text('T. Platinado')),
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
                  shape: _roundedShape,
                  foregroundColor: Theme.of(context).colorScheme.primary,
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
              spacing: 6.0,
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
      buildWhen: (prev, curr) {
        return !identical(prev.filteredGames, curr.filteredGames) ||
               prev.binaryFormat != curr.binaryFormat ||
               prev.esDePath != curr.esDePath;
      },
      builder: (context, state) {
        return ListView.separated(
          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 6),
          itemCount: state.filteredGames.length,
          separatorBuilder: (context, index) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final game = state.filteredGames[index];

            final Game(:name, :idSteam, :isSoftware, :language, :isFree, :spType, :friendPlay, :matchmaking, :hasAchievements, :hasSteamCloud, :isGeforceNow, :vrSupport, :sizeInBytes, :status) = game;
            final gameName = name ?? 'ID: $idSteam';
            final coverPath = _getEsDeMediaPath(state.esDePath, 'covers', name);

            final isCoop = switch ((matchmaking, friendPlay)) {
              (InteractionType.coop || InteractionType.both, _) => true,
              (_, InteractionType.coop || InteractionType.both) => true,
              _ => false,
            };

            final isPvp = switch ((matchmaking, friendPlay)) {
              (InteractionType.pvp || InteractionType.both, _) => true,
              (_, InteractionType.pvp || InteractionType.both) => true,
              _ => false,
            };

            final textTags = <String>[
              _statusName(status),
              if (isSoftware == true) 'Aplicación',
              _langName(language),
              if (isFree == true) 'Gratis',
            ];

            final emojiTags = <String>[
              if (spType case SpType.native) '👤' else if (spType case SpType.simulated) '👥',
              if (friendPlay case InteractionType.coop || InteractionType.pvp || InteractionType.both) '🛋',
              if (matchmaking case InteractionType.coop || InteractionType.pvp || InteractionType.both) '🌍',
              if (isCoop) '🤝',
              if (isPvp) '⚔',
              if (hasAchievements == true) '🏆',
              if (hasSteamCloud == true) '☁',
              if (isGeforceNow == true) '🖥',
              if (vrSupport case VrSupport.yes || VrSupport.only || VrSupport.mod) '🥽',
            ];

            // Construimos los Spans por colores
            final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
            final spans = <InlineSpan>[];

            // 1. Emojis primero
            if (emojiTags.isNotEmpty) {
              spans.add(TextSpan(
                text: emojiTags.join(' '),
                style: const TextStyle(letterSpacing: 2.0),
              ));

              if (textTags.isNotEmpty) {
                spans.add(TextSpan(
                  text: '  •  ',
                  style: TextStyle(color: mutedColor, letterSpacing: 0),
                ));
              }
            }

            // 2. Textos (Estatus + otros) intercalados con viñetas atenuadas
            for (int i = 0; i < textTags.length; i++) {
              spans.add(TextSpan(text: textTags[i]));

              if (i < textTags.length - 1) {
                spans.add(TextSpan(
                  text: '  •  ',
                  style: TextStyle(color: mutedColor),
                ));
              }
            }

            return ListTile(
              shape: _roundedShape,
              tileColor: _statusColor(status, Theme.of(context).brightness == Brightness.dark),
              onLongPress: () => _openGameDialog(context, game),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: PopupMenuButton<GameStatus>(
                tooltip: 'Cambiar estatus',
                initialValue: status,
                onSelected: (newStatus) => context.read<HomeCubit>().updateGameStatus(game, newStatus),
                itemBuilder: (ctx) => GameStatus.values.map((statusValue) => PopupMenuItem(
                  value: statusValue,
                  child: Text(_statusName(statusValue)),
                )).toList(),
                child: SizedBox(
                  width: 60, height: 60,
                  child: coverPath != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(File(coverPath), fit: BoxFit.contain),
                      )
                    : CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(Icons.videogame_asset, color: Theme.of(context).iconTheme.color),
                      ),
                ),
              ),
              title: Text(
                gameName,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              subtitle: Text.rich(
                TextSpan(children: spans),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: Text(
                HomeCubit.formatBytes(sizeInBytes, state.binaryFormat),
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
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: child,
    );
  }
}

class _DialogDivider extends StatelessWidget {
  const _DialogDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Divider(height: 0),
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
    final Game(:name, :idSteam, :patchUrl) = initialGame;

    return SimpleDialog(
      clipBehavior: Clip.antiAlias,
      titlePadding: EdgeInsets.zero,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      constraints: BoxConstraints(minWidth: dialogWidth, maxWidth: dialogWidth),
      children: [
        // 1. Título
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
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

        // 7. Enlaces
        if (idSteam != null || patchUrl != null) ...[
          const _DialogDivider(),
          if (idSteam != null)
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              onPressed: () async {
                final uri = Uri.parse('https://store.steampowered.com/app/$idSteam/');
                if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: Row(spacing: 12, children: [
                const Icon(Icons.link, size: 18),
                Text("Ver en Steam", style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
              ]),
            ),
          if (patchUrl != null)
            SimpleDialogOption(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              onPressed: () async {
                final uri = Uri.parse(patchUrl);
                if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: Row(spacing: 12, children: [
                const Icon(Icons.download, size: 18),
                Text("Descargar parche", style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
              ]),
            ),
        ],

        // 8. Botones de re-fetch
        if (idSteam != null) ...[
          const _DialogDivider(),
          _DialogSection(child: _GameDialogButtons(gameId: gameId)),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: GameStatus.values.map((statusValue) {
        final isCurrent = status == statusValue;
        return SimpleDialogOption(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
          onPressed: () {
            final g = context.read<HomeCubit>().gameById(gameId);
            if (g != null) context.read<HomeCubit>().updateGameStatus(g, statusValue);
          },
          child: Row(
            spacing: 12,
            children: [
              const SizedBox(width: 12),
              Text(
                _statusName(statusValue),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
              if (isCurrent) ...[
                const Spacer(),
                Icon(Icons.check, size: 18, color: Theme.of(context).colorScheme.primary),
              ],
            ],
          ),
        );
      }).toList(),
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
    final d = context.select<HomeCubit, ({GameLanguage language, bool? isSoftware, bool? isFree, bool? hasAchievements, bool? hasSteamCloud, bool? isGeforceNow})>(
      (c) {
        final g = c.gameById(gameId) ?? fallback;
        return (language: g.language, isSoftware: g.isSoftware, isFree: g.isFree,
                hasAchievements: g.hasAchievements, hasSteamCloud: g.hasSteamCloud, isGeforceNow: g.isGeforceNow);
      },
    );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _InfoChip(icon: Icons.language, label: _langName(d.language)),
        if (d.isSoftware == true) const _InfoChip(icon: Icons.apps, label: 'Aplicación'),
        if (d.isFree == true) const _InfoChip(icon: Icons.money_off, label: 'Gratuito'),
        if (d.hasAchievements == true) const _InfoChip(icon: Icons.emoji_events, label: 'Logros'),
        if (d.hasSteamCloud == true) const _InfoChip(icon: Icons.cloud, label: 'Steam Cloud'),
        if (d.isGeforceNow == true) const _InfoChip(icon: Icons.computer, label: 'GeForce NOW'),
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
    final p = context.select<HomeCubit, ({SpType? spType, InteractionType? matchmaking, InteractionType? friendPlay, VrSupport? vrSupport})>(
      (c) {
        final g = c.gameById(gameId) ?? fallback;
        return (spType: g.spType, matchmaking: g.matchmaking, friendPlay: g.friendPlay, vrSupport: g.vrSupport);
      },
    );

    void update(Game Function(Game) patch) {
      final g = context.read<HomeCubit>().gameById(gameId) ?? fallback;
      context.read<HomeCubit>().updateGameDetails(patch(g), originalGame: g);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12.0,
      children: [
        _GameSizeRow(gameId: gameId, fallback: fallback),

        if (p.spType == SpType.none)
          const _ReadOnlyRow(icon: Icons.person, label: "Solitario:", value: "Sin modo solitario")
        else
          _DropdownRow<SpType>(
            icon: Icons.person,
            label: "Solitario:",
            value: p.spType,
            items: [
              if (p.spType == null) const DropdownMenuItem(value: SpType.none, child: Text('No aplica')),
              const DropdownMenuItem(value: SpType.native, child: Text('Nativo')),
              const DropdownMenuItem(value: SpType.simulated, child: Text('Con Bots / Alternado')),
            ],
            onChanged: (val) { if (val != null) update((g) => g.copyWith(spType: val)); },
          ),

        if (p.matchmaking == InteractionType.none)
          const _ReadOnlyRow(icon: Icons.public, label: "Matchmaking:", value: "Sin matchmaking")
        else
          _DropdownRow<InteractionType>(
            icon: Icons.public,
            label: "Matchmaking:",
            value: p.matchmaking,
            items: _activeInteractions.map((t) => DropdownMenuItem(value: t, child: Text(_interactionName(t)))).toList(),
            onChanged: (val) { if (val != null) update((g) => g.copyWith(matchmaking: val)); },
          ),

        if (p.friendPlay == InteractionType.none)
          const _ReadOnlyRow(icon: Icons.chair, label: "Salas/Local:", value: "Sin multijugador local")
        else
          _DropdownRow<InteractionType>(
            icon: Icons.chair,
            label: "Salas/Local:",
            value: p.friendPlay,
            items: _activeInteractions.map((t) => DropdownMenuItem(value: t, child: Text(_interactionName(t)))).toList(),
            onChanged: (val) { if (val != null) update((g) => g.copyWith(friendPlay: val)); },
          ),

        if (p.vrSupport == VrSupport.yes)
          const _ReadOnlyRow(icon: Icons.view_in_ar, label: "VR:", value: "VR opcional")
        else if (p.vrSupport == VrSupport.only)
          const _ReadOnlyRow(icon: Icons.view_in_ar, label: "VR:", value: "Solo VR")
        else
          _DropdownRow<VrSupport>(
            icon: Icons.view_in_ar,
            label: "VR:",
            value: p.vrSupport,
            items: [
              if (p.vrSupport == null) ...const [
                DropdownMenuItem(value: VrSupport.no, child: Text('Sin soporte VR')),
                DropdownMenuItem(value: VrSupport.yes, child: Text('VR opcional')),
                DropdownMenuItem(value: VrSupport.only, child: Text('Solo VR')),
                DropdownMenuItem(value: VrSupport.mod, child: Text('Mod de VR')),
              ] else ...const [
                DropdownMenuItem(value: VrSupport.no, child: Text('Sin soporte VR')),
                DropdownMenuItem(value: VrSupport.mod, child: Text('Mod de VR')),
              ],
            ],
            onChanged: (val) { if (val != null) update((g) => g.copyWith(vrSupport: val)); },
          ),
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
  late double _bytes = (_cubit.gameById(widget.gameId) ?? widget.fallback).sizeInBytes;

  bool get _isBinary => _cubit.state.binaryFormat;

  @override
  void initState() {
    super.initState();
    _ctrl.text = _formatUnitValue(_bytes, _isBinary);
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit(_unitData(_bytes, _isBinary));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit(({double divisor, String name}) unit) {
    final isBinary = _isBinary;
    final value = double.tryParse(_ctrl.text.replaceAll(',', '.'));
    final newBytes = (value ?? _bytes / _unitData(_bytes, isBinary).divisor) * unit.divisor;

    if (value != null && newBytes != _bytes) {
      _cubit.updateGameSize(_cubit.gameById(widget.gameId) ?? widget.fallback, value, unit.name);
    }
    setState(() => _bytes = newBytes);
    _ctrl.text = _formatUnitValue(newBytes, isBinary);
  }

  @override
  Widget build(BuildContext context) {
    final isBinary = context.select((HomeCubit c) => c.state.binaryFormat);
    final unit = _unitData(_bytes, isBinary);
    final valueStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold);

    return Row(
      spacing: 6,
      children: [
        const Icon(Icons.sd_storage, size: 18),
        const Text('Peso:'),
        Expanded(
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            textAlign: TextAlign.end,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: valueStyle,
            decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: '0'),
            onSubmitted: (_) => _commit(unit),
          ),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<({double divisor, String name})>(
            value: unit,
            isDense: true,
            iconSize: 18,
            borderRadius: BorderRadius.circular(6),
            style: valueStyle,
            items: [
              for (final u in [_unitData(0, isBinary), _unitData(double.maxFinite, isBinary)])
                DropdownMenuItem(value: u, child: Text(u.name)),
            ],
            onChanged: (newUnit) {
              if (newUnit != null) _commit(newUnit);
            },
          ),
        ),
      ],
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
        padding: EdgeInsets.fromLTRB(isLabel ? 3 : 0, isHeader ? 0 : 6, trailing ? 3 : 0, isHeader ? 0 : 6),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DialogSection(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12.0,
            children: [
              const Row(spacing: 12, children: [
                Icon(Icons.timer, size: 18),
                Text('Tiempos Estimados (HowLongToBeat)', style: TextStyle(fontWeight: FontWeight.w600)),
              ]),
              Table(
                border: TableBorder(
                  top: borderSide, right: borderSide, bottom: borderSide, left: borderSide,
                  horizontalInside: borderSide, borderRadius: BorderRadius.circular(6),
                ),
                columnWidths: const {
                  0: FlexColumnWidth(1.4),
                  1: FlexColumnWidth(1.1),
                  2: FlexColumnWidth(1.1),
                  3: FlexColumnWidth(1.1),
                  4: FlexColumnWidth(1.1),
                  // 5: FlexColumnWidth(1.1),
                },
                children: [
                  TableRow(
                    decoration: BoxDecoration(color: headerColor),
                    children: [
                      const SizedBox.shrink(),
                      // td('Clásico', isHeader: true),
                      td('Promedio', isHeader: true),
                      td('Mediana', isHeader: true),
                      td('Rápido', isHeader: true),
                      td('Relajado', isHeader: true, trailing: true),
                    ],
                  ),
                  if (!mainStory.isEmpty) TableRow(children: [
                    td('Historia', isLabel: true),
                    // td(_formatDuration(mainStory.classic)),
                    td(_formatDuration(mainStory.average)),
                    td(_formatDuration(mainStory.median)),
                    td(_formatDuration(mainStory.rushed)),
                    td(_formatDuration(mainStory.leisure), trailing: true),
                  ]),
                  if (!extras.isEmpty) TableRow(children: [
                    td('+ Extras', isLabel: true),
                    // td(_formatDuration(extras.classic)),
                    td(_formatDuration(extras.average)),
                    td(_formatDuration(extras.median)),
                    td(_formatDuration(extras.rushed)),
                    td(_formatDuration(extras.leisure), trailing: true),
                  ]),
                  if (!completionist.isEmpty) TableRow(children: [
                    td('Platinado', isLabel: true),
                    // td(_formatDuration(completionist.classic)),
                    td(_formatDuration(completionist.average)),
                    td(_formatDuration(completionist.median)),
                    td(_formatDuration(completionist.rushed)),
                    td(_formatDuration(completionist.leisure), trailing: true),
                  ]),
                  if (!allPlayStyles.isEmpty) TableRow(children: [
                    td('Todos los estilos', isLabel: true),
                    // td(_formatDuration(allPlayStyles.classic)),
                    td(_formatDuration(allPlayStyles.average)),
                    td(_formatDuration(allPlayStyles.median)),
                    td(_formatDuration(allPlayStyles.rushed)),
                    td(_formatDuration(allPlayStyles.leisure), trailing: true),
                  ]),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Botones de re-fetch ──
class _GameDialogButtons extends StatelessWidget {
  final String gameId;
  const _GameDialogButtons({required this.gameId});

  @override
  Widget build(BuildContext context) {
    void refetch(void Function(Game) action, String msg) {
      final g = context.read<HomeCubit>().gameById(gameId);
      if (g == null) return;
      action(g);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh, size: 12),
          label: const Text('Steam'),
          style: OutlinedButton.styleFrom(
            shape: _roundedShape, visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          onPressed: () => refetch(
            (g) => context.read<HomeCubit>().refetchSteamForGame(g),
            'Re-consultando Steam en segundo plano...',
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh, size: 12),
          label: const Text('GFN'),
          style: OutlinedButton.styleFrom(
            shape: _roundedShape, visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          onPressed: () => refetch(
            (g) => context.read<HomeCubit>().refetchGfnForGame(g),
            'Re-consultando GeForce NOW en segundo plano...',
          ),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh, size: 12),
          label: const Text('HLTB'),
          style: OutlinedButton.styleFrom(
            shape: _roundedShape, visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          onPressed: () => refetch(
            (g) => context.read<HomeCubit>().refetchHltbForGame(g),
            'Re-consultando HLTB en segundo plano...',
          ),
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
      spacing: 6,
      children: [
        Icon(icon, size: 18),
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
      spacing: 6,
      children: [
        Icon(icon, size: 18),
        Text(label),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              isExpanded: true,
              isDense: true,
              iconSize: 18,
              borderRadius: BorderRadius.circular(6),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Icon(icon, size: 12),
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
  late TextEditingController _ctrl;
  late FocusNode _focusNode;
  Timer? _debounce;
  bool _pendingSave = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialNote);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

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
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final g = context.read<HomeCubit>().gameById(widget.gameId);
    if (g == null) { _pendingSave = false; return; }
    context.read<HomeCubit>().updateGameDetails(
      g.copyWith(userNote: _ctrl.text),
      originalGame: g,
    );
    _pendingSave = false;
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
          prefixIcon: const Icon(Icons.edit_note, size: 24),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onChanged: (val) {
          _pendingSave = true;
          if (_debounce?.isActive ?? false) _debounce!.cancel();
          _debounce = Timer(const Duration(milliseconds: 1500), _save);
        },
      ),
    );
  }
}

// ==========================================
// PIEZAS REUTILIZABLES DE LA HOJA DE FILTROS
// ==========================================

Wrap _triFilterWrap({
  required TriFilter value,
  required String yesLabel,
  required String noLabel,
  required ValueChanged<TriFilter> onSelected,
}) {
  Widget chip(String label, TriFilter option) => ChoiceChip(
        label: Text(label),
        selected: value == option,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (v) { if (v) onSelected(option); },
      );
  return Wrap(
    spacing: 6, runSpacing: 6,
    children: [
      chip('Todos', TriFilter.all),
      chip(yesLabel, TriFilter.yes),
      chip(noLabel, TriFilter.no),
    ],
  );
}

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
      spacing: 6,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        _triFilterWrap(value: filter, yesLabel: yesLabel, noLabel: noLabel, onSelected: onFilterChanged),
        if (filter != TriFilter.no)
          Wrap(
            spacing: 6, runSpacing: 6,
            children: [
              for (final exp in ExperienceFilter.values)
                ChoiceChip(
                  label: Text(_expName(exp)),
                  selected: experience == exp,
                  showCheckmark: false,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (v) { if (v) onExperienceChanged(exp); },
                ),
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
      spacing: 6, runSpacing: 6,
      children: [
        for (final dist in SliderDistribution.values)
          ChoiceChip(
            label: Text(_distName(dist)),
            selected: current == dist,
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (v) { if (v) context.read<HomeCubit>().updateFlag(sliderDistribution: dist); },
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
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
      spacing: 6,
      children: [
        Text('Perfil de filtros', style: Theme.of(context).textTheme.titleMedium),
        BlocBuilder<HomeCubit, HomeState>(
          buildWhen: (p, c) => p.filterProfiles != c.filterProfiles,
          builder: (ctx, state) {
            final profiles = state.filterProfiles;
            final profileExists = profiles.containsKey(_profileName.trim());
            return Row(
              spacing: 6,
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
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
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
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const _HltbIntervalStepper(),
        _BooleanFilterChip(
          label: 'Consultar al abrir detalle',
          selector: (c) => c.state.hltbAutoRefreshOnDetail,
          onToggled: (val) => context.read<HomeCubit>().updateFlag(hltbAutoRefreshOnDetail: val),
        ),
      ],
    );
  }
}

/// Selector del intervalo de refresco de HLTB (en días) en una sola línea:
/// un valor numérico editable al centro con flechas −/+ para ajustarlo, acotado
/// a [_min, _max]. Escribir permite saltar a cualquier entero sin ir de uno en
/// uno. Se suscribe solo a refreshIntervalDays (BlocConsumer con buildWhen)
class _HltbIntervalStepper extends StatefulWidget {
  const _HltbIntervalStepper();

  @override
  State<_HltbIntervalStepper> createState() => _HltbIntervalStepperState();
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

  static int _stepForTicks(int t) {
    if (t < 6) return 1; // ~0.5 s de 1 en 1
    if (t < 12) return 2; // luego de 2 en 2
    if (t < 20) return 5; // luego de 5 en 5
    return 10; // y finalmente de 10 en 10
  }

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

class _HltbIntervalStepperState extends State<_HltbIntervalStepper> {
  static const int _min = 0;   // 0 = desactivado
  static const int _max = 365; // máximo solicitado

  late final HomeCubit _cubit; // guardado para poder volcar en dispose sin usar context
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  Timer? _commitDebounce;
  late int _days;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<HomeCubit>();
    _days = _cubit.state.refreshIntervalDays.clamp(_min, _max);
    _ctrl = TextEditingController(text: '$_days');
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _commitDebounce?.cancel();
    _commitNow(); // vuelca cualquier cambio pendiente antes de irse
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // Ciclo modular sobre [_min, _max] para cualquier delta (positivo o negativo).
  int _cycle(int v, int delta) {
    const range = _max - _min + 1;
    final shifted = (v - _min + delta) % range;
    return _min + (shifted + range) % range;
  }

  void _setDays(int value, {bool syncField = true}) {
    if (!mounted) return;
    setState(() => _days = value);
    if (syncField) {
      final text = '$value';
      if (_ctrl.text != text) _ctrl.text = text;
    }
    _scheduleCommit();
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

  void _scheduleCommit() {
    _commitDebounce?.cancel();
    _commitDebounce = Timer(const Duration(milliseconds: 400), _commitNow);
  }

  void _commitNow() {
    _commitDebounce?.cancel();
    if (_cubit.state.refreshIntervalDays != _days) {
      _cubit.updateFlag(refreshIntervalDays: _days);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final numberStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: cs.onSurfaceVariant,
    );

    // Ancho fijo para 3 dígitos (el máximo es 366), medido con el estilo real.
    final painter = TextPainter(
      text: TextSpan(text: '000', style: numberStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final fieldWidth = painter.width + 10;

    final baseBorder = OutlineInputBorder(
      gapPadding: 0,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: cs.outlineVariant), 
    );

    return TapRegion(
      onTapOutside: (_) {
        if (_focus.hasFocus) _focus.unfocus();
      },
      child: IntrinsicWidth(
        child: InputDecorator(
          decoration: InputDecoration(
            label: const Padding(
              padding: EdgeInsetsDirectional.symmetric(horizontal: 4),
              child: Text('Refrescar cada'),
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
                icon: Icon(Icons.remove, size: 18, color: cs.onSurfaceVariant),
                onStep: (magnitude) => _bump(-magnitude),
              ),
              SizedBox(
                width: fieldWidth,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    _MaxValueFormatter(_max),
                  ],
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: numberStyle,
                  onChanged: (text) {
                    final v = int.tryParse(text);
                    // No reescribimos el campo mientras escribe (syncField: false).
                    if (v != null) _setDays(v.clamp(_min, _max), syncField: false);
                  },
                  onSubmitted: (_) => _focus.unfocus(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(_days == 1 ? 'día' : 'días', style: numberStyle),
              ),
              _HoldRepeatButton(
                tooltip: 'Más días',
                icon: Icon(Icons.add, size: 18, color: cs.onSurfaceVariant),
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
  late TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    final currentQuery = context.read<HomeCubit>().state.searchQuery;
    _searchCtrl = TextEditingController(text: currentQuery);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Widget _buildGroup(String title, Widget child, [Widget? extraChild]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        child,
        ?extraChild,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // No se suscribe a estado volátil ni hace setState al teclear: se ejecuta una vez al
    // abrir y cada grupo hijo gestiona su propio rebuild.
    return Padding(
      padding: EdgeInsets.only(
        left: 18.0, right: 18.0, top: 18.0,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18.0,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 18,
          children: [
            _ProfileManager(searchController: _searchCtrl),

            _buildGroup(
              'Búsqueda',
              _SearchField(controller: _searchCtrl),
            ),

            _buildGroup(
              'Idiomas',
              Wrap(
                spacing: 6, runSpacing: 6,
                children: GameLanguage.values.map((lang) => _LanguageFilterChip(language: lang)).toList(),
              ),
            ),

            _buildGroup(
              'Solitario',
              Wrap(
                spacing: 6, runSpacing: 6,
                children: SpType.values.map((sp) => _SpTypeFilterChip(spType: sp)).toList(),
              ),
            ),

            _buildGroup(
              'VR',
              Wrap(
                spacing: 6, runSpacing: 6,
                children: VrSupport.values.map((vr) => _VrFilterChip(vrSupport: vr)).toList(),
              ),
            ),

            _InteractionFilterGroup(
              title: 'Salas / Local',
              yesLabel: 'Con Salas/Local',
              noLabel: 'Sin Salas/Local',
              selectFilter: (s) => s.friendPlayFilter,
              selectExperience: (s) => s.friendPlayExperience,
              onFilterChanged: (t) => context.read<HomeCubit>().updateFlag(friendPlayFilter: t),
              onExperienceChanged: (e) => context.read<HomeCubit>().updateFlag(friendPlayExperience: e),
            ),

            _InteractionFilterGroup(
              title: 'Matchmaking',
              yesLabel: 'Con Matchmaking',
              noLabel: 'Sin Matchmaking',
              selectFilter: (s) => s.matchmakingFilter,
              selectExperience: (s) => s.matchmakingExperience,
              onFilterChanged: (t) => context.read<HomeCubit>().updateFlag(matchmakingFilter: t),
              onExperienceChanged: (e) => context.read<HomeCubit>().updateFlag(matchmakingExperience: e),
            ),

            _buildGroup(
              'Logros de Steam',
              _TriFilterChips(
                yesLabel: 'Con Logros',
                noLabel: 'Sin Logros',
                selector: (s) => s.achievementsFilter,
                onSelected: (t) => context.read<HomeCubit>().updateFlag(achievementsFilter: t),
              ),
            ),

            _buildGroup(
              'Steam Cloud',
              _TriFilterChips(
                yesLabel: 'Soporta Cloud',
                noLabel: 'Sin Cloud',
                selector: (s) => s.steamCloudFilter,
                onSelected: (t) => context.read<HomeCubit>().updateFlag(steamCloudFilter: t),
              ),
            ),

            _buildGroup(
              'Precio',
              _TriFilterChips(
                yesLabel: 'Gratuitos',
                noLabel: 'De Pago',
                selector: (s) => s.priceFilter,
                onSelected: (t) => context.read<HomeCubit>().updateFlag(priceFilter: t),
              ),
            ),

            _buildGroup(
              'GeForce NOW',
              _TriFilterChips(
                yesLabel: 'En GFN',
                noLabel: 'No en GFN',
                selector: (s) => s.geforceNowFilter,
                onSelected: (t) => context.read<HomeCubit>().updateFlag(geforceNowFilter: t),
              ),
            ),

            _buildGroup(
              'Otras características',
              Wrap(
                spacing: 6, runSpacing: 6,
                children: [
                  _BooleanFilterChip(
                    label: 'Incluir aplicaciones',
                    selector: (c) => c.state.includeSoftware,
                    onToggled: (val) => context.read<HomeCubit>().updateFlag(software: val),
                  ),
                  _BooleanFilterChip(
                    label: 'Formato binario (MiB/GiB)',
                    selector: (c) => c.state.binaryFormat,
                    onToggled: (val) => context.read<HomeCubit>().updateFlag(binary: val),
                  ),
                ],
              ),
            ),

            _buildGroup(
              'HowLongToBeat',
              const _HltbRefreshControls(),
            ),

            _buildGroup(
              'Distribución del Slider',
              const _SliderDistributionChips(),
            ),

            BlocBuilder<HomeCubit, HomeState>(
              buildWhen: (p, c) => p.groupByStatus != c.groupByStatus || !identical(p.statusFilters, c.statusFilters),
              builder: (ctx, state) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
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
                          size: 18,
                        ),
                        onSelected: (v) => ctx.read<HomeCubit>().updateFlag(groupByStatus: v),
                      ),
                    ],
                  ),
                  _StatusChipGrid(config: state.statusFilters),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _SpTypeFilterChip extends StatelessWidget {
  final SpType spType;
  const _SpTypeFilterChip({required this.spType});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select((HomeCubit c) => c.state.visibleSpTypes.contains(spType));
    return FilterChip(
      showCheckmark: false,
      label: Text(_spTypeName(spType)),
      selected: isSelected,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => context.read<HomeCubit>().toggleSpTypeFilter(spType, val),
    );
  }
}

class _VrFilterChip extends StatelessWidget {
  final VrSupport vrSupport;
  const _VrFilterChip({required this.vrSupport});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select((HomeCubit c) => c.state.visibleVrTypes.contains(vrSupport));
    return FilterChip(
      showCheckmark: false,
      label: Text(_vrName(vrSupport)),
      selected: isSelected,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => context.read<HomeCubit>().toggleVrFilter(vrSupport, val),
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

class _LanguageFilterChip extends StatelessWidget {
  final GameLanguage language;
  const _LanguageFilterChip({required this.language});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select((HomeCubit c) => c.state.visibleLanguages.contains(language));
    return FilterChip(
      showCheckmark: false,
      label: Text(_langName(language)),
      selected: isSelected,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => context.read<HomeCubit>().toggleLanguageFilter(language, val),
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
  late List<StatusEntry> _preview;
  GameStatus? _dragging;

  @override
  void initState() {
    super.initState();
    _preview = List.of(widget.config);
  }

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
    setState(() {
      final item = _preview.removeAt(fi);
      _preview.insert(ti, item);
    });
  }

  void _commit() {
    if (_dragging == null) return;
    context.read<HomeCubit>().updateFlag(statusFilters: List.of(_preview));
    setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
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
    final cs = Theme.of(context).colorScheme;
    final isThisDragging = currentlyDragging == status;
    final chip = _StatusFilterChip(status: status);
    final feedback = Material(
      type: MaterialType.transparency,
      elevation: 4,
      shadowColor: cs.shadow,
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
        final isTarget = candidates.isNotEmpty && !isThisDragging;
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
    final cubit = context.read<HomeCubit>();
    final isSelected = context.select<HomeCubit, bool>(
      (c) => c.state.isStatusVisible(status),
    );
    final color = _statusColor(status, Theme.of(context).brightness == Brightness.dark);

    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_statusName(status)),
          const SizedBox(width: 3),
          Icon(
            Icons.drag_indicator,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
        ],
      ),
      selected: isSelected,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (val) => cubit.toggleStatusFilter(status, val),
      backgroundColor: color.withValues(alpha: 0.25),
      selectedColor: color.withValues(alpha: 0.55),
      // side: BorderSide.none,
    );
  }
}

// ==========================================
// CONTROLES DE SLIDERS AISLADOS Y OPTIMIZADOS
// ==========================================

class _DiscreteStepCache {
  double _min = -1;
  double _max = -1;
  bool _binary = false;
  List<double> _steps = [];

  List<double> getSteps(HomeState state) {
    if (_min == state.absoluteMinBytes &&
        _max == state.absoluteMaxBytes &&
        _binary == state.binaryFormat &&
        _steps.isNotEmpty) {
      return _steps;
    }

    _min = state.absoluteMinBytes;
    _max = state.absoluteMaxBytes;
    _binary = state.binaryFormat;

    final mb = _binary ? 1048576.0 : 1000000.0;
    final gb = _binary ? 1073741824.0 : 1000000000.0;

    _steps = [_min];

    double current = _snapToUnit(_min, _binary, mb, gb);
    if (current <= _min) current += (current < gb ? mb : gb);

    int safety = 0;
    while (current < _max && safety < 50000) {
      _steps.add(current);
      current += (current < gb ? mb : gb);
      safety++;
    }

    if (_steps.last < _max) _steps.add(_max);

    return _steps;
  }

  static double _snapToUnit(double bytes, bool isBinary, double mb, double gb) {
    final divisor = bytes >= gb ? gb : mb;
    return (bytes / divisor).roundToDouble() * divisor;
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
  double? _localMinBytes;
  double? _localMaxBytes;

  bool get _isInteracting => _isDragging || minFocus.hasFocus || maxFocus.hasFocus;

  @override
  void initState() {
    super.initState();
    minFocus.addListener(_onFocusChange);
    maxFocus.addListener(_onFocusChange);
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

  void _onFocusChange() {
    if (!_isInteracting) {
      final state = context.read<HomeCubit>().state;
      _localMinBytes = state.currentMinBytes;
      _localMaxBytes = state.currentMaxBytes;
      _updateTextFields(_localMinBytes!, _localMaxBytes!, state.binaryFormat);
    }
  }

  void _updateTextFields(double minB, double maxB, bool isBinary) {
    final minStr = _formatUnitValue(minB, isBinary);
    final maxStr = _formatUnitValue(maxB, isBinary);
    if (minCtrl.text != minStr) minCtrl.text = minStr;
    if (maxCtrl.text != maxStr) maxCtrl.text = maxStr;
  }

  void _submitManualEntry(TextEditingController ctrl, bool isMin, double unitDivisor) {
    _debounceTimer?.cancel();

    final state = context.read<HomeCubit>().state;
    final currentBytes = isMin ? (_localMinBytes ?? state.currentMinBytes) : (_localMaxBytes ?? state.currentMaxBytes);

    double parsed = double.tryParse(ctrl.text) ?? (currentBytes / unitDivisor);
    double newBytes = parsed * unitDivisor;

    if (isMin) {
      _localMinBytes = newBytes;
    } else {
      _localMaxBytes = newBytes;
    }

    context.read<HomeCubit>().updateRange(_localMinBytes!, _localMaxBytes!);
    FocusScope.of(context).unfocus();
  }

  void _onSliderChanged(double calcMin, double calcMax, bool isBinary) {
    setState(() {
      _localMinBytes = calcMin;
      _localMaxBytes = calcMax;
    });

    _updateTextFields(calcMin, calcMax, isBinary);

    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        context.read<HomeCubit>().updateRange(_localMinBytes!, _localMaxBytes!);
      }
    });
  }

  void _onSliderChangeEnd() {
    setState(() => _isDragging = false);

    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
      context.read<HomeCubit>().updateRange(_localMinBytes!, _localMaxBytes!);
    }
  }

  double _bytesToSlider(double bytes, HomeState state, List<double> steps) {
    final dist = state.sliderDistribution;
    if (dist == SliderDistribution.discrete) {
      if (steps.length <= 1) return 0.0;
      if (bytes <= steps.first) return 0.0;
      if (bytes >= steps.last) return 1.0;

      int low = 0;
      int high = steps.length - 1;

      while (low <= high) {
        int mid = (low + high) >> 1;
        if (steps[mid] == bytes) return mid / (steps.length - 1);
        if (steps[mid] < bytes) {
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }

      double diffLow = (bytes - steps[high]).abs();
      double diffHigh = (steps[low] - bytes).abs();
      return (diffLow < diffHigh ? high : low) / (steps.length - 1);
    }

    final minB = state.absoluteMinBytes;
    final maxB = state.absoluteMaxBytes;
    if (bytes <= minB) return 0.0;
    if (bytes >= maxB) return 1.0;
    final fraction = (bytes - minB) / (maxB - minB);
    return switch (dist) {
      SliderDistribution.quadratic => sqrt(fraction),
      SliderDistribution.cubic => pow(fraction, 1 / 3).toDouble(),
      _ => fraction,
    };
  }

  double _sliderToBytes(double sliderVal, HomeState state, List<double> steps) {
    final dist = state.sliderDistribution;
    if (dist == SliderDistribution.discrete) {
      if (steps.isEmpty) return state.absoluteMinBytes;
      if (steps.length == 1) return steps.first;

      int index = (sliderVal * (steps.length - 1)).round();
      return steps[index.clamp(0, steps.length - 1)];
    }

    final minB = state.absoluteMinBytes;
    final maxB = state.absoluteMaxBytes;
    if (sliderVal <= 0.0) return minB;
    if (sliderVal >= 1.0) return maxB;

    final fraction = switch (dist) {
      SliderDistribution.quadratic => pow(sliderVal, 2).toDouble(),
      SliderDistribution.cubic => pow(sliderVal, 3).toDouble(),
      _ => sliderVal,
    };

    return minB + fraction * (maxB - minB);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<HomeCubit, HomeState>(
      listenWhen: (prev, curr) {
        return prev.currentMinBytes != curr.currentMinBytes ||
               prev.currentMaxBytes != curr.currentMaxBytes ||
               prev.binaryFormat != curr.binaryFormat ||
               prev.absoluteMaxBytes != curr.absoluteMaxBytes;
      },
      listener: (context, state) {
        if (!_isInteracting) {
          setState(() {
            _localMinBytes = state.currentMinBytes;
            _localMaxBytes = state.currentMaxBytes;
          });
          _updateTextFields(_localMinBytes!, _localMaxBytes!, state.binaryFormat);
        }
      },
      child: BlocBuilder<HomeCubit, HomeState>(
        buildWhen: (prev, curr) =>
            prev.absoluteMinBytes != curr.absoluteMinBytes ||
            prev.absoluteMaxBytes != curr.absoluteMaxBytes ||
            prev.binaryFormat != curr.binaryFormat ||
            prev.sliderDistribution != curr.sliderDistribution,
        builder: (context, state) {
          final cMin = _localMinBytes ?? state.currentMinBytes;
          final cMax = _localMaxBytes ?? state.currentMaxBytes;
          final steps = _stepCache.getSteps(state);

          final tMin = _bytesToSlider(cMin, state, steps).clamp(0.0, 1.0);
          final tMax = _bytesToSlider(cMax, state, steps).clamp(0.0, 1.0);

          return Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildEditableLimit(minCtrl, minFocus, true, cMin, state.binaryFormat),
                  _buildEditableLimit(maxCtrl, maxFocus, false, cMax, state.binaryFormat),
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
                  onChanged: (values) {
                    final mb = state.binaryFormat ? 1048576.0 : 1000000.0;
                    final gb = state.binaryFormat ? 1073741824.0 : 1000000000.0;
                    double calcMin = _DiscreteStepCache._snapToUnit(_sliderToBytes(values.start, state, steps), state.binaryFormat, mb, gb);
                    double calcMax = _DiscreteStepCache._snapToUnit(_sliderToBytes(values.end, state, steps), state.binaryFormat, mb, gb);
                    _onSliderChanged(calcMin, calcMax, state.binaryFormat);
                  },
                  onChangeEnd: (_) => _onSliderChangeEnd(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEditableLimit(TextEditingController ctrl, FocusNode focus, bool isMin, double currentBytes, bool isBinary) {
    final ud = _unitData(currentBytes, isBinary);
    final double baseMB = isBinary ? 1048576.0 : 1000000.0;
    final double baseGB = isBinary ? 1073741824.0 : 1000000000.0;

    return TapRegion(
      onTapOutside: (event) {
        if (focus.hasFocus) {
          focus.unfocus();
          _submitManualEntry(ctrl, isMin, ud.divisor);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        spacing: 6,
        children: [
          IntrinsicWidth(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
              onSubmitted: (_) => _submitManualEntry(ctrl, isMin, ud.divisor),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<double>(
              value: ud.divisor,
              isDense: true, iconSize: 20,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
              items: [
                DropdownMenuItem(value: baseMB, child: Text(isBinary ? "MiB" : "MB")),
                DropdownMenuItem(value: baseGB, child: Text(isBinary ? "GiB" : "GB")),
              ],
              onChanged: (newDivisor) {
                if (newDivisor != null) _submitManualEntry(ctrl, isMin, newDivisor);
              },
            ),
          ),
        ],
      ),
    );
  }
}
