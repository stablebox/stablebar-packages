#!/bin/sh
set -e

json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

read_json() {
  printf '%s' "$json" | plutil -extract "$1" raw -o - -
}

duration() {
  if [ "$1" -ge 86400 ]; then
    printf '%dd %dh' $(($1 / 86400)) $(($1 % 86400 / 3600))
  elif [ "$1" -ge 3600 ]; then
    printf '%dh %dm' $(($1 / 3600)) $(($1 % 3600 / 60))
  else
    printf '%dm' $(($1 / 60))
  fi
}

# Seconds since 1970 of an RFC 3339 time, such as 2026-11-27T09:35:35.700894+01:00 or 2026-11-27T08:35:35Z.
epoch() {
  zone=$(printf '%s' "$1" | sed -n 's/.*\([+-][0-9][0-9]\):\{0,1\}\([0-9][0-9]\)$/\1\2/p')
  date -j -f %Y-%m-%dT%H:%M:%S%z "$(printf '%s' "$1" | cut -c 1-19)${zone:-+0000}" +%s
}

weekly_pace() {
  elapsed=$((604800 - $2))
  [ "$elapsed" -gt 0 ] || elapsed=0
  delta=$(awk -v used="$1" -v elapsed="$elapsed" 'BEGIN { printf "%.0f", used - elapsed / 6048 }')
  if [ "$delta" -lt -2 ]; then
    printf '%d%% in reserve' $((-delta))
  elif [ "$delta" -gt 2 ]; then
    printf '%d%% in deficit' "$delta"
  else
    printf 'On pace'
  fi
  eta=$(awk -v used="$1" -v elapsed="$elapsed" 'BEGIN { if (used * 6048 > elapsed) printf "%d", (100 - used) * elapsed / used }')
  if [ -n "$eta" ]; then
    printf ' · Runs out in %s' "$(duration "$eta")"
  else
    printf ' · Lasts until reset'
  fi
}

# Sets $json to the usage response for the curl arguments, saving it in $saved. The request's headers
# come on standard input, one per line, so that a token never shows in the process list. When the request fails,
# it uses the response an earlier run saved, if any, and $note says why. $data_time is when it was fetched.
fetch() {
  wait_file="${saved%.json}-wait"
  if [ -f "$wait_file" ] && [ "$now" -lt "$(cat "$wait_file")" ]; then
    use_saved "$host is limiting requests; trying again at $(date -r "$(cat "$wait_file")" +%H:%M)"
    return
  fi
  # A setting change restarts the script at once. A response from the last minute is still current,
  # and asking again so soon is what makes Anthropic answer 429.
  if [ -f "$saved" ] && [ $((now - $(stat -f %m "$saved"))) -lt 60 ]; then
    json=$(cat "$saved")
    data_time=$(stat -f %m "$saved")
    note=""
    return
  fi
  # Every request shares the widget's 30-second timeout, so that the output arrives with what's saved:
  # each gets an equal share of the time left with the accounts still to come, up to 12 seconds.
  left=$((deadline - $(date +%s)))
  if [ "$left" -lt 2 ]; then
    use_saved "There was no time left to reach $host"
    return
  fi
  share=$((left / pending))
  [ "$share" -ge 2 ] || share=2
  [ "$share" -le 12 ] || share=12
  curl_status=0
  result=$(curl -sS --max-time "$share" -H @- -o "$saved.part" -w '%{http_code} %header{retry-after}' "$@") || curl_status=$?
  # A transfer cut short, such as by the deadline, can still report 200; keep the saved response then.
  [ "$curl_status" = 0 ] || result="000 "
  fetch_status=${result%% *}
  case $fetch_status in
    200)
      mv "$saved.part" "$saved"
      json=$(cat "$saved")
      data_time=$now
      note=""
      return
      ;;
    429)
      wait=${result#* }
      case $wait in '' | *[!0-9]*) wait=300 ;; esac
      # Anthropic has answered 429 with Retry-After: 0.
      [ "$wait" -ge 60 ] || wait=60
      echo $((now + wait)) > "$wait_file"
      reason="$host is limiting requests; trying again at $(date -r $((now + wait)) +%H:%M)"
      ;;
    401 | 403) reason="$app's sign-in has expired; open $app to renew it" ;;
    *) reason="Couldn't reach $host" ;;
  esac
  rm -f "$saved.part"
  use_saved "$reason"
}

