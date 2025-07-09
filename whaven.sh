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
#: If no options will download and set random wallpaper every 5 minutes from hardcoded keywords.
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
walls=()
wallpaper="$TMPDIR/wallpaper"

# Wallhaven API 
api="https://wallhaven.cc/api/v1/search?"   # base url
key=										# personal api key (only needed for NSFW wallpapers)
categories=100                              # 1=on,0=off (general/anime/people)
purity=111                                  # 1=on,0=off (sfw/sketchy/nsfw)
ratios=landscape                            # 16x9/16x10/4:3/landscape
resolutions=1920x1080
sorting=random	#views						# date_added, relevance, random, views, favorites, toplist

#API_URL="${api}apikey=${key}&q=${keywords}&categories=${categories}&purity=${purity}&ratios=${ratios}&sorting=${sorting}"
# "-sS" hide progress bar but show errors
# --connect-timeout (maximum time that you allow curl's connection to take
# --max-time 10     (how long each retry will wait)
# --retry 5         (it will retry 5 times)
# --retry-delay 0   (make curl sleep this amount of tie before each retry 
# --retry-max-time  (total time before it's considered failed)
# To limit  a  single  request's  maximum  time, use -m, --max-time.
# Set this option to zero to not timeout retries.
### Consider trimming $API_CURL right away to store as smaller string, might be quicker?
#API_CURL_TRIMMED="${API_CURL%%thumbs*}" # remove all after thumbs


curl_opts=( \
	-sS \
	--connect-timeout 5 \
	--max-time 10 \
	--retry 3 \
	--retry-delay 3 \
	--retry-max-time 20 \
)

swww_opts=( \
	--transition-bezier .43,1.19,1,.4 \
	--transition-fps 60 \
	--transition-type simple \
	--transition-duration 5 \
	--transition-step 4 \
)

########################################
# Functions
########################################

usage() {
	msg "$(grep "^#:" "${BASH_SOURCE[0]:-$0}" | sed -e "s/^...//" -e "s/\$script/$script/g" -e "s/#://g")"
}

version() {
	local vnum="$(grep "^#;" "${BASH_SOURCE[0]:-$0}" | tail -1 | sed -e "s/^..//" | tr -s " " | cut -d" " -f2)"
	local vdate="$(grep "^#;" "${BASH_SOURCE[0]:-$0}" | tail -1 | sed -e "s/^..//" | tr -s " " | cut -d" " -f3)"
	msg "$script v$vnum $vdate"
}

chk_dep() {
	command -v "$1" &>/dev/null
}

def_sets() {
	true
}

notify() {
	notify-send -i /usr/share/icons/Adwaita/16x16/mimetypes/image-x-generic.png "Wallhaven" "${1-}"
}

msg() {
	# print non-script output: errs/logs/messages
	echo >&2 -e "${1-}"
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
		"circuits+circuitry+electronics" \
		"monochrome+nature" \
		"map+globe" \
		"id:81213" \
		"@waneella" \
		"@joejazz" \
		"planets+stars+nebula" \
		"@userisro" \
		"@pc7" \
		"monochrome+wildlife" \
		"dystopian" \
		"Aenami" \
	)
	if [ -z "$keywords" ]; then
		RANDOM=$$$(date +%s)
		keywords="${words[ $RANDOM % ${#words[@]} ]}"
		msg "$keywords"
		notify "$keywords"
	fi
	keywords=$(echo $keywords | tr " " "+" | sed 's/+$//')
}

wh_images() {
	while :; do
		subject
		main
		get_images
		dl_wallpaper
		gen_colors
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
			cp "${walls[$wallnum]}" "$wallpaper"
			gen_colors
			gen_blur
			add_quote
			set_wallpaper
			sleep "$interval" &
			wait $!
		done
	else
		txt="Error: directory not found!"
		msg "$txt"
		notify "$txt"
	fi
}

file_image() {
	if [ -f "$wallfile" ]; then
		cp "$wallfile" "$wallpaper"
		add_quote
		set_wallpaper
		txt="Wallpaper set to: $wallpaper"
		msg "$txt"
		notify "$txt"
	else
		txt="Error: $wallpaper does not exist!"
		msg "$txt"
		notify "$txt"
		exit 1
	fi
}

picker() {
	if [ -d "$walldir" ]; then
		wallfile="$(ls $walldir | rofi -dmenu)"
		wallfile="$walldir/$wallfile"
		file_image
	else
		txt="Error: $walldir does not exist!"
		msg "$txt"
		notify "$txt"
		exit 1
	fi
}

get_images() {
	API_URL="${api}apikey=${key}&q=${keywords}&categories=${categories}&purity=${purity}&ratios=${ratios}&sorting=${sorting}"
	API_CURL=$(curl ${curl_opts[@]} $API_URL)
	#echo $API_URL
}

