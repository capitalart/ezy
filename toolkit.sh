#!/bin/bash
# ============================================================================
# 🛠️ EzyGallery | Unified Project Toolkit – v3.4
# - Uses ./stacks/ (NOT code-stacks)
# - Saves code stack + last-hour logs snapshot into ./stacks/
# - Service name = ezy.service
# - Adds Node.js & npm Health Check
# ============================================================================

set -euo pipefail

# ============================================================================
# 1) CONFIG & PATHS
# ============================================================================
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/backups"                     # keep backups OUTSIDE repo
LOG_DIR="$ROOT_DIR/logs"
STACKS_DIR="$ROOT_DIR/stacks"             # renamed from code-stacks
VENV_DIR="$ROOT_DIR/venv"

GUNICORN_SERVICE="ezy.service"
NGINX_SERVICE="nginx.service"

REMOTE_NAME="gdrive"
RCLONE_FOLDER="EzyGallery-Backups"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Colors (TTY only)
if [[ -t 1 ]]; then
  C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

mkdir -p "$LOG_DIR" "$STACKS_DIR"
# Ensure backup dir exists and is writable by current user
if [[ ! -d "$BACKUP_DIR" ]]; then
  if sudo mkdir -p "$BACKUP_DIR"; then
    sudo chown "$(id -u)":"$(id -g)" "$BACKUP_DIR" || true
  fi
fi

# ============================================================================
# 2) LOGGING & UTILS
# ============================================================================
log_action() {
  local message="$1"
  local lf="$LOG_DIR/toolkit-actions-$(date +%Y-%m-%d).log"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" >> "$lf"
}

print_success() { echo -e "${C_GREEN}✅ $1${C_RESET}"; }
print_error()   { echo -e "${C_RED}❌ $1${C_RESET}"; }
print_warning() { echo -e "${C_YELLOW}⚠️ $1${C_RESET}"; }
print_info()    { echo -e "${C_CYAN}ℹ️ $1${C_RESET}"; }

check_venv() {
  if [[ -z "${VIRTUAL_ENV-}" ]]; then
    print_error "Virtual environment is not activated."
    print_warning "Run: source venv/bin/activate"
    return 1
  fi
}

# ============================================================================
# 3) SERVICES
# ============================================================================
restart_service() {
  local service_name="$1"
  print_info "Restarting ${service_name}..."
  if sudo systemctl restart "$service_name"; then
    print_success "${service_name} restarted."
    log_action "Service restarted: ${service_name}"
  else
    print_error "Failed to restart ${service_name}"
    print_info  "Check: journalctl -u ${service_name} --no-pager"
    log_action "Service restart FAILED: ${service_name}"
  fi
}

reboot_server() {
  print_warning "This will reboot the entire server."
  read -p "Are you sure? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    log_action "🚨 REBOOT triggered from toolkit"
    sudo reboot
  else
    print_info "Reboot cancelled."
  fi
}

# ============================================================================
# 4) GIT
# ============================================================================
git_pull_and_restart() {
  print_info "Git pull (auto-stash if needed)..."
  if [[ -n "$(git status --porcelain)" ]]; then
    git stash push -m "Auto stash by toolkit before pull on $(date)"
    log_action "Local changes stashed before pull"
  fi
  if git pull; then
    log_action "Git pull OK"
    print_success "Pulled latest. Running QA..."
    if run_tests; then
      print_success "QA passed. Restarting app..."
      restart_service "$GUNICORN_SERVICE"
    else
      print_error "QA failed. App NOT restarted."
      log_action "PULL FAILED QA"
    fi
  else
    print_error "Git pull failed."
    log_action "Git pull FAILED"
  fi
}

git_push_safe() {
  print_info "Running QA before push..."
  if ! run_tests; then
    print_error "QA failed. Push aborted."
    log_action "Push aborted (QA failed)"
    return 1
  fi
  git add .
  git commit -m "🔄 Auto-commit via toolkit on $(date)" || print_info "Nothing to commit."
  if git push; then
    print_success "Pushed to remote."
    log_action "Git push OK"
  else
    print_error "Git push failed."
    log_action "Git push FAILED"
  fi
}