# Uses the response an earlier run saved in $saved, with $1 saying why, or no response if there is none.
use_saved() {
  if [ -f "$saved" ]; then
    json=$(cat "$saved")
    data_time=$(stat -f %m "$saved")
    note="$1. Showing data from $(date -r "$data_time" +%H:%M)."
  else
    json=""
    note="$1."
  fi
}

now=$(date +%s)
deadline=$((now + 25))
# The next refresh, in seconds, from a choice such as "Every 5 minutes".
interval=$(($(printf '%s' "$REFRESH" | tr -cd '0-9') * 60))
updated=$now
failures=""
summary=""
# The tooltip: a line per provider, with the limits the bar shows.
tooltip=""
line=""
# A note in a provider's popup section that, unlike $note, doesn't dim it on the bar.
notice=""
expired_idle=false
# The output styles that place pace marks.
pace_styles=""
popup=""
rows=""
group=""
bar=""

counted=left
[ "$PERCENTAGES_SHOW" = "What's used" ] && counted=used
arrangement=stacked
[ "$LAYOUT" = "One line" ] && arrangement=oneLine
# Which of the stacked layout's columns show.
columns=""
[ "$METERS" = Hide ] || columns="$columns,\"meters\":\"1\""
[ "$PERCENTAGES" = Hide ] || columns="$columns,\"percents\":\"1\""
[ "$RESET_TIMES" = Hide ] || columns="$columns,\"resets\":\"1\""

# Whether the bar shows window $1, session or weekly, of the provider whose choice is in $limits.
in_bar() {
  case $1:$limits in
    session:Session | weekly:Week | session:"Session and week" | weekly:"Session and week") return 0 ;;
  esac
  return 1
}

# Adds window $2 (session, weekly, or another kind the bar doesn't show) titled $1, with $3 percent used,
# resetting at $4, if known. A fifth argument, "popup", keeps it off the bar.
add_window() {
  title=$(json_escape "$1")
  used=$(awk -v used="$3" 'BEGIN { printf "%.0f", used }')
  if [ "$counted" = used ]; then
    percent=$used
  else
    percent=$((100 - used))
  fi
  fraction=$(awk -v percent="$percent" 'BEGIN { printf "%.2f", percent / 100 }')
  reset=""
  countdown=""
  pace=""
  mark=""
  bar_mark=""
  # A reset that has passed belongs to a saved response; the next refresh brings the new window.
  if [ -n "$4" ] && [ "$4" -gt "$now" ]; then
    countdown=$(duration $(($4 - now)))
    reset="Resets in $countdown"
    # Pace is noise in the first 3% of the week. Weekly windows are taken to last 7 days, as Claude's,
    # Codex's and Antigravity's do.
    if [ "$2" = weekly ] && [ $((604800 - ($4 - now))) -ge 18144 ]; then
      pace=$(weekly_pace "$3" $(($4 - now)))
      # A mark on the meter where it would be on pace: popup meters are 262 points wide and the bar's
      # 20, each with its 2- or 1.5-point mark after it.
      pace_mark popup "$4" 262 2
      mark=$mark_style
      if [ "$5" != popup ] && in_bar "$2"; then
        pace_mark bar "$4" 20 1.5
        bar_mark=$mark_style
      fi
    fi
    # Refresh a minute after the reset, when that comes before the next refresh; a response saved before
    # the reset is then more than a minute old, so it's fetched again.
    [ $(($4 - now + 60)) -ge "$interval" ] || interval=$(($4 - now + 60))
  fi
  rows="$rows${rows:+,}{\"title\":\"$title\",\"fraction\":\"$fraction\",\"detail\":\"$percent% $counted\",\"trailing\":\"$reset\",\"pace\":\"$pace\",\"brand\":\"$brand\"${mark:+,\"paceMark\":\"1\",\"paceAt\":\"$mark\"}}"
  if [ "$5" != popup ] && in_bar "$2"; then
    summary="$summary${summary:+ · }$provider $2 $percent% $counted"
    line="$line${line:+ · }$2 $percent% $counted"
    label=W
    [ "$2" = session ] && label=5h
    group="$group\"${2}Label\":\"$label\","
    [ "$METERS" = Hide ] || group="$group\"${2}Meter\":\"$fraction\","
    [ "$PERCENTAGES" = Hide ] || group="$group\"${2}Percent\":\"$percent%\","
    # A window without a countdown, such as a session that hasn't started, keeps its line in the
    # stacked layout, so the week's countdown stays on the week's line.
    [ "$RESET_TIMES" = Hide ] || group="$group\"${2}Reset\":\"${countdown:-–}\","
    [ "$METERS" = Hide ] || [ -z "$bar_mark" ] || group="$group\"${2}PaceMark\":\"1\",\"${2}PaceAt\":\"$bar_mark\","
  fi
}

