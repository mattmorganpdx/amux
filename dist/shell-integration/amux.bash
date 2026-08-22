# amux shell integration for bash: OSC 133 semantic prompts.
#
# Marks where the prompt ends and command output begins, so amux knows exactly
# what a command printed instead of guessing from the shape of the screen.
# Without this, `surface.run` extracts output by matching the echoed command and
# looking for something that resembles a prompt, which breaks on wrapped lines,
# on scrolling, and on any prompt that does not end in a familiar character.
#
# Install:  eval "$(amux-cli shell-init bash)"   in ~/.bashrc
#
# Emits nothing on its own; it only wraps the prompt you already have.

# Interactive shells only: a script has no prompt to mark, and writing escape
# sequences into its output would corrupt it.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

# Sourcing twice would wrap the prompt twice and emit every mark in duplicate.
if [ -n "${AMUX_SHELL_INTEGRATION:-}" ]; then
    return 0
fi
AMUX_SHELL_INTEGRATION=1

# D reports the status of the command that just finished; A opens the new
# prompt. PROMPT_COMMAND runs between the two, which is exactly that boundary.
__amux_prompt_command() {
    local status=$?
    printf '\033]133;D;%s\007\033]133;A\007' "$status"
    return $status
}

if [ -n "${PROMPT_COMMAND:-}" ]; then
    # Keep whatever was already there. Ours goes first so the reported status is
    # the command's, not that of something another hook ran.
    PROMPT_COMMAND="__amux_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
else
    PROMPT_COMMAND="__amux_prompt_command"
fi

# B closes the prompt: everything after it is what the user types. Wrapped in
# \[ \] so readline knows these bytes take no space -- without that, the prompt
# width is miscounted and long lines overwrite themselves.
PS1="${PS1}\[\033]133;B\007\]"

# C says the command is about to run, so what follows is output. PS0 is printed
# after the line is read and before it executes, which is that moment exactly --
# no DEBUG trap needed.
PS0="${PS0:-}\033]133;C\007"
