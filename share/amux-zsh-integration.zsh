#!/usr/bin/env zsh
# amux zsh shell integration
# Source this file from your .zshrc:
#   [ -n "$AMUX_WORKSPACE_ID" ] && source /path/to/amux-zsh-integration.zsh
#
# Reports git branch and dirty status to amux sidebar via V2 JSON-RPC.

# Only activate inside a amux terminal
[[ -z "$AMUX_WORKSPACE_ID" ]] && return
[[ -z "$AMUX_SOCKET_PATH" ]] && AMUX_SOCKET_PATH="/tmp/amux.sock"

typeset -g _amux_last_branch=""
typeset -g _amux_last_dirty=""

# Send a V2 JSON-RPC message to amux socket.
_amux_send() {
    local method="$1" params="$2"
    local id=$((RANDOM % 10000))
    printf '{"id":%d,"method":"%s","params":%s}\n' "$id" "$method" "$params" \
        | socat - UNIX-CONNECT:"$AMUX_SOCKET_PATH" 2>/dev/null &
}

# Called before each prompt — reports git info to amux.
_amux_precmd() {
    local ws_id="$AMUX_WORKSPACE_ID"
    [[ -z "$ws_id" ]] && return

    # Report git branch + dirty status
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch
        branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        local dirty="false"
        [[ -n "$(git status --porcelain -uno 2>/dev/null | head -1)" ]] && dirty="true"

        # Only send if changed
        if [[ "$branch" != "$_amux_last_branch" || "$dirty" != "$_amux_last_dirty" ]]; then
            _amux_last_branch="$branch"
            _amux_last_dirty="$dirty"
            _amux_send "workspace.report_git" "{\"id\":$ws_id,\"branch\":\"$branch\",\"dirty\":$dirty}"
        fi
    elif [[ -n "$_amux_last_branch" ]]; then
        # Left a git repo — clear branch
        _amux_last_branch=""
        _amux_last_dirty=""
        _amux_send "workspace.report_git" "{\"id\":$ws_id,\"branch\":\"\",\"dirty\":false}"
    fi
}

# Install precmd hook
autoload -Uz add-zsh-hook
add-zsh-hook precmd _amux_precmd
