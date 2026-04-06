#!/usr/bin/env bash
# Self-refreshing TUI dashboard for todo-tasks.
# Usage: bash monitor.sh           — refresh loop (ctrl-c to exit)
#        bash monitor.sh --once    — single frame, then exit
set -euo pipefail

TODO="$(git rev-parse --show-toplevel)/.todo-tasks"
shopt -s nullglob

# ── Color setup ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$(tput bold 2>/dev/null || true)
  DIM=$(tput dim 2>/dev/null || true)
  GREEN=$(tput setaf 2 2>/dev/null || true)
  YELLOW=$(tput setaf 3 2>/dev/null || true)
  RED=$(tput setaf 1 2>/dev/null || true)
  CYAN=$(tput setaf 6 2>/dev/null || true)
  RESET=$(tput sgr0 2>/dev/null || true)
else
  BOLD="" DIM="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
mtime() {
  stat -c %Y "$1" 2>/dev/null || date +%s
}

elapsed() {
  local file="$1" age
  local now; now=$(date +%s)
  age=$(( now - $(mtime "$file") ))
  if (( age < 3600 )); then echo "$((age/60))m"
  elif (( age < 86400 )); then echo "$((age/3600))h$((age%3600/60))m"
  else echo "$((age/86400))d$((age%86400/3600))h"; fi
}

# Pad/truncate a string to exactly N chars
pad() {
  local s="$1" n="$2"
  printf "%-${n}s" "${s:0:$n}"
}

# Right-align a string in N chars
rpad() {
  local s="$1" n="$2"
  printf "%${n}s" "$s"
}