# ============================================================================
# 5) BACKUP / RESTORE
# ============================================================================
EXCLUDES=(
  --exclude=.git
  --exclude=.vscode-server
  --exclude=.venv
  --exclude=venv
  --exclude=.cache
  --exclude=__pycache__
  --exclude=*.log
  --exclude=*.tmp
  --exclude=*.pyc
  --exclude=node_modules
  --exclude=.DS_Store
  --exclude=stacks
)

backup_dry_run() {
  print_info "Dry-run: listing what WOULD be backed up (no file created)..."
  local dry_log="$LOG_DIR/backup-dryrun-$TIMESTAMP.log"
  if tar -cvf /dev/null "${EXCLUDES[@]}" -C "$ROOT_DIR" . | tee "$dry_log"; then
    print_success "Dry-run complete. Log: $dry_log"
    log_action "Backup dry-run saved: $(basename "$dry_log")"
  else
    print_error "Dry-run failed."
  fi
}

run_full_backup() {
  local archive_name="ezygallery-backup-${TIMESTAMP}.tar.gz"
  local archive_path="${BACKUP_DIR}/${archive_name}"

  print_info "Creating backup at: ${archive_path}"
  if tar -czvf "$archive_path" "${EXCLUDES[@]}" -C "$ROOT_DIR" . > "$BACKUP_DIR/backup-$TIMESTAMP.log" 2>&1; then
    print_success "Local backup created: ${archive_path}"
    log_action "Backup created: ${archive_name}"
  else
    print_error "Backup failed. Check log: $BACKUP_DIR/backup-$TIMESTAMP.log"
    return 1
  fi

  # Keep only last 7 backups
  ls -tp "$BACKUP_DIR"/ezygallery-backup-*.tar.gz 2>/dev/null | grep -v '/$' | tail -n +8 | xargs -r rm -- || true
}

upload_to_gdrive() {
  local archive_path="$1"
  if [[ ! -f "$archive_path" ]]; then
    print_error "Archive not found: $archive_path"
    return 1
  fi
  print_info "Uploading to Google Drive ($REMOTE_NAME:$RCLONE_FOLDER)..."
  if rclone copy --progress "$archive_path" "$REMOTE_NAME:$RCLONE_FOLDER"; then
    print_success "Uploaded: $(basename "$archive_path")"
    log_action "GDrive upload OK: $(basename "$archive_path")"
  else
    print_error "GDrive upload failed."
    log_action "GDrive upload FAILED: $(basename "$archive_path")"
    return 1
  fi
}

