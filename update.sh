#!/usr/bin/env bash
# Update apt packages, then refresh snaps, with a bit of flair.
set -euo pipefail

# Colors follow the terminal's theme. With ACCENT=auto the accent is chosen the
# same way Ptyxis tints its own window: the palette's blue, or your desktop accent
# color (Settings > Appearance) for palettes that use it, such as Ubuntu and GNOME.
# Or force one of the theme's colors: 1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan.
ACCENT=auto

# Prints the desktop accent as "R;G;B" if the current Ptyxis palette follows it.
desktop_accent() {
    local palette
    if [[ -z ${PTYXIS_PROFILE:-} ]]; then return 0; fi
    palette=$(gsettings get "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$PTYXIS_PROFILE/" palette 2>/dev/null) || return 0
    palette=${palette//\'/}
    { cat ~/.local/share/org.gnome.Ptyxis/palettes/"$palette".palette 2>/dev/null ||
        gresource extract "$(command -v ptyxis)" "/org/gnome/Ptyxis/palettes/$palette.palette" 2>/dev/null; } |
        grep -ix 'UseSystemAccent=true' >/dev/null || return 0
    # The same shades libadwaita uses for each accent.
    case $(gsettings get org.gnome.desktop.interface accent-color 2>/dev/null) in
        "'blue'")   echo '53;132;228' ;;
        "'teal'")   echo '33;144;164' ;;
        "'green'")  echo '58;148;74' ;;
        "'yellow'") echo '200;136;0' ;;
        "'orange'") echo '237;91;0' ;;
        "'red'")    echo '230;45;66' ;;
        "'pink'")   echo '213;97;153' ;;
        "'purple'") echo '145;65;172' ;;
        "'slate'")  echo '111;131;150' ;;
    esac
}

# Re-run as root up front so the password is only asked for once.
# Terminal settings are only visible as you, so look up the accent first.
if (( EUID != 0 )); then
    if [[ $ACCENT == auto ]]; then ACCENT=$(desktop_accent); fi
    exec sudo -- env UPDATE_ACCENT="$ACCENT" bash "$0" "$@"
fi
ACCENT=${UPDATE_ACCENT:-$ACCENT}
if [[ -z $ACCENT || $ACCENT == auto ]]; then ACCENT=4; fi

# Output is hidden behind a spinner, so apt must never stop and wait for input.
# If you've edited a package's config file, your version is kept.
export DEBIAN_FRONTEND=noninteractive

# Make bash count multi-byte characters (the banner art) correctly.
LC_CTYPE=C.UTF-8

# Lighten "R;G;B" 40% of the way towards white.
lighten() {
    local r g b
    IFS=';' read -r r g b <<< "$1"
    printf '%d;%d;%d' $(( r + (255 - r) * 2 / 5 )) $(( g + (255 - g) * 2 / 5 )) $(( b + (255 - b) * 2 / 5 ))
}

# Only animate when writing to a real terminal (not cron, not a pipe).
if [[ -t 1 ]]; then
    FANCY=1
    RESET=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m'
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
    if [[ $ACCENT == *';'* ]]; then     # an exact color from the desktop accent
        THEME=$'\e[0;38;2;'"${ACCENT}m"
        BRIGHT=$'\e[0;38;2;'"$(lighten "$ACCENT")m"
    else                                # one of the terminal palette's colors
        THEME=$'\e[0;3'"${ACCENT}m"
        BRIGHT=$'\e[0;9'"${ACCENT}m"
    fi
    SHADOW=$'\e[0;2m'                   # faded text color: gray on any background
    # Highlight that sweeps across the banner, center → edge:
    # bold text color, plain text color, then a brighter accent.
    SHINE=($'\e[0;1m' $'\e[0m' "$BRIGHT")
else
    FANCY=0
    RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" THEME=""
fi

SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
BANNER=(
    '██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗'
    '██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝'
    '██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗  '
    '██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝  '
    '╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗'
    ' ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝'
)

LOG_DIR=$(mktemp -d /tmp/update.XXXXXX)
STEP=0
CHILD=""

# The animations run alongside the update, so they avoid starting new processes
# (each one costs several milliseconds of CPU) and use bash built-ins instead.

# A pipe that never gets any data: reading it with a timeout is a sleep that
# doesn't need to start a `sleep` process each time.
exec {NAP_FD}<> <(:)
nap() { read -r -t "$1" -u "$NAP_FD" || true; }

cleanup() {
    if (( FANCY )); then printf '\e[?25h'; fi   # bring the cursor back
}

