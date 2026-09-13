#!/usr/bin/env bash
#
########################################
# Dependencies:
#	curl
#	imagemagick
#	jq
########################################
# References:
#	<https://github.com/jpatzy/whaven>
########################################
#; Changes:
#; Ver  Date        Author  Comment
#; 1.0	2024-06-24	JJS		Initial Release
#; 1.1	2024-06-25	JJS		Feature Complete
#; 1.2	2024-10-05	JJS		+SIGHUP
########################################
#:
#: This script Downloads and sets random wallpapers from Wallhaven.cc based on keywords (-k) or a
#: specified directory (-d) at an specified interval (-i), or a single specified file (-f).
#: If no options will download and set random wallpaper every 5 minutes from random hardcoded keywords.
#: Receipt of SIGUSR1 will restart the timer and retrieve next wallpaper.
#: Receipt of SIGUSR2 performs SIGUSR1 action with a new set of random hardcoded keywords.
#: Receipt of SIGRTMIN will notify the keywords being used.
#: Receipt of SIGRTMAX will save the current wallpaper.
#:
#: Usage: $script [-h] [-u] [-v] [-a] [-d] [-f] [-i] [-k] [-p] [-q]
#:
#: Options:
#:	-h, -u	display help/usage and exit
#:	-v		display version and exit
#:	-a		personal api key (additionally retrieve NSFW images)
#:	-d		input directory (exclusive to -f, -k)
#:	-f		input file (exclusive to -d, -k)
#:	-k		wallhaven.cc keyword(s) or @user(s)
#:			multiples -k kwd1 -k kwd2 or -k kwd1+kwd2 or -k "kwd1 kwd2"
#:	-i		change interval in seconds
#:	-p		pick wallpaper from provided directory
#:	-q		add quotations to wallpaper
#:
########################################

########################################
# Shell Sets
########################################

#set -x
#exec &>2 $ Shutup
set -o pipefail   #### -u ####

########################################
# Variables
########################################


TMPDIR="$HOME/.cache/whaven"
PIDFILE="$TMPDIR/whaven.pid"
walldir="$HOME/.local/share/wallpaper"
wallfile=
walls=()
WALLPAPER="$TMPDIR/wallpaper"
WALLPAPER_BLURRED="$TMPDIR/wallpaper_blurred"

# Wallhaven API
api="https://wallhaven.cc/api/v1/search?"   # base url
key="$(<~/.creds/wallhaven)"				# personal api key (only needed for NSFW wallpapers)
categories=100                              # 1=on,0=off (general/anime/people)
purity=111                                  # 1=on,0=off (sfw/sketchy/nsfw)
ratios=landscape                            # 16x9/16x10/4:3/landscape
resolutions=1920x1080
colors=000000
sorting=random	#views						# date_added, relevance, random, views, favorites, toplist

api_opts=( \
	apikey=${key}\&\
	categories=${categories}\&\
	purity=${purity}\&\
	atleast=1920x1080\&\
	ratios=${ratios}\&\
  colors=${colors}\&\
	sorting=${sorting}
)

curl_opts=( \
	-sS \
	--connect-timeout 5 \
	--max-time 10 \
	--retry 3 \
	--retry-delay 3 \
	--retry-max-time 20 \
)

awww_opts=( \
  --all \
  --outputs HDMI-A-1,HDMI-A-2 \
	--resize fit \
	--transition-bezier .54,0,.34,.99 \
	--transition-fps 60 \
	--transition-type random \
	--transition-pos center \
	--transition-duration 3 \
	--transition-step 90 \
)

magick_resize_opts=( \
	-resize 1920x1080^ \
	-gravity center \
	-extent 1920x1080 \
)

magick_blur_opts=( \
	-resize 75% \
	-blur 20x12 \
)

########################################
# Functions
########################################

usage() {
	echo "$(grep "^#:" "${BASH_SOURCE[0]:-$0}" | sed -e "s/^...//" -e "s/\$script/$script/g" -e "s/#://g")"
}

