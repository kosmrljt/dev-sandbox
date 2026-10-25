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

BG_COLOR="${BG_COLOR:-#001f3f}"     # tint during the session
BG_RESET="${BG_RESET:-#1e1e2e}"     # restore color if the query can't read the background

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
    _BG_OLD=$(_bg_query)
    printf '\033]11;%s\033\\' "$BG_COLOR" >/dev/tty 2>/dev/null || true
}

_bg_post() {
    printf '\033]11;%s\033\\' "${_BG_OLD:-$BG_RESET}" >/dev/tty 2>/dev/null || true
    _BG_OLD=""
}

PRE_RUN_HOOKS+=(_bg_pre)
POST_RUN_HOOKS+=(_bg_post)
