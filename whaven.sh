#!/usr/bin/env bash
# whaven.sh -- randomized wallpapers from wallhaven.cc
#
# Dependencies: curl, imagemagick (magick), jq
#   rofi  (only for -p),  fortune (only for -q)
# References: <https://github.com/jpatzy/whaven>
#
#; Changes:
#; 1.0  2024-06-24  JJS  Initial Release
#; 1.1  2024-06-25  JJS  Feature Complete
#; 1.2  2024-10-05  JJS  +SIGHUP
#; 1.3  2026-09-13  HMB  Refactor: shellcheck-clean, single event loop
#
#: Downloads and sets random wallpapers from wallhaven.cc based on keywords
#: (-k), a directory (-d), a rofi picker (-p), or sets a single file (-f),
#: at a chosen interval (-i). With no options it fetches a random wallpaper
#: every 5 minutes using randomized built-in keywords.
#:
#: Signals:
#:   SIGUSR1   fetch the next wallpaper immediately
#:   SIGUSR2   fetch the next wallpaper with fresh keywords
#:   SIGRTMIN  show the keywords currently in use
#:   SIGRTMAX  save the current wallpaper into the wallpaper directory
#:   SIGHUP    same as SIGUSR1
#:
#: Usage: $script [-h] [-u] [-v] [-a] [-d] [-f] [-i] [-k] [-p] [-q] [-t THEME]
#:
#: Options:
#:   -h, -u  show help and exit
#:   -v      show version and exit
#:   -a      personal API key (required for NSFW images)
#:   -d      input directory (exclusive with -f, -k, -p)
#:   -f      input file (exclusive with -d, -k, -p)
#:   -k      wallhaven.cc keyword(s) or @user(s); may be repeated
#:           (-k a -k b), space-separated (-k "a b"), or joined (-k a+b)
#:   -i      interval in seconds (min 60, default 300)
#:   -p      pick a wallpaper from a directory via rofi
#:   -q      overlay a fortune quote on the wallpaper
#:   -t      theme filter for fetched wallpapers: dark (default) or light;
#:           wallpapers whose average brightness mismatches are refetched
#:
#: Environment:
#:   WHAVEN_API_KEY        personal API key (overrides cred file)
#:   WHAVEN_CRED_FILE      key file        (default ~/.creds/wallhaven)
#:   WHAVEN_CACHE_DIR      cache dir       (default ~/.cache/whaven)
#:   WHAVEN_WALLPAPER_DIR  saved-wallpaper dir (default ~/.local/share/wallpaper)
#
########################################

set -o pipefail

########################################
# Configuration
########################################

# API key: -a flag beats env, env beats ~/.creds/wallhaven (legacy)
WHAVEN_API_KEY="${WHAVEN_API_KEY:-}"
cred_file="${WHAVEN_CRED_FILE:-$HOME/.creds/wallhaven}"
if [[ -z "$WHAVEN_API_KEY" ]] && [[ -r "$cred_file" ]]; then
	read -r WHAVEN_API_KEY <"$cred_file"
fi

# Paths (XDG-aware, individually overridable)
TMP="${WHAVEN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/whaven}"
WALLDIR="${WHAVEN_WALLPAPER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wallpaper}"
WALLPAPER="$TMP/wallpaper"
WALLPAPER_ORIG="$TMP/wallpaper.orig"
PIDFILE="$TMP/whaven.pid"

# Wallhaven API
API="https://wallhaven.cc/api/v1/search"
categories=100 # general=1 anime=2 people=4 -> 100 = general only
purity=111     # sfw=1 sketchy=2 nsfw=4 -> 111 = all three
atleast=1920x1080
ratios=landscape # landscape | 16x9 | 16x10 | 4:3
sorting=random   # date_added | relevance | random | views | favorites | toplist

interval=300 # seconds between wallpapers (min 60)
mode=        # '' | wh | dir | file | pick
kws=         # accumulated search keywords (wh mode)
quots=0
theme=dark # dark | light -- enforced for fetched wallpapers (wh mode)
theme_retries=5
quote_font="$HOME/.local/share/fonts/TTF/Fuzzy_Bubbles/FuzzyBubbles-Bold.ttf"
quote_font_fallback=/usr/share/fonts/OTF/SpaceGrotesk-SemiBold.otf

