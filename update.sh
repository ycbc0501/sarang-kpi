#!/bin/zsh
# 사랑 찾는 KPI — reads Claire's public follower count once and publishes it to GitHub Pages.
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$HOME/Documents/no2/sarang-kpi"
LOG="$DIR/update.log"
HANDLE="clairelee_sunshine"
cd "$DIR" || exit 1
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

fetch_meta() {
  curl -s -m 30 -L -A "$1" "https://www.instagram.com/$HANDLE/" \
    | grep -o '<meta property="og:description" content="[^"]*"' | head -1
}

META="$(fetch_meta 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)')"
if [[ -z "$META" ]]; then
  sleep 60
  META="$(fetch_meta 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)')"
fi
if [[ -z "$META" ]]; then
  log "FAIL no og:description from instagram"
  exit 2
fi

COUNT="$(print -r -- "$META" | python3 -c '
import re, sys
m = re.search(r"content=\"([\d.,]+[KkMm]?) Followers", sys.stdin.read())
if not m: sys.exit(1)
v = m.group(1).replace(",", "")
mult = {"k": 1000, "m": 1000000}.get(v[-1].lower(), 1)
if mult != 1: v = v[:-1]
print(int(round(float(v) * mult)))
')" || { log "FAIL could not parse: $META"; exit 3; }

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
else:
    entries.append({"date": date, "count": count, "note": "", "source": "auto"})
entries.sort(key=lambda e: e["date"])
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(p, "a", encoding="utf-8").write("\n")
PY

if git diff --quiet -- data.json; then
  log "OK $TODAY count=$COUNT (unchanged, nothing to push)"
  exit 0
fi
git add data.json
git commit -q -m "record $TODAY: $COUNT followers" || { log "FAIL commit"; exit 4; }
if git push -q origin main; then
  log "OK $TODAY count=$COUNT pushed"
else
  log "FAIL push (will retry next run)"
  exit 5
fi