# Sets $mark_style to an output style that moves a pace mark, drawn after a meter $3 points wide and itself $4
# wide, back onto the meter where the week would be on pace, given its reset at $2. The meter fills
# with what's left or what's used, so the mark sits at the share that should be left or used by now.
pace_mark() {
  offset=$(awk -v reset="$2" -v now="$now" -v width="$3" -v mark="$4" -v counted="$counted" 'BEGIN {
    on = (604800 - (reset - now)) / 604800
    if (counted != "used") on = 1 - on
    printf "%d", (on * width - width - mark / 2) * 4 - 0.5
  }')
  mark_style="pace-$1$offset"
  case $pace_styles in *"\"$mark_style\""*) ;; *)
    pace_styles="$pace_styles,\"$mark_style\":{\"offsetX\":$(awk -v offset="$offset" 'BEGIN { print offset / 4 }')}" ;;
  esac
}

# The logo of provider $1, a one-color image drawn in the provider's color, as fields.
logo() {
  printf '"logo":"%s","brand":"%s"' "$(json_escape "$PACKAGE_DIR/icons/$1.png")" "$1"
}

# Adds a provider's section to the popup and, with data, its group to the bar: $1 is its logo, $2 its
# title, $3 its usage dashboard, if any, and $4 the account's name on the bar, if any. $brand, which
# colors the rows of its limits, is $1 too.
add_provider() {
  image=$(logo "$1")
  plan=$(json_escape "$(printf '%s' "$plan" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')")
  divider=""
  [ -z "$popup" ] || divider=",\"divider\":\"1\""
  popup="$popup${popup:+,}{$image,\"header\":\"$(json_escape "$2")\",\"plan\":\"$plan\"$divider}"
  [ -z "$note" ] || popup="$popup,{\"note\":\"$(json_escape "$note")\"}"
  [ -z "$notice" ] || popup="$popup,{\"note\":\"$(json_escape "$notice")\"}"
  popup="$popup${rows:+,}$rows"
  [ -z "$3" ] || popup="$popup,{\"dashboard\":\"$3\"}"
  if [ -n "$json" ]; then
    look=""
    [ -z "$note" ] || look=",\"look\":\"stale\""
    bar="$bar${bar:+,}{$group$image,\"name\":\"$(json_escape "$4")\",\"$arrangement\":\"1\"$columns$look}"
    [ "$data_time" -ge "$updated" ] || updated=$data_time
  else
    failures="$failures${failures:+ }$note"
  fi
  # A line from a saved response says when it was fetched.
  if [ -n "$line" ] && { [ -n "$note" ] || $expired_idle; }; then
    line="$line · as of $(date -r "$data_time" +%H:%M)"
  fi
  # A provider on the bar without any of the limits it shows, such as only a week with Session chosen,
  # says so.
  [ -z "$json" ] || [ -n "$line" ] || line="none of the limits the bar shows; click for the others"
  [ -z "$line" ] || tooltip="$tooltip${tooltip:+\\n}$provider: $line"
  line=""
  notice=""
  expired_idle=false
  rows=""
  group=""
  account_done
}

# Counts an account as done, whether it made a request or not, so that only the accounts still to come
# share the time left.
account_done() {
  [ "$pending" -le 1 ] || pending=$((pending - 1))
}