curl_opts=(-sS --connect-timeout 5 --max-time 10 --retry 5 --retry-delay 3 --retry-max-time 20)

magick_extend_opts=(-background "#000000" -gravity center -extent 1920x1080)

awww_opts=(
	--all
	--outputs "HDMI-A-1,HDMI-A-2"
	--resize fit
	--transition-bezier ".54,0,.34,.99"
	--transition-fps 60
	--transition-type random
	--transition-pos center
	--transition-duration 3
	--transition-step 90
)

# Substitution keywords used when none are given with -k
words=(
	"tech+technology" "vintage+tech" "german+shepherd" "husky+huskies"
	"wolf+wolves" "dog+dogs" "circuit+circuitry" "electronic+electricity"
	"code" "test+pattern" "particles" "audio" "spectrum" "cogs+gears"
	"mechanism+machinery" "nightscape" "id:17952" "id:344" "@jrmnt"
	"#Fangpeii" "monochrome+nature" "map+globe" "id:81213" "@waneella"
	"@joejazz" "planets+stars+nebulae" "@userisro" "@pc7"
	"monochrome+wildlife" "national+parks" "landmark" "dystopia" "tolkien"
	"nikola+tesla" "physics+science" "@CartographerStorm" "Kvacm" "escher"
	"world+heritage" "Aenami"
)

########################################
# Helpers
########################################

now() { date '+%F %T'; }

log() { printf '[%s] [%s] %s\n' "$(now)" "$1" "${2:-}" >&2; }
err() { log ERROR "$*"; }

chk_dep() { command -v "$1" >/dev/null 2>&1; }
chk_noct() { pgrep -x noctalia >/dev/null 2>&1; }

notify() { # level message -> noctalia daemon if running, else notify-send
	local level="$1" msg="${2:-}"
	if chk_noct; then
		local json
		json="$(jq -nc --arg body "$msg" \
			'{app_name:"Whaven", summary:"Whaven", urgency:"low", icon:"livewallpaper-indicator", body:$body}')"
		noctalia msg notification-show "$json"
	else
		notify-send --category="$level" --urgency=low "Whaven" "$msg"
	fi
}

usage() {
	grep '^#:' "${BASH_SOURCE[0]:-$0}" | sed -e 's/^#: *//' -e "s/\$script/$(basename "${BASH_SOURCE[0]:-$0}")/g"
}

version() {
	local line ver date
	line="$(grep '^#;' "${BASH_SOURCE[0]:-$0}" | tail -1 | sed 's/^#; *//')"
	ver="$(awk '{print $1}' <<<"$line")"
	date="$(awk '{print $2}' <<<"$line")"
	echo "$(basename "${BASH_SOURCE[0]:-$0}") v$ver $date"
}

make_url() { # print the wallhaven search URL for the current state
	local url="$API?categories=${categories}&purity=${purity}&atleast=${atleast}"
	url+="&ratios=${ratios}&sorting=${sorting}"
	[[ -n "$kws" ]] && url+="&q=${kws}"
	[[ -n "$WHAVEN_API_KEY" ]] && url+="&apikey=${WHAVEN_API_KEY}"
	printf '%s' "$url"
}

image_brightness() { # 0-100 "darkness score" of $WALLPAPER; prints measured values
	# mean - 0.5*stdev: high-contrast images (bright sky + dark ground) score
	# darker than flat gray at the same mean -- closer to perceived darkness.
	# IM fx properties mean/standard_deviation are ALREADY normalized 0-1;
	# score = (mean - 0.5*stdev) * 100. Do NOT divide by quantumrange again.
	local mean stdev score
	mean="$(magick "$WALLPAPER" -format '%[fx:mean]' info: 2>/dev/null)" || return 1
	stdev="$(magick "$WALLPAPER" -format '%[fx:standard_deviation]' info: 2>/dev/null)" || return 1
	[[ -n "$mean" && -n "$stdev" ]] || return 1
	score="$(awk -v m="$mean" -v s="$stdev" 'BEGIN { x = (m - 0.5*s)*100; if (x < 0) x = 0; if (x > 100) x = 100; printf "%.0f", x }')"
	# always surface the measured values on the terminal (stderr) for judging
	printf '[brightness] mean=%.2f stdev=%.2f score=%s\n' "$mean" "$stdev" "$score" >&2
	printf '%s' "$score"
}

