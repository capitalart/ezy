#!/usr/bin/env bash
# =====================================================================================
# EzyGallery — code-stacker.sh (tight include set, backup/temp excludes, toggles)
# Collect ONLY app code into two markdown files.
# Optional toggles:
#   INCLUDE_DOCS=true         # include .md/.txt
#   INCLUDE_TESTS=true        # include tests directory
#   INCLUDE_ART_PROCESSING=true
#   LIST_ONLY=true            # just list files, don’t write stacks
# =====================================================================================

set -euo pipefail

now="$(date "+%a-%d-%B-%Y-%I-%M-%p" | tr '[:lower:]' '[:upper:]')"

# ---------- Toggles ----------
INCLUDE_DOCS="${INCLUDE_DOCS:-false}"
INCLUDE_TESTS="${INCLUDE_TESTS:-false}"
INCLUDE_ART_PROCESSING="${INCLUDE_ART_PROCESSING:-false}"
LIST_ONLY="${LIST_ONLY:-false}"

# ---------- Include directories (default: app code only) ----------
INCLUDED_DIRS=(
  "helpers"
  "routes"
  "scripts"
  "settings"
  "static/css"
  "static/js"
  "templates"
  "utils"
)
[[ "${INCLUDE_TESTS,,}" == "true" ]] && INCLUDED_DIRS+=("tests")
[[ "${INCLUDE_ART_PROCESSING,,}" == "true" ]] && INCLUDED_DIRS+=("art-processing")

# ---------- Root files ----------
ROOT_FILES=(
  "app.py" "config.py" "requirements.txt"
  "toolkit.sh" "gpt-edit.sh" "gpt-edit-with-context.sh"
  "generate_folder_tree.py" "cron-backup.sh" "db.py"
)
# Docs at root are optional
if [[ "${INCLUDE_DOCS,,}" == "true" ]]; then
  ROOT_FILES+=("README.md" "CHANGELOG.md" "CODEX-README.md")
fi

# ---------- Extensions to include ----------
EXTLIST=( "*.py" "*.js" "*.css" "*.html" "*.json" "*.sh" "*.ini" "*.toml" "*.yml" "*.yaml" )
if [[ "${INCLUDE_DOCS,,}" == "true" ]]; then
  EXTLIST+=( "*.md" "*.txt" )
fi

# ---------- Exclusions anywhere in the path ----------
EXCLUDE_PATH_NAMES=(
  "venv" "__pycache__"
  ".cache" ".config" ".dotnet" ".gemini" ".local" ".npm" ".nvm" ".pytest_cache" ".ssh" ".vscode-server"
  "backups" "code-stacks" "CODEX-LOGS" "data" "generic_texts" "google-cloud-sdk"
  "inputs" "logs" "outputs" "node_modules" "build" "dist" ".mypy_cache" ".ruff_cache"
  "old" "archive" "bk" "google-cloud-sdk"
)
# Also exclude ANY hidden dot-dir by default
GLOBAL_DOTDIR_EXCLUDE=true

# ---------- File name pattern excludes (backup/temp files) ----------
FILENAME_EXCLUDES=( "*-bk.*" "*_bk.*" "*-backup.*" "*.bak" "*~" "*.log" )

# ---------- Outputs ----------
OUT1="code-stacks/full-code-stack/code-stack-${now}.md"
OUT2="code-stacks/root-files-code-stack/root-files-code-stack-${now}.md"
mkdir -p "$(dirname "$OUT1")" "$(dirname "$OUT2")"

print_header() { printf "\n\n---\n## %s\n---\n" "$1"; }

# Build arrays for find
build_name_group() {
  local -a arr=( "(" ); local first=1
  for ext in "${EXTLIST[@]}"; do
    if (( first )); then arr+=( -name "$ext" ); first=0; else arr+=( -o -name "$ext" ); fi
  done
  arr+=( ")" ); printf '%s\0' "${arr[@]}"
}
build_path_excludes() {
  local -a arr=()
  for nm in "${EXCLUDE_PATH_NAMES[@]}"; do
    arr+=( ! -path "*/${nm}/*" )
  done
  if [[ "${GLOBAL_DOTDIR_EXCLUDE}" == "true" ]]; then
    arr+=( ! -path "*/.*/*" )
  fi
  printf '%s\0' "${arr[@]}"
}
build_filename_excludes() {
  local -a arr=()
  for pat in "${FILENAME_EXCLUDES[@]}"; do
    arr+=( ! -name "$pat" )
  done
  printf '%s\0' "${arr[@]}"
}
deserialize_nul_to_array() {
  local -n _out="$1"; _out=(); local IFS=
  while IFS= read -r -d '' tok; do _out+=( "$tok" ); done
}

deserialize_nul_to_array NAME_GROUP     < <(build_name_group)
deserialize_nul_to_array PATH_EXCLUDES  < <(build_path_excludes)
deserialize_nul_to_array FILE_EXCLUDES  < <(build_filename_excludes)

# ---------- Collect ----------
total_files=0
declare -a collected=()

for d in "${INCLUDED_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  mapfile -t files < <(find "$d" -type f "${NAME_GROUP[@]}" "${FILE_EXCLUDES[@]}" "${PATH_EXCLUDES[@]}" -print | sort)
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    collected+=( "$file" )
    ((total_files++)) || true
  done
done

# ---------- Root files ----------
root_count=0
declare -a root_collected=()
for f in "${ROOT_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    root_collected+=( "$f" )
    ((root_count++)) || true
  fi
done

# ---------- Output or list ----------
if [[ "${LIST_ONLY,,}" == "true" ]]; then
  printf "Would include (%d files):\n" "$total_files"
  printf "  %s\n" "${collected[@]}"
  printf "\nRoot files (%d):\n" "$root_count"
  printf "  %s\n" "${root_collected[@]}"
  exit 0
fi

echo "# FULL CODE STACK (${now})" > "$OUT1"
for f in "${collected[@]}"; do print_header "$f" >> "$OUT1"; cat "$f" >> "$OUT1"; done

echo "# ROOT FILES CODE STACK (${now})" > "$OUT2"
for f in "${root_collected[@]}"; do print_header "$f" >> "$OUT2"; cat "$f" >> "$OUT2"; done

if [[ $total_files -eq 0 && $root_count -eq 0 ]]; then
  echo "❌ No files collected. Check include/exclude rules." >&2
  exit 2
fi

echo "✅ Code stacks generated:"
echo "   $OUT1   (files: $total_files)"
echo "   $OUT2   (root files: $root_count)"
