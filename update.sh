#!/usr/bin/env bash
# Update everything on this machine (apt or dnf packages, snaps, Flatpak apps and
# Homebrew), with a bit of flair.
set -euo pipefail

# Colors follow the terminal's theme. With ACCENT=auto the accent is chosen the
# same way Ptyxis tints its own window: the palette's blue, or your desktop accent
# color (Settings > Appearance) for palettes that use it, such as Ubuntu and GNOME.
# Or force one of the theme's colors: 1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan.
ACCENT=auto

# Fedora, Fedora Atomic and other dnf systems: when the update needs a restart to
# finish, ask whether to restart now, waiting this many seconds for an answer. No
# answer means no. 0 turns the question off.
RESTART_COUNTDOWN=30

# Prints the desktop accent as "R;G;B" if the current Ptyxis palette follows it.
desktop_accent() {
    local palette
    if [[ -z ${PTYXIS_PROFILE:-} ]]; then return 0; fi
    palette=$(gsettings get "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$PTYXIS_PROFILE/" palette 2>/dev/null) || return 0
    palette=${palette//\'/}
    # Fedora doesn't install gresource, so the built-in palettes can't be read
    # there; these are the ones that follow the accent (gnome is Fedora's default).
    { cat ~/.local/share/org.gnome.Ptyxis/palettes/"$palette".palette 2>/dev/null ||
        gresource extract "$(command -v ptyxis)" "/org/gnome/Ptyxis/palettes/$palette.palette" 2>/dev/null ||
        case $palette in gnome|gnome-high-contrast|'GNOME Legacy') echo 'UseSystemAccent=true' ;; esac; } |
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

# Your own Flatpak apps belong to you rather than root, so they're updated as
# you: the user who started this with sudo.
USER_NAME=${SUDO_USER:-}
USER_HOME=""
if [[ -n $USER_NAME && $USER_NAME != root ]]; then
    USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6 || true)
fi

# Output is hidden behind a spinner, so apt must never stop and wait for input.
# If you've edited a package's config file, your version is kept.
export DEBIAN_FRONTEND=noninteractive

# Each step's output is read to sum up what it did, so ask for it in English.
# UTF-8 also makes bash count the banner's characters correctly.
export LC_ALL=C.UTF-8

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
INTRO_SHOWN=0
INTERRUPTED=0
WIDE_WARNINGS=0
BREW_REJECTED=""
FEDORA=0

# The animations run alongside the update, so they avoid starting new processes
# (each one costs several milliseconds of CPU) and use bash built-ins instead.

# A pipe that never gets any data: reading it with a timeout is a sleep that
# doesn't need to start a `sleep` process each time.
exec {NAP_FD}<> <(:)
nap() {
    read -r -t "$1" -u "$NAP_FD" || true
    check_interrupt
}

cleanup() {
    if (( FANCY )); then printf '\e[?25h'; fi   # bring the cursor back
}

# stop_tree <pid>: stops a process and what it started. Package managers are
# only asked to stop, and left to stop their own work: dnf finishes the
# transaction it's in, and apt the dpkg run it's in, setup scripts and kernel
# installs included. Anything else (Homebrew, in its own session where Ctrl+C
# can't reach it, or a wrapper like dbus-run-session) is stopped along with
# everything it started. runuser ends by itself once the command it runs does (if
# signaled, it would force-kill that command after 2s), and tee once its input ends.
stop_tree() {
    local child
    case $(ps -o comm= -p "$1" 2>/dev/null) in
        apt-get)
            # apt's way of being asked to stop is Ctrl+C, which it only handles
            # while dpkg is installing; at any other time, TERM is safe.
            if catches_ctrl_c "$1"; then kill -INT "$1" 2>/dev/null || true
            else kill "$1" 2>/dev/null || true; fi
            return ;;
        dpkg|dnf|dnf5|dnf-3|rpm-ostree|snap|flatpak) kill "$1" 2>/dev/null || true; return ;;
        runuser) for child in $(pgrep -P "$1" || true); do stop_tree "$child"; done; return ;;
        tee) return ;;
    esac
    for child in $(pgrep -P "$1" || true); do stop_tree "$child"; done
    kill "$1" 2>/dev/null || true
}