# Reads the usage of the Claude Code account whose Keychain sign-in is in $json.
claude_usage() {
  token=$(read_json claudeAiOauth.accessToken 2>/dev/null || true)
  plan=$(read_json claudeAiOauth.subscriptionType 2>/dev/null || true)
  expires=$(read_json claudeAiOauth.expiresAt 2>/dev/null || true)
  # An expiry that's missing or not a number is unknown: the request then tells whether it still works.
  case $expires in *[!0-9]*) expires="" ;; esac
  # A sign-in without a token, such as one the Keychain gave back damaged, is a note, not a failure.
  if [ -z "$token" ]; then
    json="" note="StableBar couldn't read Claude Code's sign-in from the Keychain."
  elif [ -n "$expires" ] && [ $((expires / 1000)) -le "$now" ]; then
    use_saved "Claude Code's sign-in has expired; open Claude Code to renew it"
  else
    fetch "https://api.anthropic.com/api/oauth/usage" <<END
Authorization: Bearer $token
anthropic-beta: oauth-2025-04-20
END
  fi
  [ -n "$json" ] || return 0
  total=$(read_json limits)
  # Claude reports no session until one starts, so a session that hasn't started is unused.
  i=0
  while [ "$i" -lt "$total" ] && [ "$(read_json "limits.$i.kind")" != session ]; do i=$((i + 1)); done
  [ "$i" -lt "$total" ] || add_window Session session 0 ""
  i=0
  while [ "$i" -lt "$total" ]; do
    used=$(read_json "limits.$i.percent")
    resets=$(read_json "limits.$i.resets_at" 2>/dev/null || true)
    if [ -n "$resets" ]; then
      resets=$(date -j -u -f %Y-%m-%dT%H:%M:%S "$(printf '%s' "$resets" | cut -c 1-19)" +%s)
    fi
    case $(read_json "limits.$i.kind") in
      session) add_window Session session "$used" "$resets" ;;
      weekly_all) add_window Weekly weekly "$used" "$resets" ;;
      weekly_scoped) add_window "$(read_json "limits.$i.scope.model.display_name") only" model "$used" "$resets" ;;
    esac
    i=$((i + 1))
  done

  if [ "$(read_json extra_usage.is_enabled 2>/dev/null || true)" = true ]; then
    spent=$(read_json extra_usage.used_credits 2>/dev/null || true)
    limit=$(read_json extra_usage.monthly_limit 2>/dev/null || true)
    # Without a cap above zero, there's no share of it to show.
    if [ -n "$spent" ] && awk -v limit="$limit" 'BEGIN { exit !(limit > 0) }'; then
      currency=$(json_escape "$(read_json extra_usage.currency)")
      fraction=$(awk -v spent="$spent" -v limit="$limit" -v usage="$counted" \
        'BEGIN { used = spent / limit; if (used > 1) used = 1; if (usage != "used") used = 1 - used; printf "%.2f", used }')
      detail=$(awk -v spent="$spent" -v limit="$limit" 'BEGIN { printf "%.2f / %.2f", spent / 100, limit / 100 }')
      rows="$rows,{\"title\":\"Extra usage\",\"fraction\":\"$fraction\",\"detail\":\"$detail $currency\",\"trailing\":\"This month\",\"brand\":\"$brand\"}"
    fi
  fi
}

# Claude Code keeps the sign-in of the folder CLAUDE_CONFIG_DIR names in "Claude Code-credentials-"
# followed by the first 8 hex digits of the SHA-256 of that path, exactly as written, and the sign-in of
# its default folder, used without CLAUDE_CONFIG_DIR, in "Claude Code-credentials".
hashed() {
  printf -- '-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c 1-8)"
}
main_suffix=""
[ -z "$CLAUDE_CONFIG_DIR" ] || main_suffix=$(hashed "$CLAUDE_CONFIG_DIR")

