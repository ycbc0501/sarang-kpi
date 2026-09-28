#!/bin/zsh
# 사랑 찾는 KPI — reads Claire's public follower count once and publishes it to GitHub Pages.
# Runs hourly from loop.sh (launchd KeepAlive agent com.sarang-kpi.update). Log: update.log. Exit codes: 0 ok, 2 no count,
# 3 another run in progress, 4 commit failed, 5 push failed, 6 Chrome missing.
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$HOME/sarang-kpi"
LOG="$DIR/update.log"
HANDLE="clairelee_sunshine"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="$DIR/chrome-profile"
DOM="$DIR/.last-dom.html"
RUNLOCK="$DIR/.run.lock"          # directory; mkdir is atomic
FAILS="$DIR/.fail-count"          # consecutive failures
NOTIFIED="$DIR/.notified-at"      # epoch of the last failure notification
NOTIFY_AFTER=3                    # notify after this many consecutive failures (= hours)
NOTIFY_EVERY=$((24*3600))         # and at most once per day after that

cd "$DIR" || exit 1
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
# Telegram DM to the user's phone (집컴 is headless, nobody sees its screen); falls back to a macOS banner.
notify() {
  if [[ -x "$DIR/notify.sh" ]] && "$DIR/notify.sh" "$1" "$2"; then log "NOTIFY telegram: $1"; return; fi
  osascript -e "display notification \"$2\" with title \"사랑 찾는 KPI\" subtitle \"$1\"" >/dev/null 2>&1 || true
  log "NOTIFY telegram failed, macOS banner only: $1"
}

# ---- single-run lock: two runs sharing the Chrome profile would kill each other ----
if ! mkdir "$RUNLOCK" 2>/dev/null; then
  # a run older than 15 minutes is a crashed one; take the lock over
  if [[ -n "$(find "$RUNLOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]]; then
    rmdir "$RUNLOCK" 2>/dev/null; mkdir "$RUNLOCK" 2>/dev/null || { log "SKIP could not take run lock"; exit 3; }
    log "WARN stale run lock taken over"
  else
    log "SKIP another run is in progress"; exit 3
  fi
fi
trap 'rmdir "$RUNLOCK" 2>/dev/null' EXIT

# ---- failure bookkeeping: count consecutive failures, notify once they persist ----
fail() {
  local n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
  print -r -- "$n" > "$FAILS"
  log "FAIL $1 (consecutive: $n)"
  local last=$(cat "$NOTIFIED" 2>/dev/null || echo 0) now=$(date +%s)
  if (( n >= NOTIFY_AFTER && now - last >= NOTIFY_EVERY )); then
    notify "업데이트 ${n}회 연속 실패" "$1 — ~/sarang-kpi/update.log 확인"
    print -r -- "$now" > "$NOTIFIED"
    log "NOTIFIED user about persistent failure"
  fi
  exit "$2"
}
succeed_bookkeeping() {
  local n=$(cat "$FAILS" 2>/dev/null || echo 0)
  if (( n >= NOTIFY_AFTER )); then notify "복구됨" "${n}회 실패 후 다시 정상 기록 중"; log "RECOVERED after $n failures"; fi
  rm -f "$FAILS" "$NOTIFIED"
}

[[ -x "$CHROME" ]] || fail "Google Chrome not found at $CHROME" 6

# ---- Chrome profile hygiene ----
# A leftover Chrome holding this profile's SingletonLock makes every new launch hand off its URL
# and exit with an empty DOM (this silently broke updates 2026-09-13 ~ 2026-09-27). Clear it first.
release_profile() {
  pkill -f "user-data-dir=$PROFILE" 2>/dev/null && sleep 2
  pkill -9 -f "user-data-dir=$PROFILE" 2>/dev/null
  rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonCookie" "$PROFILE/SingletonSocket"
}

# Render the real page with headless Chrome. Instagram's link-preview meta tag lags behind by days,
# but the rendered page shows the live count as <span title="277">...</span> followers.
render_page() {
  rm -f "$DOM"
  release_profile
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" --timeout=40000 --virtual-time-budget=8000 \
    --dump-dom "https://www.instagram.com/$HANDLE/" > "$DOM" 2>/dev/null &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 75 )); do sleep 1; (( waited++ )); done
  kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  release_profile
}

parse_count() {
  python3 - "$DOM" <<'PY'
import re, sys
try:
    s = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except Exception:
    sys.exit(1)
m = re.search(r'title="([\d,.]+[KkMm]?)"\s*>\s*<span[^>]*>[^<]*</span>\s*</span>\s*followers', s)
if not m: sys.exit(1)
v = m.group(1).replace(",", "")
mult = {"k": 1000, "m": 1000000}.get(v[-1].lower(), 1)
if mult != 1: v = v[:-1]
print(int(round(float(v) * mult)))
PY
}

COUNT=""
if [[ -z "${SARANG_FORCE_FAIL:-}" ]]; then
  for attempt in 1 2; do
    render_page
    COUNT="$(parse_count)" && break
    COUNT=""; sleep 30
  done
fi

if [[ -z "$COUNT" ]]; then
  if [[ -n "${SARANG_FORCE_FAIL:-}" ]]; then fail "forced failure (test)" 2
  elif [[ ! -s "$DOM" ]]; then fail "headless Chrome produced an empty DOM (profile lock or Chrome launch problem)" 2
  else fail "could not parse follower count from rendered page ($(wc -c < "$DOM" | tr -d ' ') bytes; title: $(grep -o '<title>[^<]*' "$DOM" | head -1 | cut -c8-80))" 2
  fi
fi

TODAY="$(TZ=Asia/Seoul date +%F)"
python3 - "$TODAY" "$COUNT" <<'PY'
import json, sys
date, count = sys.argv[1], int(sys.argv[2])
p = "data.json"
d = json.load(open(p, encoding="utf-8"))
entries = d.setdefault("entries", [])
hit = next((e for e in entries if e.get("date") == date), None)
if hit:
    hit["count"] = count; hit["source"] = "auto"
    hit["peak"] = max(int(hit.get("peak", hit["count"])), count)
else:
    entries.append({"date": date, "count": count, "peak": count, "note": "", "source": "auto"})
entries.sort(key=lambda e: e["date"])
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(p, "a", encoding="utf-8").write("\n")
PY

if ! git diff --quiet -- data.json; then
  git add data.json
  git commit -q -m "record $TODAY: $COUNT followers" || fail "git commit" 4
fi

# Push whenever local is ahead, so a commit whose push failed earlier is not stranded until the count changes.
if [[ -n "$(git log origin/main..main --oneline 2>/dev/null)" ]]; then
  # pick up anything pushed from elsewhere (e.g. index.html edits) so the push is a fast-forward
  git pull -q --rebase origin main 2>/dev/null || { git rebase --abort 2>/dev/null; log "WARN rebase onto origin/main failed; pushing anyway"; }
  git push -q origin main || fail "git push (will retry next run)" 5
  log "OK $TODAY count=$COUNT pushed"
else
  log "OK $TODAY count=$COUNT (unchanged, nothing to push)"
fi
succeed_bookkeeping
exit 0
