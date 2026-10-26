# ─────────────────────────────────────────────────────────────────────────────
# bg_color.sh — dev-sandbox config: tint the terminal background during a session
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE
#   The smallest useful extension — a quick test that the pre/post-run hook
#   system works. On start it tints the terminal background; on exit it restores
#   the previous background.
#
# USAGE
#   dev-sandbox --config bg_color.sh
#   BG_COLOR='#003300' dev-sandbox --config bg_color.sh    # custom tint

BG_COLOR="${BG_COLOR:-}"            # empty = derive from the profile's COLOR
BG_RESET="${BG_RESET:-#1e1e2e}"     # restore color if the background query fails

# Profile COLOR → dark background shade. COLOR is the ANSI prompt code; this maps
# the standard (30–37) and bright (90–97) foreground codes to a dark shade of the
# same hue. A leading bold prefix ("1;32") is ignored, and a hex COLOR ("#rrggbb")
# is used as-is.
_bg_from_profile() {
    local c
    c="$(get_profile_var "$1" COLOR 2>/dev/null)"
    c="${c##*;}"                       # drop a bold/attr prefix like "1;" → "32"
    case "$c" in
        '#'*)       printf '%s' "$c" ;;   # COLOR already a hex value
        30|90)      printf '#1a1a1a' ;;   # black / grey
        31)         printf '#2a0808' ;;   # red
        91)         printf '#3a0a0a' ;;   # bright red
        32)         printf '#082a0e' ;;   # green
        92)         printf '#0a3a12' ;;   # bright green
        33)         printf '#2a2408' ;;   # yellow
        93)         printf '#3a3208' ;;   # bright yellow
        34)         printf '#081a2a' ;;   # blue
        94)         printf '#0a223a' ;;   # bright blue
        35)         printf '#240a2a' ;;   # magenta
        95)         printf '#320e3a' ;;   # bright magenta
        36)         printf '#082a2a' ;;   # cyan
        96)         printf '#0a3a3a' ;;   # bright cyan
        37|97)      printf '#262626' ;;   # white / light grey
        *)          printf '#001f3f' ;;   # default / none
    esac
}

_bg_query() {
    local old reply r g b
    old=$(stty -g </dev/tty 2>/dev/null) || return 0
    stty -echo -icanon min 0 time 2 </dev/tty 2>/dev/null
    printf '\033]11;?\033\\' >/dev/tty 2>/dev/null
    reply=$(dd bs=1 count=48 2>/dev/null </dev/tty)
    stty "$old" </dev/tty 2>/dev/null
    reply="${reply#*]11;}"; reply="${reply%%$'\033'*}"; reply="${reply%%$'\a'*}"
    case "$reply" in
        '#'*) printf '%s' "$reply" ;;
        rgb:*|rgba:*)                                    # rgb:RRRR/GGGG/BBBB → #RRGGBB
            reply="${reply#rgb:}"; reply="${reply#rgba:}"
            IFS=/ read -r r g b _ <<< "$reply"
            [[ -n "$r" && -n "$g" && -n "$b" ]] || return 0
            printf '#%s%s%s' "${r:0:2}" "${g:0:2}" "${b:0:2}" ;;
    esac
}

_bg_pre() {
    local tint="${BG_COLOR:-$(_bg_from_profile "$1")}"
    _BG_OLD=$(_bg_query)
    printf '\033]11;%s\033\\' "$tint" >/dev/tty 2>/dev/null || true
}

_bg_post() {
    printf '\033]11;%s\033\\' "${_BG_OLD:-$BG_RESET}" >/dev/tty 2>/dev/null || true
    _BG_OLD=""
}

PRE_RUN_HOOKS+=(_bg_pre)
POST_RUN_HOOKS+=(_bg_post)