# catches_ctrl_c <pid>: is that process handling SIGINT right now?
catches_ctrl_c() {
    local key value
    while read -r key value; do
        if [[ $key == SigCgt: ]]; then (( 16#$value & 2 )); return; fi
    done 2>/dev/null < "/proc/$1/status"
    return 1
}

# Ctrl+C (or TERM) is only noted here. Bash can cut a signal handler short when
# a background step finishes while it runs, so the actual stopping is done by
# check_interrupt, which runs between spinner frames and between steps.
on_interrupt() { INTERRUPTED=1; }

check_interrupt() {
    if (( ! INTERRUPTED )); then return 0; fi
    trap '' INT TERM   # a second Ctrl+C mustn't interrupt the cleanup
    printf '\n\n  %sInterrupted.%s' "$RED" "$RESET"
    if [[ -n $CHILD ]]; then
        # CHILD is this script's own subshell for the step: stop what it's running,
        # and the subshell ends once that has, so waiting for it waits for the step.
        local child
        if kill -0 "$CHILD" 2>/dev/null; then printf ' Letting the current step stop safely...'; fi
        # Without the spinner, the step's last output follows on screen: give it its own lines.
        if (( ! FANCY )); then printf '\n'; fi
        for child in $(pgrep -P "$CHILD" || true); do stop_tree "$child"; done
        wait "$CHILD" 2>/dev/null || true
    fi
    if (( FANCY )); then printf ' '; else printf '\n  '; fi
    printf 'Logs are in %s\n' "$LOG_DIR"
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
    check_interrupt
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
        STEP_WIDTH=$(tput cols 2>/dev/null) || STEP_WIDTH=80
        STEP_WIDTH=$(( STEP_WIDTH - 40 ))
        STEP_WIDTH=$(( STEP_WIDTH > 0 ? STEP_WIDTH : 0 ))
    else
        printf '==> %s\n' "$STEP_LABEL"
        # In the background too, so that waiting for it can be cut short by Ctrl+C.
        # (Its own stderr is hidden only to keep bash's job notices out of the way.)
        ( set +e; "$@" </dev/null 2>&1 | tee "$LAST_LOG"; exit "${PIPESTATUS[0]}" ) 2>/dev/null &
        CHILD=$!
        STEP_STATUS=0
        wait "$CHILD" || STEP_STATUS=$?
        check_interrupt
        CHILD=""
    fi
}

# Shows a spinner with the latest line of output until the step is done,
# then reports how it went.
finish_step() {
    local frame=0 line="" chunk="" partial="" clock warning

    if (( FANCY )); then
        while :; do
            # Catch up on new output, keeping the last full line and any warnings.
            # apt says "W:" or "E:". Flatpak and Homebrew say "Warning:", and
            # Flatpak "Unable to update" for apps it had to skip; those are only
            # shown for their steps (WIDE_WARNINGS=1), as package setup scripts
            # print routine "Warning:" lines during apt and dnf upgrades.
            while IFS= read -r -u "$LOG_FD" chunk; do
                line=$partial$chunk partial=""
                if [[ $line == [WE]:\ * ]] ||
                    { (( WIDE_WARNINGS )) && [[ $line == Warning:\ * || $line == "Unable to update "* ]]; }; then
                    STEP_WARNINGS+=("$line")
                fi
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
            check_interrupt
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

# The intro plays once, before anything else is shown.
show_intro() {
    if (( FANCY && ! INTRO_SHOWN )); then
        INTRO_SHOWN=1
        printf '\e[?25l'   # hide the cursor while animating
        intro
    fi
}

run_step() {
    start_step "$@"
    show_intro   # the first step to run carries on in the background meanwhile
    finish_step
}

# skipped "Label" "reason": notes a step that didn't run, and why.
skipped() {
    show_intro
    printf '  %s- %-26s skipped, %s%s\n' "$DIM" "$1" "$2" "$RESET"
}

# have <command>: is this command installed?
have() { command -v "$1" >/dev/null 2>&1; }

# as_user command [args...]: runs a command as you instead of root, in a clean
# environment, for things that belong to you.
as_user() {
    runuser -u "$USER_NAME" -- env -i HOME="$USER_HOME" USER="$USER_NAME" LOGNAME="$USER_NAME" \
        SHELL=/bin/bash LC_ALL=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin "$@"
}

# dnf5 buffers what it writes to a file, which can split its summary lines up in
# the log; stdbuf makes it write whole lines as it goes.
line_buffered() {
    if have stdbuf; then stdbuf -oL "$@"; else "$@"; fi
}

# Fedora Atomic desktops (Silverblue and friends) update a whole system image,
# which takes over at the next boot. rpm-ostree exits 77 when there's nothing new.
upgrade_system_image() {
    local status=0
    rpm-ostree upgrade --unchanged-exit-77 || status=$?
    case $status in
        77) echo "Already up to date" ;;
        0)  echo "New system image ready; it starts after a reboot" ;;
        *)  return "$status" ;;
    esac
}