# More Claude Code accounts, as entries such as "Work=~/.claude-work": a name and the folder that
# CLAUDE_CONFIG_DIR names for that account, or the folder alone. The Claude setting covers them too.
extras=""
# One entry per line, without blank entries, so that counting and reading them agree.
[ "$CLAUDE" = Off ] || extras=$(printf '%s' "$CLAUDE_ACCOUNTS" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' || true)

# With more than one account on, the widget shows the ones signed in on this Mac. One on alone must be.
show_claude=true
show_codex=true
show_antigravity=true
[ "$CLAUDE" != Off ] || show_claude=false
[ "$CODEX" != Off ] || show_codex=false
[ "$ANTIGRAVITY" != Off ] || show_antigravity=false
on=0
for shown in $show_claude $show_codex $show_antigravity; do
  ! $shown || on=$((on + 1))
done
[ -z "$extras" ] || on=$((on + 1))
both=false
[ "$on" -le 1 ] || both=true

if $show_claude; then
  status=0
  credentials=$(security find-generic-password -s "Claude Code-credentials$main_suffix" -w 2>/dev/null) || status=$?
  # 44: the Keychain has no Claude Code sign-in.
  if [ "$status" = 44 ] && $both; then
    show_claude=false
  elif [ "$status" = 44 ]; then
    echo "Claude Code isn't signed in on this Mac. Sign in to Claude Code to see its limits." >&2
    exit 1
  elif [ "$status" != 0 ] && ! $both; then
    echo "StableBar couldn't read Claude Code's sign-in from the Keychain." >&2
    exit 1
  elif [ "$status" != 0 ]; then
    # With other providers on, a sign-in that can't be read is a note in Claude's section.
    credentials=""
  fi
fi

if $show_codex && [ ! -f "$HOME/.codex/auth.json" ]; then
  if ! $both; then
    echo "Codex isn't signed in on this Mac. Sign in to Codex to see its limits." >&2
    exit 1
  fi
  show_codex=false
fi

# Reads Antigravity's Google sign-in from the Keychain, decoding go-keyring-base64 if present.
read_antigravity_signin() {
  signin_status=0
  signin=$(security find-generic-password -s gemini -a antigravity -w 2>/dev/null) || signin_status=$?
  case $signin in
    go-keyring-base64:*) signin=$(printf '%s' "${signin#go-keyring-base64:}" | base64 -D 2>/dev/null) || signin="" ;;
  esac
}

# Finds an installed Antigravity CLI binary to renew an expired 1-hour OAuth access token.
find_antigravity_cli() {
  for candidate in antigravity agy; do
    if bin=$(command -v "$candidate" 2>/dev/null) && [ -x "$bin" ]; then
      printf '%s' "$bin"
      return 0
    fi
  done
  for candidate in \
    "$HOME/.local/bin/agy" "$HOME/.local/bin/antigravity" \
    "$HOME/.antigravity/bin/agy" "$HOME/.antigravity/bin/antigravity" \
    /opt/homebrew/bin/agy /opt/homebrew/bin/antigravity \
    /usr/local/bin/agy /usr/local/bin/antigravity; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  newest=""
  newest_time=0
  for candidate in "$HOME"/.t3/tools/antigravity-acp/*/versions/*/antigravity; do
    [ -x "$candidate" ] || continue
    mtime=$(stat -f %m "$candidate" 2>/dev/null || echo 0)
    if [ "$mtime" -ge "$newest_time" ]; then
      newest=$candidate
      newest_time=$mtime
    fi
  done
  [ -n "$newest" ] && printf '%s' "$newest"
}

