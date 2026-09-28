#!/bin/zsh
# Runs update.sh once now and then at the top of every hour, forever.
# launchd StartInterval timers do not fire on 집컴 while the lid is closed (the GUI session is
# inactive, launchd leaves the spawn "pended"), so the schedule lives in this KeepAlive loop instead.
DIR="$HOME/sarang-kpi"
cd "$DIR" || exit 1
while true; do
  /bin/zsh "$DIR/update.sh"
  sleep $(( 3600 - $(date +%s) % 3600 + 5 ))
done