# dnf5 says " Upgrading:  12 packages" and dnf4 "Upgrade  12 Packages". Updates
# dnf had to hold back (broken dependencies, conflicts) are listed under
# "Skipping packages with ..." and counted as Skipping/Skip.
dnf_summary() {
    awk '
        /^ ?(Upgrading:|Upgrade) +[0-9]+ [Pp]ackages? *$/  { upgraded = $2 }
        /^ ?(Installing:|Install) +[0-9]+ [Pp]ackages? *$/ { added = $2 }
        /^ ?(Removing:|Remove) +[0-9]+ [Pp]ackages? *$/    { removed = $2 }
        /^ ?(Skipping:|Skip) +[0-9]+ [Pp]ackages? *$/      { skipped = $2 }
        /^Skipping packages with /                         { held = 1 }
        END {
            if (upgraded + added + removed == 0) out = "Nothing new to install"
            else out = sprintf("%d upgraded, %d newly installed, %d removed", upgraded, added, removed)
            if (skipped > 0) out = out sprintf("; %d held back", skipped)
            else if (held) out = out "; some updates held back"
            else if (upgraded + added + removed == 0) out = "Already up to date"
            print out
        }
    ' "$1"
}

# Flatpak needs a D-Bus session for some updates (Fedora's own Flatpak remote
# always does), and there's none under sudo, so give it a private one when
# possible. Otherwise hide the desktop's DISPLAY so it doesn't try to start one there.
# Flatpak removes runtimes that reached end of life once no app installed for
# everyone uses them; running as root, it can't see your own apps. With no apps
# installed for everyone, only runtimes, those are there for your apps, so
# `--no-deps` keeps them. Otherwise one your apps still use is installed again
# for you when your apps are updated.
update_flatpak_system() {
    local args=(update --system --noninteractive)
    if ! compgen -G '/var/lib/flatpak/app/*' >/dev/null; then args+=(--no-deps); fi
    if have dbus-run-session; then
        dbus-run-session -- flatpak "${args[@]}"
    else
        env -u DISPLAY -u XAUTHORITY flatpak "${args[@]}"
    fi
}

# Your own Flatpak apps are updated as you, through your desktop's D-Bus session
# if you're logged in, or a private one otherwise.
update_flatpak_user() {
    local uid
    uid=$(id -u "$USER_NAME")
    if [[ -S /run/user/$uid/bus ]]; then
        as_user env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            flatpak update --user --noninteractive
    elif have dbus-run-session; then
        as_user dbus-run-session -- flatpak update --user --noninteractive
    else
        as_user flatpak update --user --noninteractive
    fi
}

# Flatpak prints one "Updating app/..." (or runtime/...) line per change.
flatpak_summary() {
    awk '
        /^Updating (app|runtime)\//     { updated++ }
        /^Installing (app|runtime)\//   { added++ }
        /^Uninstalling (app|runtime)\// { removed++ }
        END {
            if (updated + added + removed == 0) print "Already up to date"
            else printf "%d updated, %d newly installed, %d removed\n", updated, added, removed
        }
    ' "$1"
}

