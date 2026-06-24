import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import 'hltb_service.dart';
import 'model.dart';
import 'state.dart';

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

String _formatHours(double? hours) {
  if (hours == null || hours <= 0) return '--';
  final m = (hours * 60).round();
  final hh = m ~/ 60;
  final mm = m % 60;
  return switch ((hh, mm)) {
    (0, _) => '${mm}m',
    (_, 0) => '${hh}h',
    _ => '${hh}h ${mm}m',
  };
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

// ==========================================
// WIDGET PRINCIPAL
// ==========================================
class HomeView extends StatelessWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
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
              showDialog(
                context: context,
                builder: (ctx) {
                  final g = games[_random.nextInt(games.length)];
                  return _GameDialog(gameId: g.internalId, initialGame: g);
                },
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'import') {
                _showJsonDialog(context, isUpdate: false);
              } else if (value == 'update') {
                _showJsonDialog(context, isUpdate: true);
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
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'import', child: Text('Importar biblioteca')),
              PopupMenuItem(value: 'update', child: Text('Actualizar biblioteca')),
              PopupMenuItem(value: 'export', child: Text('Exportar biblioteca')),
              PopupMenuItem(value: 'clear', child: Text('Vaciar biblioteca')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'update_gfn', child: Text('Sincronizar datos de GeForce NOW')),
              PopupMenuItem(value: 'refetch_steam', child: Text('Sincronizar datos de Steam')),
              PopupMenuItem(value: 'refetch_hltb', child: Text('Sincronizar datos de HLTB')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'esde_path', child: Text('Vincular carpeta de ES-DE')),
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
          if (!hasGames)
            const Expanded(
              child: Center(child: Text('No hay datos. Importa un JSON para comenzar.')),
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

  void _showJsonDialog(BuildContext context, {required bool isUpdate}) {
    final TextEditingController jsonCtrl = TextEditingController();
    String? selectedFileName;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(isUpdate ? 'Actualizar JSON' : 'Importar JSON'),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12.0,
                  children: [
                    Text(isUpdate
                        ? 'Se actualizarán los juegos existentes y se añadirán los nuevos.'
                        : 'Se eliminarán los datos actuales y se reemplazarán.'),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                        side: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
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
                          Icon(Icons.folder_open, color: Theme.of(context).colorScheme.primary, size: 24),
                          Expanded(
                            child: Text(
                              selectedFileName ?? 'Tocar para elegir archivo...',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: selectedFileName == null
                                  ? Theme.of(context).textTheme.bodyMedium?.color
                                  : Theme.of(context).colorScheme.primary,
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
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6))
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              ElevatedButton(
                onPressed: () {
                  if (jsonCtrl.text.isNotEmpty) {
                    context.read<HomeCubit>().processJson(jsonCtrl.text, replace: !isUpdate);
                  }
                  Navigator.pop(ctx);
                },
                child: Text(isUpdate ? 'Actualizar' : 'Importar'),
              ),
            ],
          );
        }
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

class _CompactControls extends StatelessWidget {
  const _CompactControls();

  @override
  Widget build(BuildContext context) {
    final hasGames = context.select((HomeCubit c) => c.state.gameCount > 0);
    final sortBy = context.select((HomeCubit c) => c.state.sortBy);
    final sortAsc = context.select((HomeCubit c) => c.state.sortAsc);
    final isFetching = context.select((HomeCubit c) => c.state.isFetchingSteam);
    final isFetchingGfn = context.select((HomeCubit c) => c.state.isFetchingGfnDb);
    final isFetchingHltb = context.select((HomeCubit c) => c.state.isFetchingHltb);
    final pendingCount = context.select((HomeCubit c) => c.state.steamQueueSize);
    final pendingHltbCount = context.select((HomeCubit c) => c.state.hltbQueueSize);

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
              if (isFetching || isFetchingGfn || isFetchingHltb)
                IconButton(
                  tooltip: [
                    'Sincronizando:',
                    if (isFetchingGfn) '• GeForce NOW: descargando catálogo',
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
                ),

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
              onLongPress: () => showDialog(
                context: context,
                builder: (ctx) => _GameDialog(gameId: game.internalId, initialGame: game),
              ),
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
                    // td(_formatHours(mainStory.classic)),
                    td(_formatHours(mainStory.average)),
                    td(_formatHours(mainStory.median)),
                    td(_formatHours(mainStory.rushed)),
                    td(_formatHours(mainStory.leisure), trailing: true),
                  ]),
                  if (!extras.isEmpty) TableRow(children: [
                    td('+ Extras', isLabel: true),
                    // td(_formatHours(extras.classic)),
                    td(_formatHours(extras.average)),
                    td(_formatHours(extras.median)),
                    td(_formatHours(extras.rushed)),
                    td(_formatHours(extras.leisure), trailing: true),
                  ]),
                  if (!completionist.isEmpty) TableRow(children: [
                    td('Platinado', isLabel: true),
                    // td(_formatHours(completionist.classic)),
                    td(_formatHours(completionist.average)),
                    td(_formatHours(completionist.median)),
                    td(_formatHours(completionist.rushed)),
                    td(_formatHours(completionist.leisure), trailing: true),
                  ]),
                  if (!allPlayStyles.isEmpty) TableRow(children: [
                    td('Todos los estilos', isLabel: true),
                    // td(_formatHours(allPlayStyles.classic)),
                    td(_formatHours(allPlayStyles.average)),
                    td(_formatHours(allPlayStyles.median)),
                    td(_formatHours(allPlayStyles.rushed)),
                    td(_formatHours(allPlayStyles.leisure), trailing: true),
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
// BOTTOM SHEET DE FILTROS
// ==========================================
class _FilterBottomSheet extends StatefulWidget {
  const _FilterBottomSheet();

  @override
  State<_FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<_FilterBottomSheet> {
  late TextEditingController _searchCtrl;
  String _profileName = '';

  @override
  void initState() {
    super.initState();
    final currentQuery = context.read<HomeCubit>().state.searchQuery;
    _searchCtrl = TextEditingController(text: currentQuery);
    _searchCtrl.addListener(() => setState(() {}));
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
            _buildGroup(
              'Perfil de filtros',
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
                                _searchCtrl.text = context.read<HomeCubit>().state.searchQuery;
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
            ),

            _buildGroup(
              'Búsqueda',
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Buscar título...',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  suffixIcon: _searchCtrl.text.isNotEmpty ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchCtrl.clear();
                      context.read<HomeCubit>().updateFlag(searchQuery: '');
                    },
                  ) : null,
                ),
                onChanged: (val) => context.read<HomeCubit>().updateFlag(searchQuery: val),
              ),
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

            _buildGroup(
              'Salas / Local',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.friendPlayFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(friendPlayFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Con Salas/Local'),
                      selected: state.friendPlayFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(friendPlayFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Sin Salas/Local'),
                      selected: state.friendPlayFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(friendPlayFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
              ),
              context.select((HomeCubit c) => c.state.friendPlayFilter) != TriFilter.no
                ? BlocBuilder<HomeCubit, HomeState>(
                    builder: (ctx, state) => Wrap(
                      spacing: 6, runSpacing: 6,
                      children: ExperienceFilter.values.map((exp) => ChoiceChip(
                        label: Text(_expName(exp)),
                        selected: state.friendPlayExperience == exp,
                        showCheckmark: false,
                        onSelected: (v) {
                          if (v) context.read<HomeCubit>().updateFlag(friendPlayExperience: exp);
                        },
                      )).toList(),
                    ),
                  )
                : null,
            ),

            _buildGroup(
              'Matchmaking',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.matchmakingFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(matchmakingFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Con Matchmaking'),
                      selected: state.matchmakingFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(matchmakingFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Sin Matchmaking'),
                      selected: state.matchmakingFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(matchmakingFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
              ),
              context.select((HomeCubit c) => c.state.matchmakingFilter) != TriFilter.no
                ? BlocBuilder<HomeCubit, HomeState>(
                    builder: (ctx, state) => Wrap(
                      spacing: 6, runSpacing: 6,
                      children: ExperienceFilter.values.map((exp) => ChoiceChip(
                        label: Text(_expName(exp)),
                        selected: state.matchmakingExperience == exp,
                        showCheckmark: false,
                        onSelected: (v) {
                          if (v) context.read<HomeCubit>().updateFlag(matchmakingExperience: exp);
                        },
                      )).toList(),
                    ),
                  )
                : null,
            ),

            _buildGroup(
              'Logros de Steam',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.achievementsFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(achievementsFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Con Logros'),
                      selected: state.achievementsFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(achievementsFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Sin Logros'),
                      selected: state.achievementsFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(achievementsFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
              ),
            ),

            _buildGroup(
              'Steam Cloud',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.steamCloudFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(steamCloudFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Soporta Cloud'),
                      selected: state.steamCloudFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(steamCloudFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Sin Cloud'),
                      selected: state.steamCloudFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(steamCloudFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
              ),
            ),

            _buildGroup(
              'Precio',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.priceFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(priceFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Gratuitos'),
                      selected: state.priceFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(priceFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('De Pago'),
                      selected: state.priceFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(priceFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
              ),
            ),

            _buildGroup(
              'GeForce NOW',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: state.geforceNowFilter == TriFilter.all,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(geforceNowFilter: TriFilter.all);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('En GFN'),
                      selected: state.geforceNowFilter == TriFilter.yes,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(geforceNowFilter: TriFilter.yes);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('No en GFN'),
                      selected: state.geforceNowFilter == TriFilter.no,
                      showCheckmark: false,
                      onSelected: (v) {
                        if (v) context.read<HomeCubit>().updateFlag(geforceNowFilter: TriFilter.no);
                      },
                    ),
                  ],
                ),
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
              'Distribución del Slider',
              BlocBuilder<HomeCubit, HomeState>(
                builder: (ctx, state) => Wrap(
                  spacing: 6, runSpacing: 6,
                  children: SliderDistribution.values.map((dist) => ChoiceChip(
                    label: Text(_distName(dist)),
                    selected: state.sliderDistribution == dist,
                    showCheckmark: false,
                    onSelected: (v) {
                      if (v) context.read<HomeCubit>().updateFlag(sliderDistribution: dist);
                    },
                  )).toList(),
                ),
              ),
            ),

            _buildGroup(
              'Estatus',
              Wrap(
                spacing: 6, runSpacing: 6,
                children: GameStatus.values.map((s) => _StatusFilterChip(status: s)).toList(),
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
      onSelected: (val) => context.read<HomeCubit>().toggleLanguageFilter(language, val),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  final GameStatus status;
  const _StatusFilterChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final isSelected = context.select((HomeCubit c) => c.state.visibleStatuses.contains(status));
    return FilterChip(
      showCheckmark: false,
      label: Text(_statusName(status)),
      selectedColor: _statusColor(status, Theme.of(context).brightness == Brightness.dark).withValues(alpha: 0.4),
      selected: isSelected,
      onSelected: (val) => context.read<HomeCubit>().toggleStatusFilter(status, val),
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
    final minStr = _formatValue(minB, isBinary);
    final maxStr = _formatValue(maxB, isBinary);
    if (minCtrl.text != minStr) minCtrl.text = minStr;
    if (maxCtrl.text != maxStr) maxCtrl.text = maxStr;
  }

  static String _formatValue(double bytes, bool isBinary) {
    final (:divisor, name: _) = _getUnitData(bytes, isBinary);
    final val = bytes / divisor;
    return val == val.toInt() ? val.toInt().toString() : val.toStringAsFixed(2);
  }

  static ({double divisor, String name}) _getUnitData(double bytes, bool isBinary) =>
      switch ((isBinary, bytes >= (isBinary ? 1073741824.0 : 1000000000.0))) {
        (true, true) => (divisor: 1073741824.0, name: "GiB"),
        (true, false) => (divisor: 1048576.0, name: "MiB"),
        (false, true) => (divisor: 1000000000.0, name: "GB"),
        (false, false) => (divisor: 1000000.0, name: "MB"),
      };

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
    final ud = _getUnitData(currentBytes, isBinary);
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
