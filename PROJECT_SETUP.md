# Vattna SwiftGen Setup - Manuelle Schritte

## Dateien zum Xcode-Projekt hinzufügen

Die folgenden Dateien müssen **manuell zum Xcode-Projekt hinzugefügt werden**:

### 1. Localizable.strings
```
Datei: Vattna/Localizable.strings
Ziel: Vattna Target
Info: Enthält alle lokalisierten Strings
```

### 2. SwiftGen Generated Code
```
Datei: Vattna/Generated/Strings+Generated.swift  
Ziel: Vattna Target
Info: Von SwiftGen automatisch generierter Code
```

### 3. SwiftGen Build Script (Optional)
```
Datei: Scripts/swiftgen.sh
Info: Script für automatische SwiftGen-Ausführung bei jedem Build
```

## Xcode Build Phase hinzufügen (Optional)

**Target:** Vattna
**Phase:** New Run Script Phase
**Position:** Vor "Compile Sources"  
**Name:** "SwiftGen"
**Script:**
```bash
if which swiftgen >/dev/null; then
    swiftgen
else
    echo "warning: SwiftGen not installed, download from https://github.com/SwiftGen/SwiftGen"
fi
```

**Input Files:**
- `$(SRCROOT)/Vattna/Localizable.strings`

**Output Files:**  
- `$(SRCROOT)/Vattna/Generated/Strings+Generated.swift`

## SwiftGen Verwendung

### Vorher (manuell):
```swift
Text("Add Device")
Alert(title: Text("Error"), message: Text("Device not found"))
```

### Nachher (SwiftGen):
```swift  
Text(L10n.Navigation.addDevice)
Alert(title: Text(L10n.Alert.error), message: Text(L10n.Device.Error.notFound))
```

### Parametrisierte Strings:
```swift
// String: "Are you sure you want to delete '%@'?"
L10n.Device.deleteConfirmation("iPhone Device")

// String: "Current: %d%%" 
L10n.Watering.current(65)
```

## Strings regenerieren

Nach Änderungen an `Localizable.strings`:

```bash
cd /Users/veitprogl/Dev/Company/Vattna
swiftgen
```

## Vorteile

✅ **Compile-time Safety** - Typos werden zur Build-Zeit erkannt  
✅ **Auto-Completion** - Xcode zeigt alle verfügbaren Strings  
✅ **Automatic Namespacing** - Hierarchische Struktur basierend auf String-Keys  
✅ **Parameter Detection** - SwiftGen erkennt String-Parameter automatisch  
✅ **Fallback Values** - Eingebaute Fallback-Werte  

## String-Namenskonventionen

```
"navigation.menu" = "Menu";           → L10n.Navigation.menu
"device.error.notFound" = "Not found"; → L10n.Device.Error.notFound  
"watering.current" = "Current: %d%%"; → L10n.Watering.current(Int)
```