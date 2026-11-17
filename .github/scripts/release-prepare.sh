#!/usr/bin/env bash
# Calcule et valide la version de la release, puis génère le patch note.
#
# Entrées (variables d'environnement) :
#   VERSION_INPUT  version voulue (ex. 1.2.0 ou v1.2.0) ; vide = détection automatique
#   BUMP           auto | patch | minor | major (ignoré si VERSION_INPUT est fourni)
#   NOTES_FILE     fichier de sortie du patch note (défaut : release-notes.md)
#   REPO_URL       https://github.com/owner/repo (pour les liens ; optionnel)
#
# Sorties (dans $GITHUB_OUTPUT si défini) : version, tag, previous_tag
set -euo pipefail

VERSION_INPUT="${VERSION_INPUT:-}"
BUMP="${BUMP:-auto}"
NOTES_FILE="${NOTES_FILE:-release-notes.md}"
REPO_URL="${REPO_URL:-}"

fail() { echo "::error::$*" >&2; echo "ERREUR : $*" >&2; exit 1; }
semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'

# ------------------------------------------------------------ dernière version publiée
prev_tag=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)
prev="${prev_tag#v}"
cargo_version=$(awk -F'"' '/^\[package\]/{p=1; next} /^\[/{p=0} p && /^version *=/{print $2; exit}' Cargo.toml)

if [ -n "$prev_tag" ]; then
  range="$prev_tag..HEAD"
  echo "Dernière release : $prev_tag"
  [ -n "$(git log --format=%H "$range")" ] || fail "Aucun commit depuis $prev_tag : rien à publier."
else
  range="HEAD"
  echo "Aucune release précédente (Cargo.toml : $cargo_version)"
fi

# ------------------------------------------------------------ commits (sujet + corps)
# Séparateurs : \x1f entre champs, \x1e entre commits.
commits=$(git log --no-merges --format='%H%x1f%s%x1f%b%x1e' $range)

# ------------------------------------------------------------ version cible
version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

if [ -n "$VERSION_INPUT" ]; then
  version="${VERSION_INPUT#v}"
  [[ "$version" =~ $semver_re ]] || fail "« $VERSION_INPUT » n'est pas une version valide (format attendu : X.Y.Z, ex. 1.2.0)."
  if [ -n "$prev" ] && ! version_gt "$version" "$prev"; then
    fail "v$version doit être strictement supérieure à la dernière release $prev_tag."
  fi
  source="manuelle"
else
  if [ -z "$prev" ]; then
    # Première release : on publie la version déclarée dans Cargo.toml.
    [[ "$cargo_version" =~ $semver_re ]] || fail "Version de Cargo.toml invalide : $cargo_version"
    version="$cargo_version"
    source="Cargo.toml (première release)"
  else
    IFS=. read -r ma mi pa <<< "$prev"
    level="$BUMP"
    if [ "$level" = auto ]; then
      level=patch
      subjects=$(printf '%s' "$commits" | tr '\036' '\n' | cut -d$'\x1f' -f2)
      if printf '%s' "$commits" | grep -qE 'BREAKING[ -]CHANGE' \
         || printf '%s\n' "$subjects" | grep -qE '^[a-zA-Z]+(\([^)]*\))?!:'; then
        level=major
      elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
        level=minor
      fi
      # Avant la 1.0.0, un changement cassant ne fait monter que la mineure.
      if [ "$level" = major ] && [ "$ma" = 0 ]; then level=minor; fi
      source="auto ($level)"
    else
      source="forcée ($level)"
    fi
    case "$level" in
      major) version="$((ma + 1)).0.0" ;;
      minor) version="$ma.$((mi + 1)).0" ;;
      patch) version="$ma.$mi.$((pa + 1))" ;;
      *) fail "BUMP inconnu : $level (attendu : auto, patch, minor, major)" ;;
    esac
  fi
fi

tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "Le tag $tag existe déjà."
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && fail "Le tag $tag existe déjà sur origin."

echo "Version : $tag — $source"

# ------------------------------------------------------------ patch note
declare -A sections
order=(breaking feat fix perf refactor docs test build ci chore other)
declare -A titles=(
  [breaking]="⚠️ Changements cassants" [feat]="✨ Nouveautés" [fix]="🐛 Corrections"
  [perf]="⚡ Performances" [refactor]="♻️ Refactoring" [docs]="📝 Documentation"
  [test]="✅ Tests" [build]="📦 Build" [ci]="👷 CI" [chore]="🔧 Maintenance" [other]="Autres changements"
)

while IFS=$'\x1f' read -r -d $'\x1e' sha subject body; do
  sha="${sha#$'\n'}"
  [ -n "$sha" ] || continue
  short="${sha:0:7}"
  link="$short"; [ -n "$REPO_URL" ] && link="[\`$short\`]($REPO_URL/commit/$sha)"

  if [[ "$subject" =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:[[:space:]]*(.*)$ ]]; then
    type="${BASH_REMATCH[1],,}"; scope="${BASH_REMATCH[3]}"; bang="${BASH_REMATCH[4]}"; desc="${BASH_REMATCH[5]}"
  else
    type=other; scope=""; bang=""; desc="$subject"
  fi
  case "$type" in feat|fix|perf|refactor|docs|test|build|ci|chore) ;; *) type=other ;; esac
  [ "$type" = chore ] && [[ "$desc" =~ ^release ]] && continue

  line="- ${scope:+**$scope :** }$desc ($link)"
  if [ -n "$bang" ] || [[ "$body" =~ BREAKING[\ -]CHANGE ]]; then
    sections[breaking]+="$line"$'\n'
  else
    sections[$type]+="$line"$'\n'
  fi
done <<< "$commits"

{
  for key in "${order[@]}"; do
    [ -n "${sections[$key]:-}" ] || continue
    printf '## %s\n\n%s\n' "${titles[$key]}" "${sections[$key]}"
  done
  if [ -n "$REPO_URL" ]; then
    if [ -n "$prev_tag" ]; then
      printf '**Changelog complet** : %s/compare/%s...%s\n' "$REPO_URL" "$prev_tag" "$tag"
    else
      printf '**Changelog complet** : %s/commits/%s\n' "$REPO_URL" "$tag"
    fi
  fi
} > "$NOTES_FILE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "version=$version"; echo "tag=$tag"; echo "previous_tag=$prev_tag"; } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "# Release $tag"; echo; echo "Version $source${prev_tag:+, précédente : $prev_tag}"; echo; cat "$NOTES_FILE"; } >> "$GITHUB_STEP_SUMMARY"
fi