restore_from_backup() {
  print_info "Searching local backups..."
  mapfile -t backups < <(ls -1t "$BACKUP_DIR"/ezygallery-backup-*.tar.gz 2>/dev/null || true)
  if [ ${#backups[@]} -eq 0 ]; then
    print_warning "No local backups found in $BACKUP_DIR"
    return 1
  fi
  echo "Available backups:"
  select archive_path in "${backups[@]}"; do
    [[ -n "${archive_path:-}" ]] && break
    print_error "Invalid selection."
  done

  print_warning "This will overwrite files under $ROOT_DIR."
  read -p "Proceed with restore from '$(basename "$archive_path")'? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { print_info "Restore cancelled."; return; }

  print_info "Restoring..."
  tar -xzf "$archive_path" -C "$ROOT_DIR"
  print_success "Restore complete."
  log_action "Restore from $(basename "$archive_path")"
  print_warning "Re-check your .env, dependencies, and restart services."
}

# ============================================================================
# 6) QA & MAINTENANCE
# ============================================================================
run_tests() {
  check_venv || return 1
  print_info "Running QA..."
  local status=0

  if command -v ruff >/dev/null 2>&1; then
    print_info "Ruff..."
    ruff check . || status=1
  fi

  if command -v pip-audit >/dev/null 2>&1; then
    print_info "pip-audit..."
    pip-audit || status=1
  fi

  if command -v pytest >/dev/null 2>&1; then
    print_info "pytest..."
    PYTHONPATH="$ROOT_DIR" pytest --maxfail=3 --disable-warnings | tee "$LOG_DIR/test-output-$TIMESTAMP.log" || status=1
    log_action "Tests complete: test-output-$TIMESTAMP.log"
  fi

  if [[ $status -ne 0 ]]; then
    print_error "QA FAILED."
    log_action "QA FAILED"
    return 1
  fi
  print_success "QA PASSED."
  log_action "QA PASSED"
}

update_dependencies() {
  check_venv || return 1
  print_info "Updating dependencies from requirements.txt..."
  if pip install --upgrade -r requirements.txt; then
    pip freeze > requirements.txt
    print_success "Dependencies updated."
    log_action "Dependencies updated"
    print_warning "Restart app to apply changes."
  else
    print_error "Dependency update failed."
  fi
}

cleanup_disk() {
  print_info "Cleaning logs/backups older than 30 days..."
  find "$LOG_DIR" -type f -mtime +30 -print -delete | (grep -q . && print_success "Old logs removed." || print_info "No old logs.")
  find "$BACKUP_DIR" -type f -mtime +30 -print -delete | (grep -q . && print_success "Old backups removed." || print_info "No old backups.")
  log_action "Disk cleanup run"
}

# ============================================================================
# 7) DEV TOOLS (Stacks: code + last-hour logs)
# ============================================================================
generate_logs_snapshot() {
  local now_human
  now_human=$(date "+%a-%d-%B-%Y-%I-%M-%p" | tr '[:lower:]' '[:upper:]')
  local snap_file="$STACKS_DIR/logs-snapshot-${now_human}.md"

  print_info "Capturing last-hour logs → $snap_file"
  {
    echo "# LOGS SNAPSHOT (Last 60 minutes) – $now_human"
    echo
    echo "## journalctl ($GUNICORN_SERVICE, last 60m)"
    echo '```'
    sudo journalctl -u "$GUNICORN_SERVICE" --since "60 min ago" --no-pager || true
    echo '```'
    echo
    echo "## journalctl ($NGINX_SERVICE, last 60m)"
    echo '```'
    sudo journalctl -u "$NGINX_SERVICE" --since "60 min ago" --no-pager || true
    echo '```'
    echo
    echo "## repo logs/ changed in last 60m"
    echo '```'
    find "$LOG_DIR" -type f -mmin -60 -print 2>/dev/null | sed "s|^| - |" || true
    echo
    for f in $(find "$LOG_DIR" -type f -mmin -60 2>/dev/null); do
      echo "---- tail: $f ----"
      tail -n 200 "$f" || true
      echo
    done
    echo '```'
  } > "$snap_file"

  print_success "Logs snapshot saved: $snap_file"
  log_action "Logs snapshot saved: $(basename "$snap_file")"
}

run_code_stacker() {
  print_info "Running Code Stacker..."

  local now
  now=$(date "+%a-%d-%B-%Y-%I-%M-%p" | tr '[:lower:]' '[:upper:]')

  mkdir -p "$STACKS_DIR"

  # choose content
  local folders_to_stack="routes static templates utils"
  local files_to_stack="app.py config.py requirements.txt README.md toolkit.sh"

  # 1) Full code stack
  local full_stack_file="$STACKS_DIR/ezygallery-full-stack-${now}.md"
  echo "# EZYGALLERY | FULL CODE STACK ($now)" > "$full_stack_file"
  print_info "Generating full code stack → $full_stack_file"

  for f in $files_to_stack; do
    if [[ -f "$ROOT_DIR/$f" ]]; then
      echo -e "\n\n---\n## $f\n---" >> "$full_stack_file"
      cat "$ROOT_DIR/$f" >> "$full_stack_file"
    fi
  done

  for d in $folders_to_stack; do
    if [[ -d "$ROOT_DIR/$d" ]]; then
      find "$ROOT_DIR/$d" -type f \( -name '*.py' -o -name '*.js' -o -name '*.css' -o -name '*.html' -o -name '*.md' \) | sort | while read -r file; do
        local rel="${file#$ROOT_DIR/}"
        echo -e "\n\n---\n## $rel\n---" >> "$full_stack_file"
        cat "$file" >> "$full_stack_file"
      done
    fi
  done

  print_success "Code stack generated: $full_stack_file"
  log_action "Code Stacker run → $(basename "$full_stack_file")"

  # 2) Folder tree snapshot if tool exists
  if [[ -f "$ROOT_DIR/generate_folder_tree.py" ]]; then
    print_info "Generating folder tree…"
    python3 "$ROOT_DIR/generate_folder_tree.py" || true
    if [[ -f "$ROOT_DIR/folder_structure.txt" ]]; then
      mv -f "$ROOT_DIR/folder_structure.txt" "$STACKS_DIR/folder-structure-${now}.txt"
      print_success "Folder tree saved: $STACKS_DIR/folder-structure-${now}.txt"
    fi
  fi

  # 3) Always capture last-hour logs into stacks
  generate_logs_snapshot
}

# ============================================================================
# 8) MENUS
# ============================================================================
backup_menu() {
  while true; do
    echo -e "\n${C_BLUE}--- 📦 Backup & Restore Menu ---${C_RESET}"
    echo "[1] Dry-Run: show what WOULD be backed up"
    echo "[2] Run Full Local Backup"
    echo "[3] Run Backup + Upload to Google Drive"
    echo "[4] Restore From Local Backup"
    echo "[0] Back to Main Menu"
    read -p "Choose an option: " opt
    case "$opt" in
      1) backup_dry_run ;;
      2) run_full_backup ;;
      3) run_full_backup && latest=$(ls -1t "$BACKUP_DIR"/ezygallery-backup-*.tar.gz | head -n1) && upload_to_gdrive "$latest" ;;
      4) restore_from_backup ;;
      0) break ;;
      *) print_error "Invalid option." ;;
    esac
  done
}