theme_ok() { # $1=score(0-100); true when it matches $theme
	local b="$1"
	if [[ "$theme" == light ]]; then
		((b >= 65))
	else
		((b < 35))
	fi
}

########################################
# Wallpaper acquisition
########################################

pick_keyword() { # print one random substitution keyword
	local count="${#words[@]}"
	printf '%s\n' "${words[$((RANDOM % count))]}"
}

subject() { # ensure kws has content (wh mode); convert spaces to '+'
	local picked
	if [[ -z "$kws" ]]; then
		picked="$(pick_keyword)"
		kws="$picked"
		log INFO "keywords: $kws"
		((quiet)) || notify INFO "keywords: $kws"
	fi
	kws="${kws// /+}"
}

dl_wallpaper() { # wh mode: pick a random wallhaven result and download it
	subject
	local url json n path
	url="$(make_url)"
	if ! json="$(curl "${curl_opts[@]}" --fail "$url")"; then
		err "Wallhaven API failure (retry in ${interval}s)"
		notify ERROR "Wallhaven API failure"
		return 1
	fi
	if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
		err "Invalid API response (retry in ${interval}s)"
		notify ERROR "Invalid API response"
		return 1
	fi
	n="$(jq -r '.data | length' <<<"$json")" || return 1
	if [[ "$n" -eq 0 ]]; then
		err "No results; taking new keywords"
		notify ERROR "No results"
		kws=
		return 1
	fi
	path="$(jq -r --argjson i "$((RANDOM % n))" '.data[$i].path' <<<"$json")" || return 1
	[[ -n "$path" && "$path" != null ]] || {
		err "No usable path in response"
		return 1
	}
	if ! curl "${curl_opts[@]}" --fail "$path" -o "$WALLPAPER"; then
		err "Download failed (retry in ${interval}s)"
		notify ERROR "Download failed"
		return 1
	fi
	[[ -s "$WALLPAPER" ]] || {
		err "Empty download"
		return 1
	}
	# theme enforcement: refetch if the sampled brightness mismatches
	if ! theme_ok "$(image_brightness)"; then
		err "Theme mismatch ($theme): refetching"
		return 2 # dl_wallpaper retry sentinel
	fi
	cp "$WALLPAPER" "$WALLPAPER_ORIG"
	cur_src="$path"
	log INFO "Wallpaper: $path"
}

fetch_themed() { # dl_wallpaper + retry-on-theme-mismatch (wh mode only)
	local tries rc
	for ((tries = 1; tries <= theme_retries; tries++)); do
		dl_wallpaper && return 0
		rc=$?
		((rc == 2)) || return "$rc" # non-theme failure: report as-is
		((tries < theme_retries)) && sleep 2
	done
	# no luck after N attempts: rotate keywords (same as SIGUSR2) and try again
	log INFO "theme $theme not found in ${theme_retries} attempts; rotating keywords"
	kws=
	subject # picks + notifies the new keywords
	dl_wallpaper
}

quote_overlay() { # overlay a fortune quote when -q is given
	[[ "$quots" -ne 1 ]] && return 0
	chk_dep fortune || return 0
	local quote
	local -a font_arg=()
	quote="$(fortune -e "$HOME/.local/share/fortune/my-collected-quotes" 2>/dev/null |
		fold -s -w 60 | sed 's/--/—/')" || true
	[[ -z "$quote" ]] && return 0
	# preferred font, then fallback; skip -font entirely if neither exists (IM default)
	if [[ -f "$quote_font" ]]; then
		font_arg=(-font "$quote_font")
	elif [[ -f "$quote_font_fallback" ]]; then
		font_arg=(-font "$quote_font_fallback")
	fi
	# crop-resize to the target geometry, then draw shadowed text
	magick "$WALLPAPER" -resize 1920x1080^ "${magick_extend_opts[@]}" "$WALLPAPER"
	magick "$WALLPAPER" "${font_arg[@]}" \
		-gravity North -pointsize 32 -fill black -annotate "+0+100" "$quote" \
		-gravity North -pointsize 32 -fill gray70 -annotate "+2+102" "$quote" \
		"$WALLPAPER"
}