version() {
	local vnum="$(grep "^#;" "${BASH_SOURCE[0]:-$0}" | tail -1 | sed -e "s/^..//" | tr -s " " | cut -d" " -f2)"
	local vdate="$(grep "^#;" "${BASH_SOURCE[0]:-$0}" | tail -1 | sed -e "s/^..//" | tr -s " " | cut -d" " -f3)"
	echo "$script v$vnum $vdate"
}

chk_dep() {
	command -v "$1" &>/dev/null
}

chk_noctalia() {
	#qs list --all | grep -q noctalia
  pgrep --quiet -x noctalia
}

notify() {
	if ! chk_noctalia; then
		notify-send \
			--category="$1" \
			--urgency=low \
			--icon=/usr/share/icons/Adwaita/16x16/mimetypes/image-x-generic.png \
			"Wallhaven" \
			"${2-}"
	else
		#toast='{"type": "notice", "icon": "livewallpaper-indicator", "title": "Whaven", "body": '
    toast='{"app_name":"Whaven","summary":"Whaven","urgency":"low","icon":"livewallpaper-indicator","body":'
		json="$toast\"${2}\"}"
		#qs -c noctalia-shell ipc call toast send "$json"
    noctalia msg notification-show "$json"
	fi
}

datm() {
	date '+%F %T'
}

ep_sec() {
	date '+%s'
}

msg() {
	# print non-script output: errs/logs/messages
	printf "[%s] [%s] %s\n" "$(datm)" "${1}" "${2-}" >&2
}

#rand()( {
#	local -n intarr=${1}
#	RANDOM=$$$(date +%s)
#	echo "$(${intarr[ $RANDOM % ${#intarr[@]} ]})"
#}

subject() {
	words=( \
		"tech+technology" \
		"vintage+tech" \
		"german+shepherd" \
		"husky+huskies" \
		"wolf+wolves" \
		"dog+dogs" \
		"circuit+circuitry" \
		"electronic+electricity" \
		"code" \
		"test+pattern" \
		"particles" \
		"audio" \
		"spectrum" \
		"cogs+gears" \
		"mechanism+machinery" \
		"nightscape" \
		"id:17952" \
		"id:344" \
		"@jrmnt" \
		"#Fangpeii" \
		"monochrome+nature" \
		"map+globe" \
		"id:81213" \
		"@waneella" \
		"@joejazz" \
		"planets+stars+nebulae" \
		"@userisro" \
		"@pc7" \
		"monochrome+wildlife" \
		"national+parks" \
		"landmark" \
		"dystopia" \
		"tolkien" \
		"nikola+tesla" \
		"physics+science" \
		"@CartographerStorm" \
		"Kvacm" \
		"escher" \
		"world+heritage" \
		"Aenami" \
	)

	if [ -z "$keywords" ]; then
		RANDOM=$$$(date +%s)
		keywords="${words[ $RANDOM % ${#words[@]} ]}"
		text="Keywords: $keywords"
		msg "INFO" "$text"
		notify "INFO" "$text"
	fi
	keywords=$(echo $keywords | tr " " "+" | sed 's/+$//')
}

wh_images() {
	while :; do
		subject
		main
		get_images
		dl_wallpaper
		gen_blur
		add_quote
		set_wallpaper
		sleep "$interval" &
		wait $!
	done
}