# Homebrew lives in /home/linuxbrew/.linuxbrew (or ~/.linuxbrew on old installs).
# Sets BREW, plus BREW_OWNER and BREW_HOME: whoever owns that folder, which is who
# brew must run as. It's never run as root, not even to ask where it lives.
# The folder is resolved once, and the one it sits in must belong to root or the
# same owner, so nobody else can swap in a different Homebrew. One in your home
# folder must also be yours.
# If a Homebrew is found but turned down, BREW_REJECTED says why.
find_brew() {
    local candidate prefix parent parent_owner
    for candidate in /home/linuxbrew/.linuxbrew ${USER_HOME:+"$USER_HOME/.linuxbrew"}; do
        prefix=$(realpath -e -- "$candidate" 2>/dev/null) || continue
        if [[ ! -x $prefix/bin/brew ]]; then continue; fi
        BREW_OWNER=$(stat -c %U -- "$prefix")
        parent=${prefix%/*}
        parent_owner=$(stat -c %U -- "${parent:-/}")
        if [[ -n $USER_HOME && $candidate == "$USER_HOME"/* && $BREW_OWNER != "$USER_NAME" ]]; then
            BREW_REJECTED="the one in your home folder isn't yours"; continue
        fi
        if [[ $parent_owner != root && $parent_owner != "$BREW_OWNER" ]]; then
            BREW_REJECTED="the folder it's in belongs to someone else"; continue
        fi
        BREW_HOME=$(getent passwd "$BREW_OWNER" | cut -d: -f6 || true)
        if [[ $BREW_OWNER == root || -z $BREW_HOME ]]; then
            BREW_REJECTED="its folder doesn't belong to a regular user"; continue
        fi
        BREW=$prefix/bin/brew
        return 0
    done
    return 1
}

# as_brew_owner <brew command>: runs brew as its owner, in a clean environment,
# from their home folder. setsid detaches it from the terminal, so anything that
# asks for a sudo password fails instead of waiting behind the spinner.
as_brew_owner() {
    # The single quotes are deliberate: $HOME and $@ belong to the inner shell.
    # shellcheck disable=SC2016
    setsid -w runuser -u "$BREW_OWNER" -- env -i HOME="$BREW_HOME" USER="$BREW_OWNER" LOGNAME="$BREW_OWNER" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C.UTF-8 \
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_SUDO=1 \
        HOMEBREW_NO_COLOR=1 HOMEBREW_NO_EMOJI=1 \
        bash -c 'cd -- "$HOME" && exec "$@"' -- "$BREW" "$@"
}

# brew prints "==> Upgrading <name>" for each package it upgrades.
brew_summary() {
    awk '
        /^==> Upgrading [^ ]+$/ { names = names sep $3; sep = ", " }
        END { print (names == "" ? "Already up to date" : "Upgraded: " names) }
    ' "$1"
}

# rpm-based systems have no reboot-required file. Like `dnf needs-restarting`,
# a reboot is needed if a core package (dnf's list) was installed since boot.
rpm_needs_reboot() {
    local boot=0 key value installed
    while read -r key value _; do
        if [[ $key == btime ]]; then boot=$value; fi
    done < /proc/stat
    for installed in $(rpm -q --qf '%{INSTALLTIME}\n' kernel kernel-core kernel-PAE kernel-rt kernel-smp \
            kernel-xen linux-firmware microcode_ctl dbus glibc hal systemd udev gnutls openssl-libs \
            dbus-broker dbus-daemon 2>/dev/null || true); do
        if [[ $installed =~ ^[0-9]+$ ]] && (( installed > boot )); then return 0; fi
    done
    return 1
}

# ask_restart: asks whether to restart, counting down from RESTART_COUNTDOWN.
# Only y or Y followed by Enter means yes, so a command you're already typing for
# your shell can't answer it by accident. Anything else, Ctrl+C, or no answer
# before the countdown ends means no. What you type is shown after the question.
ask_restart() {
    local deadline=$(( SECONDS + RESTART_COUNTDOWN )) answer="" key entered=0
    # Throw away anything typed during the update.
    while read -r -s -n 1 -t 0.05 _; do :; done
    printf '\e[?25h'   # show the cursor while waiting for an answer
    echo
    while (( SECONDS < deadline && ! INTERRUPTED )); do
        printf '\r\e[K  %sRestart now?%s [y/N] %s(no in %ds)%s %s' \
            "$BOLD" "$RESET" "$DIM" $(( deadline - SECONDS )) "$RESET" "$answer"
        if ! read -r -s -n 1 -t 1 key; then continue; fi   # no key this second
        case $key in
            '')            entered=1; break ;;              # Enter
            $'\x7f'|$'\b') answer=${answer%?} ;;           # Backspace
            *)             answer+=$key ;;
        esac
    done
    if (( entered && ! INTERRUPTED )) && [[ $answer == [yY] ]]; then
        printf '\r\e[K  Restarting...\n'
        return 0
    fi
    printf '\r\e[K  %sNot restarting.%s\n' "$DIM" "$RESET"
    return 1
}

reboot_needed() {
    if [[ -f /var/run/reboot-required || -e /run/ostree/staged-deployment ]]; then return 0; fi
    have rpm && have dnf && rpm_needs_reboot
}

TOTAL_START=$SECONDS

# The system's own packages.
if [[ -e /run/ostree-booted ]] && have rpm-ostree; then
    FEDORA=1
    run_step "Upgrading the system image" upgrade_system_image
    detail "$(tail -n 1 "$LAST_LOG")"
elif have apt-get && [[ -e /etc/debian_version ]]; then   # Fedora can install apt too
    run_step "Refreshing package lists" apt-get update
    run_step "Upgrading packages" apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
    summary=$(grep -m1 -E '^[0-9]+ upgraded' "$LAST_LOG") || true
    detail "${summary%.}"
elif have dnf; then
    FEDORA=1
    run_step "Refreshing package lists" line_buffered dnf -y makecache --refresh
    run_step "Upgrading packages" line_buffered dnf -y upgrade
    detail "$(dnf_summary "$LAST_LOG")"
else
    skipped "Upgrading packages" "no supported package manager (apt on Debian or Ubuntu, or dnf)"
fi

if have snap; then
    run_step "Refreshing snaps" snap refresh
    refreshed=$(awk '/ refreshed$/ { printf "%s%s", sep, $1; sep = ", " }' "$LAST_LOG") || true
    if [[ -n $refreshed ]]; then
        detail "Refreshed: $refreshed"
    else
        detail "$(tail -n 1 "$LAST_LOG")"
    fi
fi

# Flatpak apps installed for everyone, then any you installed just for yourself.
# (Your own apps can run on runtimes installed for everyone, so those count too.)
if have flatpak; then
    if compgen -G '/var/lib/flatpak/app/*' >/dev/null || compgen -G '/var/lib/flatpak/runtime/*' >/dev/null; then
        WIDE_WARNINGS=1 run_step "Updating Flatpak apps" update_flatpak_system
        detail "$(flatpak_summary "$LAST_LOG")"
    fi
    if [[ -n $USER_HOME ]] && compgen -G "$USER_HOME/.local/share/flatpak/app/*" >/dev/null; then
        WIDE_WARNINGS=1 run_step "Updating your Flatpak apps" update_flatpak_user
        detail "$(flatpak_summary "$LAST_LOG")"
    fi
fi

if find_brew; then
    WIDE_WARNINGS=1 run_step "Updating Homebrew" as_brew_owner update
    WIDE_WARNINGS=1 run_step "Upgrading brew packages" as_brew_owner upgrade
    detail "$(brew_summary "$LAST_LOG")"
elif [[ -n $BREW_REJECTED ]]; then
    skipped "Updating Homebrew" "$BREW_REJECTED"
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
elif have tailscale; then
    skipped "Restarting Tailscale" "it isn't running"
fi
check_interrupt

echo
restart_needed=0
if reboot_needed; then
    restart_needed=1
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

# On Fedora, when a restart is needed, offer one (only when someone is at the
# terminal to answer).
restart=0
if (( FEDORA && restart_needed && RESTART_COUNTDOWN > 0 )) && [[ -t 0 && -t 1 ]]; then
    if ask_restart; then restart=1; fi
fi

rm -rf "$LOG_DIR"
if (( restart && ! INTERRUPTED )); then systemctl reboot; fi   # Ctrl+C at any point means no
