#!/usr/bin/env bash
# Voert een commando uit; bij een fout komt de relevante output als
# GitHub-annotatie in de build (handig als de logs niet direct zichtbaar zijn).
# Gebruik: ci/annotate.sh <label> <commando...>
label=$1; shift
out=$(mktemp)
"$@" >"$out" 2>&1
status=$?
cat "$out"
if [ $status -ne 0 ]; then
  msg=$(grep -E "error|Error|Exception|Expected|Actual|failed|FAILED|•|\.dart:[0-9]+" "$out" | head -60)
  [ -z "$msg" ] && msg=$(tail -40 "$out")
  msg=${msg//'%'/'%25'}
  msg=${msg//$'\r'/}
  msg=${msg//$'\n'/'%0A'}
  echo "::error title=$label::$msg"
fi
exit $status
