/// Extensions for nullable String helpers.
extension DHUNullSafeStringExtensions on String? {
  /// Returns true if the string is null, empty, or solely made of whitespace characters.
  bool get isEmptyOrNull => this == null || this!.trim().isEmpty;

  /// Returns true if the string is null, empty, or solely made of whitespace characters.
  /// Alias for [isEmptyOrNull].
  bool get isBlank => isEmptyOrNull;

  /// Returns true if the string is not null, not empty, and contains non-whitespace characters.
  bool get isNotEmptyOrNull => !isEmptyOrNull;

  /// Returns true if the string is neither null, empty, nor solely made of whitespace characters.
  /// Alias for [isNotEmptyOrNull].
  bool get isNotBlank => isNotEmptyOrNull;
}

/// DHUMapNullableExtension
extension DHUMapNullableExtension<K, V> on Map<K, V>? {
  /// Returns `true` when the map is `null` or empty.
  bool get isEmptyOrNull => this == null || this!.isEmpty;

  /// Returns `true` when the map is non-null and not empty.
  bool get isNotEmptyOrNull => !isEmptyOrNull;
}

/// Utility extensions for nullable iterables.
extension DHUCollectionsExtensionsNS<E> on Iterable<E>? {
  /// Returns `true` if this nullable iterable is either null or empty.
  bool get isEmptyOrNull => this == null || this!.isEmpty;

  /// Returns `false` if this nullable iterable is either null or empty.
  bool get isNotEmptyOrNull => !isEmptyOrNull;
}