# ── Frame renderer ────────────────────────────────────────────────────────────
render_frame() {
  local now; now=$(date +%s)
  local T=$'\t'

  # Terminal width (default 80 if not a tty)
  local cols=80
  if [[ -t 1 ]]; then cols=$(tput cols 2>/dev/null || echo 80); fi
  # Inner width = cols - 2 (for box sides)
  local inner=$(( cols - 2 ))
  (( inner < 20 )) && inner=20

  # ── Collect active (running) entries ─────────────────────────────────────
  local -a active_lines=()
  local chain_slugs=" "

  for m in "$TODO"/.running/chain-*.manifest; do
    [[ -r "$m" ]] || continue
    local chain status current completed phases total done_n e
    chain=$(sed -n 's/^chain: *//p' "$m" 2>/dev/null)
    status=$(sed -n 's/^status: *//p' "$m" 2>/dev/null)
    current=$(sed -n 's/^current: *//p' "$m" 2>/dev/null)
    completed=$(sed -n 's/^completed: *//p' "$m" 2>/dev/null)
    phases=$(sed -n 's/^phases: *//p' "$m" 2>/dev/null)
    total=$(echo "$phases" | tr ',' '\n' | grep -c . || echo 0)
    done_n=0
    [[ -n "$completed" ]] && done_n=$(echo "$completed" | tr ',' '\n' | grep -c . || echo 0)
    e=$(elapsed "$m")
    # Accumulate chain slugs so solo runner won't re-show them
    chain_slugs+="$(echo "$phases" | tr ',' ' ') "
    case "$status" in
      done|complete) ;;  # handled in recent section
      failed)
        active_lines+=("chain-fail${T}${chain} [${done_n}/${total}] ${current}${T}${e}")
        ;;
      *)
        active_lines+=("chain${T}${chain} [$((done_n+1))/${total}] ${current}${T}${e}")
        ;;
    esac
  done

  for md in "$TODO"/.running/*.md; do
    [[ -r "$md" ]] || continue
    local slug; slug=$(basename "$md" .md)
    # Skip if claimed by a chain
    local claimed=false
    for _m in "$TODO"/.running/chain-*.manifest; do
      grep -ql "$slug" "$_m" 2>/dev/null && claimed=true && break
    done
    $claimed && continue
    active_lines+=("running${T}${slug}${T}$(elapsed "$md")")
  done

  # ── Collect recent completions ────────────────────────────────────────────
  local -a recent_lines=()
  local recent_raw
  recent_raw=$(
    {
      for r in "$TODO"/.done/*.result.md "$TODO"/.archived/*.result.md; do
        [[ -r "$r" ]] || continue
        local rs; rs=$(basename "$r" .result.md)
        [[ "$chain_slugs" == *" $rs "* ]] && continue
        local st; st=$(sed -n 's/^[*]*[Ss]tatus[*]*: *//p' "$r" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
        printf '%d %s %s\n' "$(mtime "$r")" "$rs" "$st"
      done
      for m in "$TODO"/.running/chain-*.manifest; do
        [[ -r "$m" ]] || continue
        local cs; cs=$(sed -n 's/^status: *//p' "$m" 2>/dev/null)
        case "$cs" in done|complete) ;; *) continue ;; esac
        local cn; cn=$(sed -n 's/^chain: *//p' "$m" 2>/dev/null)
        local cp; cp=$(sed -n 's/^phases: *//p' "$m" 2>/dev/null)
        local ct; ct=$(echo "$cp" | tr ',' '\n' | grep -c . || echo 0)
        printf '%d %s %s\n' "$(mtime "$m")" "chain:${cn}(${ct}/${ct})" "success"
      done
    } | sort -rn | head -3
  )
  while IFS=' ' read -r _ts rslug rstatus; do
    [[ -z "$rslug" ]] && continue
    local rage=$(( now - _ts ))
    local ago
    if (( rage < 3600 )); then ago="$((rage/60))m ago"
    elif (( rage < 86400 )); then ago="$((rage/3600))h ago"
    else ago="$((rage/86400))d ago"; fi
    case "$rstatus" in
      *success*) recent_lines+=("done${T}${rslug}${T}${ago}") ;;
      *)         recent_lines+=("failed${T}${rslug}${T}${ago}") ;;
    esac
  done <<< "$recent_raw"

  # ── Collect pending tasks ─────────────────────────────────────────────────
  local -a pending_lines=()
  for tf in "$TODO"/*.md; do
    [[ -r "$tf" ]] || continue
    [[ "$tf" == *.epic.md ]] && continue
    local pslug; pslug=$(basename "$tf" .md)
    pending_lines+=("$pslug")
  done

  # ── Collect epics ─────────────────────────────────────────────────────────
  local -a epic_lines=()
  for ef in "$TODO"/*.epic.md; do
    [[ -r "$ef" ]] || continue
    local epic; epic=$(basename "$ef" .epic.md)
    declare -A seen_slugs=()
    for tf in "$TODO/${epic}"-[0-9]*.md "$TODO/.running/${epic}"-[0-9]*.md "$TODO/.done/${epic}"-[0-9]*.md; do
      [[ -f "$tf" ]] || continue
      [[ "$tf" == *.result.md ]] && continue
      seen_slugs[$(basename "$tf" .md)]=1
    done
    for tf in "$TODO/.archived/"*"-${epic}"-[0-9]*.md; do
      [[ -f "$tf" ]] || continue
      [[ "$tf" == *.result.md ]] && continue
      local esl; esl=$(basename "$tf" .md); esl="${esl#[0-9]*-}"
      seen_slugs["$esl"]=1
    done
    local etotal=0 edone=0 erunning=0 efailed=0
    for ets in "${!seen_slugs[@]}"; do
      ((etotal++))
      if [[ -f "$TODO/.done/${ets}.result.md" ]]; then
        local es; es=$(sed -n 's/^[*]*[Ss]tatus[*]*: *//p' "$TODO/.done/${ets}.result.md" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
        case "$es" in *success*) ((edone++)) ;; *) ((efailed++)) ;; esac
      elif ls "$TODO/.archived/"*"-${ets}.result.md" &>/dev/null 2>&1; then
        local erf; erf=$(ls "$TODO/.archived/"*"-${ets}.result.md" 2>/dev/null | head -1)
        local efs; efs=$(sed -n 's/^[*]*[Ss]tatus[*]*: *//p' "$erf" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
        case "$efs" in *success*) ((edone++)) ;; *) ((efailed++)) ;; esac
      elif [[ -f "$TODO/.running/${ets}.md" ]]; then
        ((erunning++))
      fi
    done
    unset seen_slugs
    (( etotal == 0 )) && continue
    local esummary="${edone}/${etotal} done"
    (( erunning > 0 )) && esummary+="  ${erunning} running"
    (( efailed > 0 )) && esummary+="  ${efailed} failed"
    epic_lines+=("${epic}${T}${esummary}")
  done

  # ── Counts for summary line ───────────────────────────────────────────────
  local n_running=${#active_lines[@]}
  local n_done=0 n_failed=0
  for rl in "${recent_lines[@]}"; do
    local rs_type; rs_type=$(echo "$rl" | cut -f1)
    case "$rs_type" in done) n_done=$((n_done + 1)) ;; failed) n_failed=$((n_failed + 1)) ;; esac
  done
  local n_pending=${#pending_lines[@]}

  # ── Box drawing ───────────────────────────────────────────────────────────
  local title=" todo-tasks "
  local hline; hline=$(printf '─%.0s' $(seq 1 $((inner - 2))))
  local top="┌─${title}${hline:${#title}}┐"
  # Trim/pad top to exact width
  local border_line; border_line=$(printf '─%.0s' $(seq 1 $((inner))))
  local bottom="└${border_line}┘"

  # Helper: print a box row with content, padded to inner width
  box_row() {
    local content="$1"
    # Strip ANSI to measure visible length
    local visible; visible=$(echo "$content" | sed 's/\x1b\[[0-9;]*m//g')
    local vlen=${#visible}
    local pad_n=$(( inner - vlen - 1 ))
    (( pad_n < 0 )) && pad_n=0
    printf '│ %s%*s│\n' "$content" "$pad_n" ""
  }

  box_empty() {
    printf '│%*s│\n' "$inner" ""
  }

  # Print top border (adjust width)
  local tlen=${#top}
  local target=$(( cols ))
  if (( tlen < target )); then
    # Extend the hline
    local extra_dashes; extra_dashes=$(printf '─%.0s' $(seq 1 $((target - tlen - 1))))
    top="${top%┐}${extra_dashes}┐"
  fi
  printf '%s\n' "$top"
  box_empty

  # Running entries
  if (( ${#active_lines[@]} > 0 )); then
    for entry in "${active_lines[@]}"; do
      local etype eslug eextra eelapsed
      etype=$(echo "$entry" | cut -f1)
      eslug=$(echo "$entry" | cut -f2)
      eelapsed=$(echo "$entry" | cut -f3)

      local icon color
      case "$etype" in
        chain)      icon="${YELLOW}●${RESET}"; color="$YELLOW" ;;
        chain-fail) icon="${RED}✗${RESET}";    color="$RED" ;;
        running)    icon="${YELLOW}●${RESET}"; color="$YELLOW" ;;
        *)          icon="?"; color="" ;;
      esac

      local label_raw="${eslug}"
      local status_word="${color}running${RESET}"
      local elapsed_str="$eelapsed"

      # Compute visible lengths for alignment
      local lv=${#label_raw}
      local sv=7  # "running" visible length
      local ev=${#elapsed_str}
      # Available space: inner - 2 (icon+space) - 2 (spaces around status) - ev - 2 (right margin) - 1 (space after icon)
      local label_max=$(( inner - 2 - sv - ev - 6 ))
      (( label_max < 8 )) && label_max=8
      local label_disp; label_disp=$(pad "$label_raw" "$label_max")

      box_row "${icon} ${BOLD}${label_disp}${RESET}  ${status_word}  ${elapsed_str}"
    done
    box_empty
  fi

  # Recent completions
  if (( ${#recent_lines[@]} > 0 )); then
    for entry in "${recent_lines[@]}"; do
      local rtype rslug2 rag
      rtype=$(echo "$entry" | cut -f1)
      rslug2=$(echo "$entry" | cut -f2)
      rag=$(echo "$entry" | cut -f3)

      local icon color status_word
      case "$rtype" in
        done)   icon="${GREEN}✓${RESET}"; color="$GREEN";  status_word="${color}success${RESET}" ;;
        failed) icon="${RED}✗${RESET}";  color="$RED";    status_word="${color}failed${RESET}" ;;
        *)      icon="?"; color=""; status_word="$rtype" ;;
      esac

      local sv_len=7  # "success" or "failed " visible length (pad to 7)
      local rag_len=${#rag}
      local label_max=$(( inner - 2 - sv_len - rag_len - 6 ))
      (( label_max < 8 )) && label_max=8
      local label_disp; label_disp=$(pad "$rslug2" "$label_max")

      box_row "${icon} ${DIM}${label_disp}${RESET}  ${status_word}  ${rag}"
    done
    box_empty
  fi

  # Pending tasks
  if (( ${#pending_lines[@]} > 0 )); then
    for pslug in "${pending_lines[@]}"; do
      local label_max=$(( inner - 4 ))
      local label_disp; label_disp=$(pad "$pslug" "$label_max")
      box_row "${DIM}⏳ ${label_disp}${RESET}"
    done
    box_empty
  fi

  # Epics section
  if (( ${#epic_lines[@]} > 0 )); then
    local epic_header="${DIM}── epics ──${RESET}"
    box_row "$epic_header"
    for eline in "${epic_lines[@]}"; do
      local ename; ename=$(echo "$eline" | cut -f1)
      local esumm; esumm=$(echo "$eline" | cut -f2)
      local name_max=$(( inner / 2 - 2 ))
      local name_disp; name_disp=$(pad "$ename" "$name_max")
      box_row "  ${CYAN}${name_disp}${RESET}  ${esumm}"
    done
    box_empty
  fi

  # Summary line
  local summary="${n_running} running · ${n_done} done · ${n_failed} failed · ${n_pending} pending"
  box_row "${DIM}${summary}${RESET}"
  box_empty

  printf '%s\n' "$bottom"
}

# ── Main ──────────────────────────────────────────────────────────────────────
ONCE=false
for arg in "$@"; do
  [[ "$arg" == "--once" ]] && ONCE=true
done

# Non-interactive stdout → single shot
[[ ! -t 1 ]] && ONCE=true

if $ONCE; then
  render_frame
  exit 0
fi

# Loop mode: hide cursor, trap exit for cleanup
tput civis 2>/dev/null || true
cleanup() {
  tput cnorm 2>/dev/null || true
  tput clear 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

while true; do
  tput clear 2>/dev/null || printf '\033[H\033[2J'
  render_frame
  printf '\n  %srefreshing every 5s · ctrl-c to exit%s\n' "$DIM" "$RESET"
  sleep 5
done