restart_menu() {
  while true; do
    echo -e "\n${C_RED}--- ⚡️ System Restart Menu ---${C_RESET}"
    print_warning "Use with care."
    echo "[1] Restart Application (Gunicorn)"
    echo "[2] Restart Web Server (NGINX)"
    echo "[3] REBOOT ENTIRE SERVER"
    echo "[0] Back to Main Menu"
    read -p "Choose an option: " opt
    case "$opt" in
      1) restart_service "$GUNICORN_SERVICE" ;;
      2) restart_service "$NGINX_SERVICE" ;;
      3) reboot_server ;;
      0) break ;;
      *) print_error "Invalid option." ;;
    esac
  done
}

# ============================================================================
# 9) EXTRA TOOLS
# ============================================================================
system_health_check() {
  print_info "Generating system health report..."
  local report_file="$LOG_DIR/health-check-$TIMESTAMP.md"
  {
    echo "# System Health Report - $(date)"
    echo -e "\n## Disk Usage"
    df -h
    echo -e "\n## Memory Usage"
    free -h
    echo -e "\n## .env Presence"
    [[ -f "$ROOT_DIR/.env" ]] && echo "✅ .env present" || echo "❌ .env MISSING"
    echo -e "\n## Top Memory Processes"
    ps aux --sort=-%mem | head -n 6
    echo -e "\n## Top CPU Processes"
    ps aux --sort=-%cpu | head -n 6
    echo -e "\n## Gunicorn Status"
    systemctl status --no-pager "$GUNICORN_SERVICE" || true
  } > "$report_file"
  print_success "Health report: $report_file"
  log_action "Health report saved: $(basename "$report_file")"
}

