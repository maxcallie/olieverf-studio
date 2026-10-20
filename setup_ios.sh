#!/usr/bin/env bash
# Maakt het iOS-project aan en zet de benodigde rechten in Info.plist.
# Gebruik (op een Mac, in de map olieverf_studio):  bash setup_ios.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "Flutter niet gevonden. Installeer via https://docs.flutter.dev/get-started/install/macos"; exit 1; }

flutter create --project-name olieverf_studio --org nl.olieverfstudio --platforms=ios .

PLIST=ios/Runner/Info.plist
PB=/usr/libexec/PlistBuddy
setkey() { # key type value
  $PB -c "Delete :$1" "$PLIST" 2>/dev/null || true
  $PB -c "Add :$1 $2 $3" "$PLIST"
}
# Toegang tot de fotobibliotheek (foto kiezen)
setkey NSPhotoLibraryUsageDescription string "'Kies een foto om er een schilderij van te maken.'"
# Geëxporteerde bestanden zichtbaar in de Bestanden-app
setkey UIFileSharingEnabled bool true
setkey LSSupportsOpeningDocumentsInPlace bool true

flutter pub get
flutter test

echo
echo "Klaar. Volgende stap:"
echo "  open ios/Runner.xcworkspace   → Runner → Signing & Capabilities → kies je Team"
echo "  flutter run --release          (met je iPhone via USB aangesloten)"