# Asks the local Antigravity CLI to refresh its 1-hour access token in Keychain, using its saved
# refresh token. Capped to a few seconds and backed off on failure so it never stalls the widget.
renew_antigravity_signin() {
  refresh_wait="$CONFIG_DIR/ai-usage-antigravity-refresh-wait"
  if [ -f "$refresh_wait" ] && [ "$now" -lt "$(cat "$refresh_wait")" ]; then
    return 1
  fi
  refresh_token=$(printf '%s' "$signin" | plutil -extract token.refresh_token raw -o - - 2>/dev/null || true)
  [ -n "$refresh_token" ] || return 1
  cli=$(find_antigravity_cli 2>/dev/null || true)
  [ -n "$cli" ] || return 1
  left=$((deadline - $(date +%s)))
  [ "$left" -ge 5 ] || return 1
  cap=$((left - 2))
  [ "$cap" -le 6 ] || cap=6
  "$cli" models </dev/null >/dev/null 2>&1 &
  cli_pid=$!
  waited=0
  while kill -0 "$cli_pid" 2>/dev/null && [ "$waited" -lt "$cap" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  cli_status=0
  if kill -0 "$cli_pid" 2>/dev/null; then
    kill "$cli_pid" 2>/dev/null || true
    wait "$cli_pid" 2>/dev/null || true
    cli_status=124
  else
    wait "$cli_pid" 2>/dev/null || cli_status=$?
  fi
  if [ "$cli_status" = 0 ]; then
    read_antigravity_signin
    if [ "$signin_status" = 0 ]; then
      new_token=$(printf '%s' "$signin" | plutil -extract token.access_token raw -o - - 2>/dev/null || true)
      new_expires=$(epoch "$(printf '%s' "$signin" | plutil -extract token.expiry raw -o - - 2>/dev/null || true)" 2>/dev/null || true)
      if [ -n "$new_token" ] && { [ -z "$new_expires" ] || [ "$new_expires" -gt "$now" ]; }; then
        token=$new_token
        expires=$new_expires
        rm -f "$refresh_wait"
        return 0
      fi
    fi
  fi
  echo $((now + 900)) > "$refresh_wait"
  return 1
}

# Antigravity keeps its Google sign-in in the Keychain, as JSON or as "go-keyring-base64:" and the JSON
# in Base64. With other providers on, a sign-in that can't be read is a note in Antigravity's section.
signin_problem=""
if $show_antigravity; then
  read_antigravity_signin
  status=$signin_status
  if [ "$status" = 44 ] && $both; then
    show_antigravity=false
  elif [ "$status" = 44 ]; then
    echo "Antigravity isn't signed in on this Mac. Sign in to Antigravity to see its limits." >&2
    exit 1
  elif [ "$status" != 0 ] || ! printf '%s' "$signin" | plutil -extract token.access_token raw -o - - >/dev/null 2>&1; then
    signin_problem="StableBar couldn't read Antigravity's sign-in from the Keychain."
    if ! $both; then
      echo "$signin_problem" >&2
      exit 1
    fi
  fi
fi

if ! $show_claude && ! $show_codex && ! $show_antigravity && [ -z "$extras" ]; then
  echo "None of Claude Code, Codex and Antigravity is signed in on this Mac." >&2
  exit 1
fi

# The accounts still to come, each with at most one request, which share the time left.
pending=0
for shown in $show_claude $show_codex $show_antigravity; do
  ! $shown || pending=$((pending + 1))
done
[ -z "$extras" ] || pending=$((pending + $(printf '%s\n' "$extras" | wc -l)))
[ "$pending" -ge 1 ] || pending=1

if $show_claude; then
  provider=Claude app="Claude Code" brand=claude host=api.anthropic.com saved="$CONFIG_DIR/ai-usage-claude$main_suffix.json"
  limits=$CLAUDE
  json=$credentials
  claude_usage
  add_provider claude Claude https://claude.ai/settings/usage ""
fi

# The Keychain items already shown, so that a folder listed twice, or the main account's, shows once.
seen="[$main_suffix]"
while IFS= read -r entry; do
  entry=$(printf '%s' "$entry" | sed 's/^ *//; s/ *$//')
  # Without extra accounts, the loop reads one empty line.
  [ -n "$entry" ] || continue
  case $entry in
    *=*)
      name=$(printf '%s' "${entry%%=*}" | sed 's/ *$//')
      written=$(printf '%s' "${entry#*=}" | sed 's/^ *//')
      ;;
    *) name="" written=$entry ;;
  esac
  folder=$written
  case $folder in \~/*) folder="$HOME/${folder#\~/}" ;; esac
  suffix=""
  [ "$folder" = "$HOME/.claude" ] || suffix=$(hashed "$folder")
  case $seen in *"[$suffix]"*) account_done; continue ;; esac
  seen="${seen}[$suffix]"
  heading=${name:-$written}
  provider="Claude $(json_escape "$heading")" app="Claude Code" brand=claude host=api.anthropic.com saved="$CONFIG_DIR/ai-usage-claude$suffix.json"
  limits=$CLAUDE
  plan=""
  status=0
  json=$(security find-generic-password -s "Claude Code-credentials$suffix" -w 2>/dev/null) || status=$?
  if [ "$status" = 0 ]; then
    claude_usage
  elif [ "$status" = 44 ]; then
    json="" note="Claude Code isn't signed in with $written."
  else
    json="" note="StableBar couldn't read the sign-in for $written from the Keychain."
  fi
  # Only a name the entry gives goes on the bar; the popup and the tooltip name the folder otherwise.
  add_provider claude "Claude · $heading" https://claude.ai/settings/usage "$name"
done <<END
$extras
END

if $show_codex; then
  provider=Codex app=Codex brand=codex host=chatgpt.com saved="$CONFIG_DIR/ai-usage-codex.json"
  limits=$CODEX
  json=$(cat "$HOME/.codex/auth.json")
  token=$(read_json tokens.access_token 2>/dev/null || true)
  account=$(read_json tokens.account_id 2>/dev/null || true)
  # Signed in with an API key instead of a ChatGPT account, Codex has no plan limits to show.
  if [ -z "$token" ] || [ -z "$account" ]; then
    json="" note="Codex isn't signed in with a ChatGPT account, so it has no plan limits to show."
  else
    fetch "https://chatgpt.com/backend-api/wham/usage" <<END
Authorization: Bearer $token
ChatGPT-Account-Id: $account
END
  fi
  plan=""
  if [ -n "$json" ]; then
    plan=$(read_json plan_type)
    for window in primary_window secondary_window; do
      length=$(read_json "rate_limit.$window.limit_window_seconds" 2>/dev/null || true)
      [ -n "$length" ] || continue
      used=$(read_json "rate_limit.$window.used_percent")
      resets=$(read_json "rate_limit.$window.reset_at")
      if [ "$length" -lt 86400 ]; then
        add_window Session session "$used" "$resets"
      else
        add_window Weekly weekly "$used" "$resets"
      fi
    done
  fi
  add_provider codex Codex https://chatgpt.com/codex/settings/usage ""
fi

# Antigravity groups the models that share limits, such as Gemini Models and Claude and GPT models,
# each with a 5-hour and a weekly limit. The bar shows the group the setting names, and the popup every
# group. Google access tokens last an hour; when expired, try renewing through the local CLI first,
# and otherwise show the last saved limits calmly while Antigravity is idle.
if $show_antigravity; then
  provider=Antigravity app=Antigravity brand=antigravity host=aicode.googleapis.com saved="$CONFIG_DIR/ai-usage-antigravity-quota.json"
  limits=$ANTIGRAVITY
  plan=""
  expired_idle=false
  if [ -n "$signin_problem" ]; then
    json="" note=$signin_problem
  else
    json=$signin
    token=$(read_json token.access_token)
    # An expiry that's missing or unreadable is unknown: the request then tells whether it still works.
    expires=$(epoch "$(read_json token.expiry 2>/dev/null || true)" 2>/dev/null || true)
    renewed=false
    if [ -n "$expires" ] && [ "$expires" -le "$now" ]; then
      if renew_antigravity_signin; then
        renewed=true
      elif [ -f "$saved" ]; then
        json=$(cat "$saved")
        data_time=$(stat -f %m "$saved")
        note=""
        notice="Antigravity is idle; showing limits from $(date -r "$data_time" +%H:%M). Open Antigravity to refresh."
        expired_idle=true
      else
        json=""
        note="Antigravity's sign-in has expired; open Antigravity to renew it."
      fi
    fi
    if ! $expired_idle && [ -n "$json" ]; then
      fetch_status=""
      fetch "https://aicode.googleapis.com/v1alpha/remote:getUserQuotaSummary" <<END
Authorization: Bearer $token
User-Agent: antigravity
END
      # If the token was rejected before expiry was known, renew once through the CLI and retry.
      if ! $renewed && { [ "$fetch_status" = 401 ] || [ "$fetch_status" = 403 ]; } && renew_antigravity_signin; then
        fetch "https://aicode.googleapis.com/v1alpha/remote:getUserQuotaSummary" <<END
Authorization: Bearer $token
User-Agent: antigravity
END
      fi
    fi
  fi
  if [ -n "$json" ]; then
    groups=summary.response.groups
    total=$(read_json "$groups" 2>/dev/null || echo 0)
    case $total in '' | *[!0-9]*) total=0 ;; esac
    # The group on the bar: the first whose name starts with the setting's, such as "Gemini".
    wanted=$(printf '%s' "$ANTIGRAVITY_MODELS" | tr '[:upper:]' '[:lower:]')
    shown=""
    g=0
    while [ "$g" -lt "$total" ]; do
      models=$(read_json "$groups.$g.displayName" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
      case $models in "$wanted"*) shown=$g && break ;; esac
      g=$((g + 1))
    done
    if [ -z "$shown" ] && [ "$total" -gt 0 ]; then
      shown=0
      notice="${notice:+$notice }Antigravity lists no $ANTIGRAVITY_MODELS models, so the bar shows $(read_json "$groups.0.displayName" 2>/dev/null || printf 'its first group')."
    fi
    # The tooltip names the group the bar shows.
    models=$(read_json "$groups.${shown:-0}.displayName" 2>/dev/null | sed 's/ [Mm]odels$//' || true)
    provider="Antigravity${models:+ ($(json_escape "$models"))}"
    g=0
    while [ "$g" -lt "$total" ]; do
      models=$(read_json "$groups.$g.displayName" 2>/dev/null | sed 's/ [Mm]odels$//' || true)
      buckets=$(read_json "$groups.$g.buckets" 2>/dev/null || echo 0)
      case $buckets in '' | *[!0-9]*) buckets=0 ;; esac
      # The session first and the week second, as for Claude and Codex, then any other limit.
      for kind in 5h weekly other; do
        b=0
        while [ "$b" -lt "$buckets" ]; do
          at="$groups.$g.buckets.$b"
          b=$((b + 1))
          window=$(read_json "$at.window" 2>/dev/null || true)
          case $kind:$window in
            5h:5h | weekly:weekly) ;;
            other:5h | other:weekly) continue ;;
            other:*) ;;
            *) continue ;;
          esac
          # A limit without a share left from 0 to 1 measures nothing to show.
          left=$(read_json "$at.remainingFraction" 2>/dev/null || true)
          awk -v left="$left" 'BEGIN { exit !(left ~ /^([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/ && left + 0 <= 1) }' || continue
          used=$(awk -v left="$left" 'BEGIN { printf "%.2f", 100 - left * 100 }')
          # A window that hasn't started has no reset time.
          resets=$(read_json "$at.resetTime" 2>/dev/null || true)
          [ -z "$resets" ] || resets=$(epoch "$resets" 2>/dev/null || true)
          # While Antigravity is idle, a window whose reset time has already passed has reset.
          if $expired_idle && [ -n "$resets" ] && [ "$resets" -le "$now" ]; then
            used=0
            resets=""
          fi
          # Only the shown group's limits go on the bar.
          where=popup
          [ "$g" != "$shown" ] || where=bar
          case $window in
            5h) add_window "${models:+$models · }Session" session "$used" "$resets" "$where" ;;
            weekly) add_window "${models:+$models · }Weekly" weekly "$used" "$resets" "$where" ;;
            *) add_window "${models:+$models · }$(read_json "$at.displayName" 2>/dev/null || printf Limit)" group "$used" "$resets" ;;
          esac
        done
      done
      g=$((g + 1))
    done
    # Without a limit for the bar, as the setting chooses them, the bar shows Antigravity's logo, which
    # opens the popup and its limits, or, without any limit, Antigravity shows in the popup only.
    if [ -z "$rows" ]; then
      json="" note="Antigravity reported no limits."
    elif [ -z "$group" ]; then
      notice="${notice:+$notice }Antigravity reported none of the limits the bar shows."
    fi
  fi
  add_provider antigravity Antigravity "" ""
fi

if [ -z "$bar" ]; then
  echo "$failures" >&2
  exit 1
fi

# Each provider's color: Claude's orange, OpenAI's green and Google's blue.
styles='"stale":{"opacity":0.55}'"$pace_styles"
for brand in claude:D97757 codex:10A37F antigravity:4285F4; do
  styles="$styles,\"${brand%%:*}\":{\"foreground\":\"#${brand#*:}\",\"accent\":\"#${brand#*:}\"}"
done

printf '{"text":"%s","tooltip":"%s","interval":%s,"styles":{%s},"fields":{"updated":"Updated at %s"},"lists":{"popup":[%s],"bar":[%s]}}\n' \
  "$summary" "$tooltip" "$interval" "$styles" "$(date -r "$updated" +%H:%M)" "$popup" "$bar"