dir_images() {
	if [ -d "$walldir" ]; then
		while :; do
			shopt -s nullglob
			walls=($walldir/*.{png,jpg,jpeg,gif})
			shopt -u nullglob
			RANDOM=$$$(date +%s)
			wallnum=$(($RANDOM % (${#walls[@]} - 2 + 1) + 0))
			cp "${walls[$wallnum]}" "$WALLPAPER"
			gen_blur
			add_quote
			set_wallpaper
			sleep "$interval" &
			wait $!
		done
	else
		text="Directory not found!"
		msg "ERROR" "$text"
	fi
}

file_image() {
	if [ -f "$wallfile" ]; then
		cp "$wallfile" "$WALLPAPER"
		add_quote
		set_wallpaper
		text="Wallpaper: $WALLPAPER"
		msg "INFO" "$text"
		notify "INFO" "$text"
	else
		text="$WALLPAPER does not exist!"
		msg "ERROR" "$text"
		notify "ERROR" "$text"
		exit 1
	fi
}

picker() {
	if [ -d "$walldir" ]; then
		wallfile="$(ls $walldir | rofi -dmenu)"
		wallfile="$walldir/$wallfile"
		file_image
	else
		text="$walldir does not exist!"
		msg "ERROR" "$text"
		notify "ERROR" "$text"
		exit 1
	fi
}

get_images() {
	API_URL="${api}apikey=${key}&q=${keywords}&categories=${categories}&purity=${purity}&atleast=1920x1080&ratios=${ratios}&sorting=${sorting}"
	API_CURL=$(curl ${curl_opts[@]} $API_URL)
	#echo $API_URL
}

gen_blur() {
	blurred="$TMPDIR/blurred_wallpaper.png"
	blur="20x12"
	magick "$WALLPAPER" -resize 75% "$blurred"
	if [ "$blur" != "0x0" ]; then
		magick "$blurred" -blur "$blur" "$blurred"
	fi
}

resize_wall() {
	magick "$WALLPAPER" "${magick_resize_opts[@]}" "$WALLPAPER"
}

add_quote() {
	if [ "$quots" -eq 1 ]; then
		# <https://github.com/Cybersnake223/Hypr/blob/main/.local/bin/scripts/changewall>
		cols=60
		font=/usr/share/fonts/OTF/SpaceGrotesk-SemiBold.otf
		font_size=32
		font_color=lightgray
		shad_color=black
		quote=$(fortune -e ~/.local/share/fortune/my-collected-quotes | fold -s -w $cols | sed 's/--/—/')
		resize_wall
		magick \
			"$WALLPAPER" \
			-gravity North \
			-font "$font" \
			-pointsize "$font_size" \
			-fill "$shad_color" \
			-annotate +0+100 "$quote" \
			-fill "$font_color" \
			-annotate +2+102 "$quote" \
			"$WALLPAPER"
	else
		return
	fi
}

awww_set() {
	awww img "$WALLPAPER" "${awww_opts[@]}"
}

noctalia_set() {
	epoch="$(ep_sec)"
	cp "$WALLPAPER" "$TMPDIR/wallpaper_$epoch"
	#qs -c noctalia-shell ipc call wallpaper set $TMPDIR/wallpaper_$epoch all
  noctalia msg wallpaper-set $TMPDIR/wallpaper_$epoch
	sleep 1
	rm "$TMPDIR/wallpaper_$epoch"
}

set_wallpaper() {
	if chk_dep awww; then
		awww_set
	fi
	if chk_noctalia; then
		noctalia_set
	fi
}

main() {
	if get_images; then
		if [[ $API_CURL == *"path"* ]]; then  # if results contain full path url
			if hash jq > /dev/null 2>&1 ; then  # then decide which function to define
				dl_wallpaper() {
					entries=$(echo $API_CURL | jq -r '[.data[] | .path]' | wc -l)
					if [ "$entries" -lt 2 ]; then
						subject
						return
					fi
					RANDOM=$$$(date +%s)
					entry=$(($RANDOM % ($entries - 2 + 1) + 0))
					IMAGE_URL=$(echo "$API_CURL" | jq -r "[.data[] | .path] | .[$entry]")
					FILE="$(echo ${IMAGE_URL##*/})"
					text="Wallpaper: $IMAGE_URL"
					msg "INFO" "$text"
					curl -sS --max-time 10 --retry 2 --retry-delay 3 --retry-max-time 20 "$IMAGE_URL" -o "$WALLPAPER" #"$HOME/.cache/wallpaper.${IMAGE_URL##*.}"
					cp "$WALLPAPER" "$WALLPAPER.ORG"
				}
			else
				dl_wallpaper() {
					trim="${API_CURL##*path}"
					echo "$trim" | cut -c 4-59 | xargs curl -sS --max-time 10 --retry 2 --retry-delay 3 --retry-max-time 20 -o "$WALLPAPER" #"$HOME/.cache/wallpaper.${IMAGE_URL##*.}"
				}
			fi
		else
			# if $API_CURL does not return at least one full path url
			text="No results - Fetching new keywords!"
			msg "ERROR" "$text"
			notify "ERROR" "$text"
			keywords=
			wh_images
		fi
	else
		text="Wallhaven API failure: retry in $interval seconds."
		msg "ERROR" "$text"
		notify "ERROR" "$text"
		sleep "$interval" &
		wait $!
	fi
}

