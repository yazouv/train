#!/usr/bin/env bash
# Usage : set-version.sh X.Y.Z
# Écrit la version dans Cargo.toml ([package]) et dans l'entrée du paquet de Cargo.lock.
set -euo pipefail

version="${1:?version manquante}"
version="${version#v}"

pkg=$(awk -F'"' '/^\[package\]/{p=1; next} /^\[/{p=0} p && /^name *=/{print $2; exit}' Cargo.toml)
[ -n "$pkg" ] || { echo "Nom du paquet introuvable dans Cargo.toml" >&2; exit 1; }

awk -v v="$version" '
  /^\[package\]/ { p = 1 } /^\[/ && !/^\[package\]/ { p = 0 }
  p && !done && /^version *=/ { print "version = \"" v "\""; done = 1; next }
  { print }
' Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml

if [ -f Cargo.lock ]; then
  awk -v n="$pkg" -v v="$version" '
    $0 == "name = \"" n "\"" { hit = 1; print; next }
    hit && /^version = / { print "version = \"" v "\""; hit = 0; next }
    { hit = 0; print }
  ' Cargo.lock > Cargo.lock.tmp && mv Cargo.lock.tmp Cargo.lock
fi

echo "$pkg -> $version"
