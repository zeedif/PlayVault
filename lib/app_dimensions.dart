import 'package:flutter/widgets.dart';

/// Escala de la interfaz, en múltiplos de 3. Sirve igual para separar hijos (`spacing`)
/// que como unidad de relleno, de modo que huecos y márgenes casen entre sí.
abstract final class AppSpacing {
  static const tiny = 3.0;
  static const small = 6.0;
  static const medium = 12.0;
  static const large = 18.0;
}

/// Rellenos que se repiten, compuestos sobre [AppSpacing].
abstract final class AppInsets {
  static const allMedium = EdgeInsets.all(AppSpacing.medium);
  static const allLarge = EdgeInsets.all(AppSpacing.large);
  static const horizontalMedium = EdgeInsets.symmetric(horizontal: AppSpacing.medium);
  static const horizontalLarge = EdgeInsets.symmetric(horizontal: AppSpacing.large);
  static const verticalSmall = EdgeInsets.symmetric(vertical: AppSpacing.small);
  static const verticalMedium = EdgeInsets.symmetric(vertical: AppSpacing.medium);

  /// Botones compactos, píldoras y campos de una línea.
  static const control = EdgeInsets.symmetric(horizontal: AppSpacing.medium, vertical: AppSpacing.small);
}

abstract final class AppRadius {
  static const small = BorderRadius.all(Radius.circular(AppSpacing.small));

  /// [small] como forma, para botones, chips y tarjetas.
  static const smallShape = RoundedRectangleBorder(borderRadius: small);
}

abstract final class AppIconSize {
  static const small = 12.0;
  static const medium = 18.0;
  static const large = 24.0;
}