# next wallpaper
handle_usr1() {
	if [ "$mode" == "dir" ]; then
		dir_images
	elif [ "$mode" == "pick" ]; then
		picker
	else
		wh_images
	fi
}

# new keywords
handle_usr2() {
	if [ "$mode" == "dir" ]; then
		dir_images
	else
		keywords=
		wh_images
	fi
}

# notify current keywords
handle_rtmin() {
	if [ "$mode" == "dir" ] || [ "$mode" == "pick" ]; then
		notify "ERROR" "Keywords not applicable in $mode mode."
	else
		notify "INFO" "Keywords: $keywords"
	fi
	sleep "$interval" &
	wait $!
}

# save current wallpaper
handle_rtmax() {
	if ! [ -d "$walldir" ]; then
		mkdir "$walldir"
	fi
	cp "$WALLPAPER.ORG" "$walldir/$FILE"
	notify "INFO" "Wallpaper: $FILE saved!"
	sleep "$interval" &
	wait $!
}

########################################
# Script
########################################

if ! [ -d "$TMPDIR" ]; then
	mkdir "$TMPDIR"
fi

# pidfile
if [[ -f "$PIDFILE" && $(pgrep $(cat $PIDFILE)) ]]; then
	kill -TERM "$(cat $PIDFILE)"
	rm "$PIDFILE"
fi
echo $$ >"$PIDFILE"

trap handle_usr1 SIGUSR1
trap handle_usr2 SIGUSR2
trap handle_rtmin SIGRTMIN
trap handle_rtmax SIGRTMAX

script="$(basename "${BASH_SOURCE[0]:-$0}")"

deps=( curl magick jq )
for dep in "${deps[@]}"; do
	if ! chk_dep "$dep"; then
		text="$script depends on $dep"
		msg "ERROR" "$text"
		exit 1
	fi
done

interval=300
mode=
keywords=
key=
quots=0

OPTERR=0	# same as leading : in opts???
while getopts ":huva:d:f:i:k:qp:" option; do
	case $option in
		h|u )	usage
				exit
				;;
		v )		version
				exit
				;;
		a )		key="$OPTARG"
				;;
		d )		mode=dir
				walldir="$OPTARG"
				;;
		f )		mode=file
				wallfile="$OPTARG"
				;;
		i )		if [ "$OPTARG" -lt 60 ]; then
					interval=60
				else
					interval="$OPTARG"
				fi
				;;
		k )		mode=wh
				keywords+="$OPTARG+"
				;;
		p )		mode=pick
				walldir="$OPTARG"
				;;
		q )		quots=1
				;;
		* )		msg "ERROR" "Invalid option \"-$OPTARG\"!"
				usage
				exit 1
				;;
	esac
done

if [ "$mode" == "dir" ]; then
	sleep 10
	dir_images
elif [ "$mode" == "file" ]; then
	file_image
elif [ "$mode" == "pick" ]; then
	picker
	#sleep infinity	# blocks -SIGUSR
	sleep infinity &
	wait $!
elif [ "$mode" == "wh" ]; then
	sleep 10
	wh_images
else
	sleep 10
	wh_images
fi

exit 0
