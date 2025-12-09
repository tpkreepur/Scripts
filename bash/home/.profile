#shellcheck shell=bash
# if running bash
if [ -n "$BASH_VERSION" ]; then
  # include .bashrc if it exists
  if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
  fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ]; then
  PATH="$HOME/bin:$PATH"
fi

# Ensure XDG Base Directory Specification is adhered to.
# Default directories (per XDG Base Directory Specification)
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export BASH_COMPLETION_USER_DIR="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions"

# Ensure the directories exist
[ -d "$XDG_CONFIG_HOME" ] || mkdir -p "$XDG_CONFIG_HOME"
[ -d "$XDG_CACHE_HOME" ] || mkdir -p "$XDG_CACHE_HOME"
[ -d "$XDG_DATA_HOME" ] || mkdir -p "$XDG_DATA_HOME"
[ -d "$XDG_STATE_HOME" ] || mkdir -p "$XDG_STATE_HOME"
[ -d "$BASH_COMPLETION_USER_DIR" ] || mkdir -p "$BASH_COMPLETION_USER_DIR"

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi

# Oh My Posh configuration
# Ensure oh-my-posh commahnd exists before running it
if command -v oh-my-posh &>/dev/null; then
  export POSH_CONFIG_DIR="$HOME/.config/oh-my-posh"
  export POSH_THEME_NAME="tokyo"

  # Ensure oh-my-posh config directory exists if it doesn't already
  [ -d "$POSH_CONFIG_DIR" ] || mkdir -p "$POSH_CONFIG_DIR"

  # Ensure oh-my-posh theme directory exists if it doesn't already
  [ -d "$POSH_CONFIG_DIR/themes" ] || mkdir -p "$POSH_CONFIG_DIR/themes"

  # Ensure oh-my-posh theme file exists if it doesn't already
  if [ ! -f "$POSH_CONFIG_DIR/themes/$POSH_THEME_NAME.omp.json" ]; then
    touch "$POSH_CONFIG_DIR/themes/$POSH_THEME_NAME.omp.json"
    # Download the theme from github
    curl -s "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/$POSH_THEME_NAME.omp.json" >"$POSH_CONFIG_DIR/themes/$POSH_THEME_NAME.omp.json"

    # Ensure the theme was downloaded successfully
    if [ ! -f "$POSH_CONFIG_DIR/themes/$POSH_THEME_NAME.omp.json" ]; then
      echo "Failed to download oh-my-posh theme: $POSH_THEME_NAME"
    fi
  fi

  # Init
  eval "$(oh-my-posh init bash --config "$POSH_CONFIG_DIR/themes/$POSH_THEME_NAME.omp.json")"
fi