view_live_log() {
  print_info "Tailing Gunicorn service log via journalctl..."
  journalctl -u "$GUNICORN_SERVICE" -f
}

node_health_check() {
  print_info "Node.js & npm Health Check"
  {
    echo "# Node.js & npm Health – $(date)"
    echo
    echo "## Versions"
    echo -n "node: "; (command -v node >/dev/null && node -v) || echo "not installed"
    echo -n "npm : ";  (command -v npm  >/dev/null && npm -v)  || echo "not installed"
    echo -n "yarn: ";  (command -v yarn >/dev/null && yarn -v) || echo "not installed"
    echo
    echo "## Paths"
    echo -n "which node: "; which node || true
    echo -n "which npm : "; which npm  || true
    echo -n "which yarn: "; which yarn || true
    echo
    if command -v nvm >/dev/null 2>&1; then
      echo "## nvm list"
      nvm ls || true
    else
      echo "## nvm"
      echo "nvm not on PATH in this shell. If installed, 'source ~/.nvm/nvm.sh' first."
    fi
    echo
    if command -v npm >/dev/null 2>&1; then
      echo "## Global npm packages (depth=0)"
      npm list -g --depth=0 || true
    fi
  } | tee "$STACKS_DIR/node-health-$TIMESTAMP.md"
  print_success "Node health saved → $STACKS_DIR/node-health-$TIMESTAMP.md"
}

# ============================================================================
# 10) MAIN MENU
# ============================================================================
main_menu() {
  while true; do
    echo -e "\n${C_CYAN}🌟 Project Toolkit – EzyGallery 🌟${C_RESET}"
    echo -e "${C_YELLOW}--- Git & Deployment ---${C_RESET}"
    echo " [1] Git PULL & Deploy"
    echo " [2] Run QA, Commit & PUSH"
    echo -e "${C_YELLOW}--- System Management ---${C_RESET}"
    echo " [3] Backup & Restore"
    echo " [4] System Restart Options"
    echo " [5] System Health Check"
    echo -e "${C_YELLOW}--- QA & Maintenance ---${C_RESET}"
    echo " [6] Run Full QA Suite"
    echo " [7] Update Python Dependencies"
    echo " [8] Cleanup Old Logs & Backups"
    echo -e "${C_YELLOW}--- Developer Tools ---${C_RESET}"
    echo " [9] View Live Application Log"
    echo "[10] Generate Stacks (code + last-hour logs)"
    echo "[11] Node.js & npm Health Check"
    echo " [0] Exit"
    read -p "Choose an option: " opt
    case "$opt" in
      1) git_pull_and_restart ;;
      2) git_push_safe ;;
      3) backup_menu ;;
      4) restart_menu ;;
      5) system_health_check ;;
      6) run_tests ;;
      7) update_dependencies ;;
      8) cleanup_disk ;;
      9) view_live_log ;;
      10) run_code_stacker ;;
      11) node_health_check ;;
      0) echo "👋 Bye legend!"; exit 0 ;;
      *) print_error "Invalid option." ;;
    esac
  done
}

# ============================================================================
# 11) ENTRYPOINT
# ============================================================================
if [[ $# -gt 0 ]]; then
  case "$1" in
    --backup) run_full_backup ;;
    --backup-upload) run_full_backup && latest=$(ls -1t "$BACKUP_DIR"/ezygallery-backup-*.tar.gz | head -n1) && upload_to_gdrive "$latest" ;;
    --test) run_tests ;;
    --pull) git_pull_and_restart ;;
    --push) git_push_safe ;;
    --stack) run_code_stacker ;;
    --stack-logs) generate_logs_snapshot ;;
    --node-health) node_health_check ;;
    --backup-dryrun) backup_dry_run ;;
    *) print_error "Invalid arg '$1'. Run without args for menu." ;;
  esac
else
  main_menu
fi