gen_colors() {
	if $(hash wal); then
		wal --saturate 1.0 --contrast 1.0 -q -s -t -n -i "$wallpaper"	# -s -t = no term color chg
		source "$HOME/.cache/wal/colors.sh"			# Load current pywal color scheme (NO CONTROL +u)
		if [[ $(pgrep waybar) ]]; then
			$HOME/.config/hypr/scripts/waybar-bg-fg.sh
			kill -USR2 $(pidof waybar)				# Reload waybar with new colors
		fi
		if [[ $(pgrep cava) ]]; then
			# FIXME - own script?
			# color="$(grep '\--color2' $HOME/.cache/wal/colors.css | awk '{print $2}' | tr -d ';')"
			colors=(rosewater flamingo pink mauve maroon peach yellow teal sky sapphire blue lavender text)
			RANDOM=$$$(date +%s)
			color="$(echo ${colors[RANDOM%${#colors[@]}]})"
			hex="$(grep "@define-color $color" $HOME/.config/hypr/theme_colors.css | awk '{print $3}' | tr -d ';')"
			#hex="$(grep '\--color2' .cache/wal/colors.css | awk '{print $2}' | tr -d ';')"
			sed -i "/foreground/c\foreground = '$hex'" ~/.config/cava/config
			kill -USR2 $(pidof cava)	            #HOME/.cache/wal/colors.sh Reload waybar with new colors
		fi
		#if $(hash wlogout); then
		#	$HOME/.config/hypr/scripts/wlogout-colors.sh
		#fi
	fi
}

gen_blur() {
	blurred="$TMPDIR/blurred_wallpaper.png"
	blur="20x12"
	magick "$wallpaper" -resize 75% "$blurred"
	if [ "$blur" != "0x0" ]; then
		magick "$blurred" -blur "$blur" "$blurred"
	fi
}

resize_wall() {
	# <https://imagemagick.org/Usage/resize/#resize>
	#imgw=identify -ping -format '%w' "$wallpaper"
	#imgh=identify -ping -format '%h' "$wallpaper"
	magick \
		"$wallpaper" \
		-resize 1920x1080^ \
		-gravity center \
		-extent 1920x1080 \
		"$wallpaper"
}

add_quote() {
	if [ "$quots" -eq 1 ]; then
		# <https://github.com/Cybersnake223/Hypr/blob/main/.local/bin/scripts/changewall>
		cols=60
		font=/usr/share/fonts/OTF/FiraMonoNerdFont-Medium.otf
		font_size=32
		font_color=lightgray
		shad_color=black
		quote=$(fortune -e ~/.local/share/fortune/my-collected-quotes | fold -s -w $cols | sed 's/--/—/')
		resize_wall
		magick \
			"$wallpaper" \
			-gravity North \
			-font "$font" \
			-pointsize "$font_size" \
			-fill "$shad_color" \
			-annotate +0+100 "$quote" \
			-fill "$font_color" \
			-annotate +2+102 "$quote" \
			"$wallpaper"
	else
		return
	fi
}

set_wallpaper() {
	if $(hash swww); then
		swww img $wallpaper "${swww_opts[@]}"
	elif $(hash hyprpaper); then
		cat <<- _EOF_ >$HOME/.config/hypr/hyprpaper.conf
			preload = $wallpaper
			wallpaper=HDMI-A-1,$wallpaper
			wallpaper=HDMI-A-2,$wallpaper
		_EOF_
		if pidof -q hyprpaper; then
			killall hyprpaper
		fi
		hyprpaper --config $HOME/.config/hypr/hyprpaper.conf &
	elif hash sway &> /dev/null; then
		feh --bg-fill "$wallpaper";
	elif hash gsettings &> /dev/null; then
		WHICH_MODE=$(gsettings get org.gnome.desktop.interface color-scheme)
		if [[ "$WHICH_MODE" == "'prefer-dark'" ]]; then
			gsettings reset org.gnome.desktop.background picture-uri-dark
			gsettings set org.gnome.desktop.background picture-uri-dark "$wallpaper"
		elif [[ "$WHICH_MODE" == "'default'" ]]; then
			gsettings reset org.gnome.desktop.background picture-uri
			gsettings set org.gnome.desktop.background picture-uri "$wallpaper"
		fi
	else
		echo "No wallpaper utility was found!!!"
		exit 1
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
					curl -sS --max-time 10 --retry 2 --retry-delay 3 --retry-max-time 20 "$IMAGE_URL" -o "$wallpaper" #"$HOME/.cache/wallpaper.${IMAGE_URL##*.}"
					cp "$wallpaper" "$wallpaper.ORG"
				}
			else
				dl_wallpaper() {
					trim="${API_CURL##*path}"
					echo "$trim" | cut -c 4-59 | xargs curl -sS --max-time 10 --retry 2 --retry-delay 3 --retry-max-time 20 -o "$wallpaper" #"$HOME/.cache/wallpaper.${IMAGE_URL##*.}"
				}
			fi
		else
			# if $API_CURL does not return at least one full path url
			txt="Error: No results - using hardcoded keyword set!"
			msg "$txt"
			notify "$txt"
			keywords=
			wh_images
		fi
	else
		txt="Curl failed"
		msg "$txt"
		exit 1	# if get_images EXIT_CODE is non-zero, then exit
	fi
}

handle_usr1() {
	if [ "$mode" == "dir" ]; then
		dir_images
	elif [ "$mode" == "pick" ]; then
		picker
	else
		wh_images
	fi
}

handle_usr2() {
	if [ "$mode" == "dir" ]; then
		dir_images
	else
		keywords=
		wh_images
	fi
}

handle_rtmin() {
	notify "$keywords"
}

handle_rtmax() {
	if ! [ -d "$walldir" ]; then
		mkdir "$walldir"
	fi
	cp "$wallpaper.ORG" "$walldir/$FILE"
	notify "Wallpaper: $FILE saved!"
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

# def_sets
# def vars

script="$(basename "${BASH_SOURCE[0]:-$0}")"

deps=( curl magick jq )
for dep in "${deps[@]}"; do
	if ! chk_dep "$dep"; then
		msg "Error: $script depends on $dep"
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
		* )		msg "Error: invalid option \"-$OPTARG\"!"
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
