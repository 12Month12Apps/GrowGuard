# SwiftGen Integration für GrowGuard

Diese App verwendet [SwiftGen](https://github.com/SwiftGen/SwiftGen) für die typsichere Generierung von lokalisierten Strings.

## Setup

### 1. Installation
SwiftGen ist bereits über Homebrew installiert:
```bash
brew install swiftgen
```

### 2. Konfiguration
- `swiftgen.yml` - Konfigurationsdatei im Projektroot
- `GrowGuard/Localizable.strings` - String-Definitionen
- `GrowGuard/Generated/Strings+Generated.swift` - Generierte Swift-Konstanten

## Verwendung

### Strings hinzufügen
1. Neue Strings in `GrowGuard/Localizable.strings` hinzufügen:
```
"new.key" = "New String Value";
```

2. SwiftGen ausführen:
```bash
swiftgen
```

3. Generierte Konstanten verwenden:
```swift
Text(L10n.New.key)
// oder über die LocalizedStrings-Wrapper:
Text(LocalizedStrings.New.key)
```

### Parametrisierte Strings
SwiftGen erkennt automatisch Parameter in Strings:

```
"greeting.message" = "Hello %@, you have %d messages";
```

Generiert:
```swift
L10n.Greeting.message("John", 5) // "Hello John, you have 5 messages"
```

## Automatische Generierung

Das Script `Scripts/swiftgen.sh` kann als Build Phase in Xcode hinzugefügt werden, um SwiftGen bei jedem Build automatisch auszuführen.

## Vorteile

✅ **Type Safety** - Compile-time Überprüfung aller String-Referenzen
✅ **Auto-Completion** - Xcode zeigt alle verfügbaren Strings
✅ **Refactoring Support** - Automatische Aktualisierung bei String-Änderungen
✅ **Fallback Values** - Eingebaute Fallback-Werte falls Lokalisierung fehlt
✅ **Hierarchische Struktur** - Automatische Namespacing basierend auf String-Keys

## String-Struktur

```
"navigation.menu" = "Menu";
"device.error.notFound" = "Device not found";
```

Wird zu:
```swift
L10n.Navigation.menu
L10n.Device.Error.notFound
```