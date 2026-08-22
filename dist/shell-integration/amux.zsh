# amux shell integration for zsh: OSC 133 semantic prompts.
#
# See amux.bash for what this buys. Install:
#   eval "$(amux-cli shell-init zsh)"   in ~/.zshrc

[[ -o interactive ]] || return 0
[[ -z "${AMUX_SHELL_INTEGRATION:-}" ]] || return 0
AMUX_SHELL_INTEGRATION=1

# zsh has hooks for both boundaries, so no prompt string has to be rewritten:
# precmd runs before each prompt, preexec after the line is read.
__amux_precmd() {
    local status=$?
    print -n "\033]133;D;${status}\033\\\033]133;A\033\\"
}

__amux_preexec() {
    print -n "\033]133;C\033\\"
}

# %{ %} marks the bytes as zero-width so the prompt's length stays correct.
PS1="${PS1}%{$(print -n "\033]133;B\033\\")%}"

autoload -Uz add-zsh-hook
add-zsh-hook precmd __amux_precmd
add-zsh-hook preexec __amux_preexec