on_interrupt() {
    if [[ -n $CHILD ]]; then
        pkill -P "$CHILD" 2>/dev/null || true   # the running command
        kill "$CHILD" 2>/dev/null || true       # and the wrapper around it
    fi
    printf '\n\n  %sInterrupted.%s Logs are in %s\n' "$RED" "$RESET" "$LOG_DIR"
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# elapsed <var> <start>: stores the time since <start> in <var> as mm:ss.
elapsed() {
    local s=$(( SECONDS - $2 ))
    printf -v "$1" '%02d:%02d' $(( s / 60 )) $(( s % 60 ))
}

# Split the banner into single characters once, so drawing each frame is cheap.
split_banner() {
    local line i
    BANNER_CHARS=()
    for line in "${BANNER[@]}"; do
        for (( i = 0; i < ${#line}; i++ )); do BANNER_CHARS+=("${line:i:1}"); done
    done
}

# banner_cells <row> <from> <to> <column>: colors that row's characters from
# <from> to <to>, with a slanted highlight at <column>, and appends them to $out.
banner_cells() {
    local row=$1 from=$2 to=$3 pos=$4 width=${#BANNER[0]} i d ch color prev=""
    for (( i = from; i <= to; i++ )); do
        ch=${BANNER_CHARS[row * width + i]}
        d=$(( i + row - pos ))
        d=$(( d < 0 ? -d : d ))
        if [[ $ch != █ ]]; then
            color=$SHADOW
        elif (( d < ${#SHINE[@]} )); then
            color=${SHINE[d]}
        else
            color=$THEME
        fi
        if [[ $color != "$prev" ]]; then
            out+=$color
            prev=$color
        fi
        out+=$ch
    done
}

# Draw the banner, then sweep a highlight across it once.
intro() {
    local rows=${#BANNER[@]} width=${#BANNER[0]} row pos from to out=""
    split_banner
    for (( row = 0; row < rows; row++ )); do
        out+="  "
        banner_cells "$row" 0 $(( width - 1 )) -99
        out+="$RESET"$'\n'
    done
    printf '\n%s' "$out"

    # Each frame only redraws the few characters the highlight is on now or was
    # on in the last frame: up to the top row, then down a row at a time,
    # jumping to the right column on each.
    for (( pos = -4; pos <= width + 10; pos += 2 )); do
        nap 0.02
        out=$'\e['"${rows}A"
        for (( row = 0; row < rows; row++ )); do
            from=$(( pos - row - 4 )) to=$(( pos - row + 2 ))
            from=$(( from < 0 ? 0 : from )) to=$(( to < width ? to : width - 1 ))
            if (( from <= to )); then
                out+=$'\e['"$(( from + 3 ))G"
                banner_cells "$row" "$from" "$to" "$pos"
            fi
            out+=$'\e[B'
        done
        printf '%s%s\r' "$out" "$RESET"
    done
    # shellcheck source=/dev/null
    printf '  %s%s · %s · %(%a %d %b %H:%M)T%s\n\n' "$DIM" \
        "$(. /etc/os-release && echo "$PRETTY_NAME")" "$HOSTNAME" -1 "$RESET"
}

# Print text one character at a time, typewriter style.
type_out() {
    local text=$1 i
    printf '%s%s' "$THEME" "$BOLD"
    for (( i = 0; i < ${#text}; i++ )); do
        printf '%s' "${text:i:1}"
        nap 0.02
    done
    printf '%s\n' "$RESET"
}

detail() {
    printf '    %s↳ %s%s\n' "$DIM" "$1" "$RESET"
}

# start_step "Label" command [args...]
# Starts the command with its full output going to $LAST_LOG. With the spinner on,
# it runs in the background so the intro can play while it works.
start_step() {
    STEP_LABEL=$1; shift
    STEP_START=$SECONDS
    STEP=$(( STEP + 1 ))
    LAST_LOG="$LOG_DIR/step$STEP.log"
    STEP_WARNINGS=()
    : > "$LAST_LOG"

    if (( FANCY )); then
        # When the command finishes, its exit status comes back down this pipe,
        # so the spinner can wait on that instead of checking on it.
        exec {DONE_FD}< <(set +e; "$@" </dev/null >"$LAST_LOG" 2>&1; echo "$?")
        CHILD=$!
        exec {LOG_FD}<"$LAST_LOG"
        STEP_STATUS=""
        STEP_WIDTH=$(( $(tput cols 2>/dev/null || echo 80) - 40 ))
        STEP_WIDTH=$(( STEP_WIDTH > 0 ? STEP_WIDTH : 0 ))
    else
        printf '==> %s\n' "$STEP_LABEL"
        STEP_STATUS=0
        "$@" </dev/null 2>&1 | tee "$LAST_LOG" || STEP_STATUS=$?
    fi
}

# Shows a spinner with the latest line of output until the step is done,
# then reports how it went.
finish_step() {
    local frame=0 line="" chunk="" partial="" clock warning

    if (( FANCY )); then
        while :; do
            # Catch up on new output, keeping the last full line and any warnings
            # (apt reports problems on "W:" / "E:" lines).
            while IFS= read -r -u "$LOG_FD" chunk; do
                line=$partial$chunk partial=""
                if [[ $line == [WE]:\ * ]]; then STEP_WARNINGS+=("$line"); fi
            done
            partial+=$chunk
            if [[ -n $STEP_STATUS ]]; then break; fi

            elapsed clock "$STEP_START"
            line=${line//$'\r'/}
            printf '\r\e[K  %s%s%s %s%-26s%s %s  %s%s%s' \
                "$THEME" "${SPINNER[frame % ${#SPINNER[@]}]}" "$RESET" \
                "$BOLD" "$STEP_LABEL" "$RESET" "$clock" "$DIM" "${line:0:STEP_WIDTH}" "$RESET"
            frame=$(( frame + 1 ))

            # This is also the delay between frames: it waits up to 0.08s, but
            # returns as soon as the step finishes and sends its exit status.
            IFS= read -r -t 0.08 -u "$DONE_FD" STEP_STATUS || {
                if (( $? <= 128 )); then STEP_STATUS=1; fi   # closed without a status
            }
        done
        exec {DONE_FD}<&- {LOG_FD}<&-
        CHILD=""
        printf '\r\e[K'
    fi

    elapsed clock "$STEP_START"
    if (( STEP_STATUS != 0 )); then
        printf '  %s✗%s %s%-26s%s %s\n\n' "$RED" "$RESET" "$BOLD" "$STEP_LABEL" "$RESET" "$clock"
        printf '  %sIt failed with exit code %d. Last lines of output:%s\n' "$RED" "$STEP_STATUS" "$RESET"
        tail -n 15 "$LAST_LOG" | sed 's/^/    /'
        printf '\n  Full log: %s\n' "$LAST_LOG"
        exit "$STEP_STATUS"
    fi

    printf '  %s✓%s %s%-26s%s %s\n' "$GREEN" "$RESET" "$BOLD" "$STEP_LABEL" "$RESET" "$clock"
    for warning in "${STEP_WARNINGS[@]}"; do
        printf '    %s%s%s\n' "$YELLOW" "$warning" "$RESET"
    done
}

run_step() {
    start_step "$@"
    finish_step
}

TOTAL_START=$SECONDS

start_step "Refreshing package lists" apt-get update
if (( FANCY )); then
    printf '\e[?25l'   # hide the cursor while animating
    intro              # plays while the package lists download
fi
finish_step

run_step "Upgrading packages" apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
summary=$(grep -m1 -E '^[0-9]+ upgraded' "$LAST_LOG" || true)
detail "${summary%.}"

run_step "Refreshing snaps" snap refresh
refreshed=$(awk '/ refreshed$/ { printf "%s%s", sep, $1; sep = ", " }' "$LAST_LOG")
if [[ -n $refreshed ]]; then
    detail "Refreshed: $refreshed"
else
    detail "$(tail -n 1 "$LAST_LOG")"
fi

# Restarts Tailscale, then waits until it's connected again and prints its IP.
restart_tailscale() {
    systemctl restart tailscaled &&
        tailscale wait --timeout 20s &&
        tailscale ip -1
}

# Tailscale goes last: if you're connected through it, the restart can briefly
# drop the connection, and by then everything else is finished. It's only
# restarted if it's running, so if you've stopped it on purpose it stays stopped.
if systemctl is-active --quiet tailscaled; then
    run_step "Restarting Tailscale" restart_tailscale
    detail "Connected again as $(tail -n 1 "$LAST_LOG")"
elif command -v tailscale >/dev/null; then
    printf "  %s- %-26s skipped, it isn't running%s\n" "$DIM" "Restarting Tailscale" "$RESET"
fi

echo
if [[ -f /var/run/reboot-required ]]; then
    printf '  %s! A reboot is required to finish the update.%s\n' "$YELLOW" "$RESET"
fi
elapsed total "$TOTAL_START"
# $total is set by elapsed (through printf -v), which shellcheck can't see.
# shellcheck disable=SC2154
if (( FANCY )); then
    type_out "  All done in $total"
else
    echo "All done in $total."
fi

rm -rf "$LOG_DIR"