set_bg() { # apply the wallpaper via noctalia (if running) and/or awww
	local epoch
	if chk_noct; then
		epoch="$(date +%s)"
		cp "$WALLPAPER" "$TMP/wallpaper.$epoch"
		noctalia msg wallpaper-set "$TMP/wallpaper.$epoch"
		sleep 1
		rm -f "$TMP/wallpaper.$epoch"
	fi
	if chk_dep awww; then
		awww img "$WALLPAPER" "${awww_opts[@]}"
	fi
}

dir_wall() { # dir mode: rotate through a directory
	shopt -s nullglob
	local -a files=("$WALLDIR"/*.{png,jpg,jpeg,gif,PNG,JPG,JPEG,GIF})
	shopt -u nullglob
	[[ ${#files[@]} -gt 0 ]] || {
		err "No images in $WALLDIR"
		return 1
	}
	local chosen="${files[$((RANDOM % ${#files[@]}))]}"
	cp "$chosen" "$WALLPAPER"
	cp "$chosen" "$WALLPAPER_ORIG"
	cur_src="$chosen"
	log INFO "Wallpaper: $chosen"
}

pick_wall() { # pick mode: rofi chooser, then set the image
	[[ -d "$WALLDIR" ]] || {
		err "$WALLDIR does not exist"
		notify ERROR "$WALLDIR does not exist"
		return 1
	}
	local base sel
	base="$(find "$WALLDIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) \
		-printf '%f\n' | sort | rofi -dmenu)" || return 1
	[[ -n "$base" ]] || return 1
	sel="$WALLDIR/$base"
	cp "$sel" "$WALLPAPER"
	cp "$sel" "$WALLPAPER_ORIG"
	cur_src="$sel"
	log INFO "Wallpaper: $sel"
}

file_wall() { # file mode: set a single image once
	cp "$wallfile" "$WALLPAPER"
	cp "$wallfile" "$WALLPAPER_ORIG"
	cur_src="$wallfile"
	log INFO "Wallpaper: $wallfile"
}

save_current() { # SIGRTMAX: copy the live wallpaper into the wallpaper dir
	[[ -s "$WALLPAPER_ORIG" ]] || {
		err "Nothing to save"
		return 1
	}
	mkdir -p "$WALLDIR"
	local name
	if [[ -n "$cur_src" ]]; then
		name="$(basename "$cur_src")"
	else
		name=wall
	fi
	local base="${name%.*}" ext="${name##*.}" n=1
	[[ "$ext" == "$name" ]] && ext=png # no extension in source name
	while [[ -e "$WALLDIR/$name" ]]; do
		name="${base}.$((n++)).$ext"
	done
	cp "$WALLPAPER_ORIG" "$WALLDIR/$name"
	log INFO "saved $WALLDIR/$name"
	notify INFO "Wallpaper saved: $name"
}

cycle() { # one wallpaper cycle for non-file modes
	case "$mode" in
	dir) dir_wall ;;
	pick) pick_wall ;;
	*) fetch_themed ;;
	esac
	quote_overlay
	set_bg
}

########################################
# Signal handling: traps poke the sleep so the loop wakes early
########################################

sleep_pid=
want_next=0
want_kw=0
need_save=0
quiet=0

poke() {
	[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null
	return 0
}

on_usr1() { # SIGUSR1: fetch next wallpaper, no notify
	want_next=1
	poke
}
on_usr2() { # SIGUSR2: new keywords + next wallpaper; notify only keywords
	want_kw=1
	poke
}
on_rtmin() { # SIGRTMIN: report current keywords, never fetch
	notify INFO "keywords: ${kws:-<dir/pick mode>}"
}
on_rtmax() { # SIGRTMAX: save current wallpaper + notify; never change wallpaper
	need_save=1
	poke
}
on_hup() { on_usr1; }

cleanup() {
	[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null
	rm -f "$PIDFILE"
}
trap cleanup EXIT
trap on_usr1 SIGUSR1
trap on_usr2 SIGUSR2
trap on_rtmin SIGRTMIN
trap on_rtmax SIGRTMAX
trap on_hup SIGHUP

########################################
# Bootstrap
########################################

script="$(basename "${BASH_SOURCE[0]:-$0}")"

for dep in curl magick jq; do
	chk_dep "$dep" || {
		err "$script depends on $dep"
		exit 1
	}
done
if [[ "$mode" == pick ]]; then
	chk_dep rofi || {
		err "$script needs rofi for -p"
		exit 1
	}
fi

mkdir -p "$TMP" "$WALLDIR" 2>/dev/null
if [[ -f "$PIDFILE" ]]; then
	old_pid="$(<"$PIDFILE")"
	if kill -0 "$old_pid" 2>/dev/null; then
		kill -TERM "$old_pid" 2>/dev/null
	fi
	rm -f "$PIDFILE"
fi
printf '%s\n' "$$" >"$PIDFILE"

OPTERR=0
while getopts ":huva:d:f:i:k:qp:t:" option; do
	case "$option" in
	h | u)
		usage
		exit 0
		;;
	v)
		version
		exit 0
		;;
	a) key="$OPTARG" ;;
	d)
		mode=dir
		WALLDIR="$OPTARG"
		;;
	f)
		mode="file"
		wallfile="$OPTARG"
		;;
	i) interval=$((OPTARG < 60 ? 60 : OPTARG)) ;;
	k)
		mode=k
		kws+="+${OPTARG}"
		;;
	p)
		mode=pick
		WALLDIR="$OPTARG"
		;;
	t)
		theme="$OPTARG"
		[[ "$theme" == dark || "$theme" == light ]] || {
			err "Invalid theme -t: $theme (expected dark|light)"
			exit 1
		}
		;;
	q) quots=1 ;;
	?)
		err "Invalid option: -$OPTARG"
		usage
		exit 1
		;;
	esac
done

[[ -n "${key:-}" ]] && WHAVEN_API_KEY="$key"
# tidy '+' accumulation from repeated -k and space-separated lists
kws="${kws#+}"
[[ -n "$kws" ]] && kws="${kws// /+}"

if [[ "$mode" == file ]]; then
	[[ -f "$wallfile" ]] || {
		err "$wallfile does not exist"
		exit 1
	}
	file_wall
	quote_overlay
	set_bg
	exit 0
fi

if [[ "$mode" == pick ]]; then
	pick_wall || exit 1
	quote_overlay
	set_bg
	while :; do
		sleep "$interval" &
		sleep_pid=$!
		wait "$sleep_pid"
		sleep_pid=
		if ((need_save)); then
			need_save=0
			save_current
		elif ((want_next)); then
			want_next=0
			quiet=1
			pick_wall && {
				quote_overlay
				set_bg
			}
			quiet=0
		fi
	done
fi

# dir and keyword modes share the same loop
# initial wallpaper immediately, then sleep-then-cycle for autorotation
case "$mode" in
dir) dir_wall ;;
*) fetch_themed ;;
esac
quote_overlay
set_bg
while :; do
	sleep "$interval" &
	sleep_pid=$!
	wait "$sleep_pid"
	wait_status=$?
	sleep_pid=

	# A poke (signal) interrupts the sleep, making wait return nonzero.
	# Then only deferred signal actions run -- never an unsolicited cycle.
	if ((need_save)); then
		need_save=0
		save_current
	fi
	if ((want_kw)); then
		want_kw=0
		kws=
		subject # notifies the new keywords
		quiet=1
		cycle # silent fetch
		quiet=0
	fi
	if ((want_next)); then
		want_next=0
		quiet=1
		cycle # silent fetch
		quiet=0
	fi

	# timer finished normally: set wallpaper (notifies)
	if ((wait_status == 0)); then
		cycle
	fi
done
