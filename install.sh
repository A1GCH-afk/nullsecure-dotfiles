#!/usr/bin/env bash
# install.sh — Starship + Zellij + animated wallpaper (xwinwrap + mpv)
#
# Usage:  bash install.sh [options]      (run `bash install.sh --help` for the list)
#
# What it does:
#   1. asks which name(s) to show in the Starship prompt
#   2. checks / installs the dependencies (mpv, xclip, git, curl, zsh, xwinwrap, zellij, starship)
#   3. installs the Zellij config, plugins and status-bar scripts
#   4. installs the Starship config with YOUR name
#   5. adds a managed block to ~/.zshrc (aliases + target helpers)
#   6. sets up the animated wallpaper autostart (XFCE / X11)
#
# Anything it replaces is backed up first (*.bak-<timestamp>). Safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
CFG="$HOME/.config"
ZELLIJ_VERSION="${ZELLIJ_VERSION:-0.44.1}"   # version the config + bundled plugins work with; use ZELLIJ_VERSION=latest to override

NAME1=""; NAME2=""; NAME2_SET=0
VIDEO=""; NO_WALLPAPER=0; ASSUME_YES=0; ONLY_PERMS=0
LABEL=""; REPLY_VAL=""
TMPDIRS=()

# ---------- output helpers ----------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s err%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

cleanup() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    [[ -n $d ]] || continue
    rm -rf "$d"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

  --name1 NAME      first name/handle shown in the Starship prompt
  --name2 NAME      second name (use --name2 "" for none)
  --video PATH      video file for the animated wallpaper (mp4, ideally 10 fps)
  --no-wallpaper    skip xwinwrap/mpv and the wallpaper autostart
  --grant-permissions
                    only (re)write the Zellij plugin permissions, then exit. Use it if the
                    top bar is blank / the terminal seems frozen on the first start
                    (Zellij is waiting for you to press "y" on a permission prompt).
  -y, --yes         don't ask questions; use defaults / given options
  -h, --help        show this help

Environment:
  ZELLIJ_VERSION=x.y.z   Zellij version to install into ~/.local/bin when zellij is
                         missing or is a different version (default: 0.44.1, the
                         version the config and bundled plugins work with; use
                         "latest" for the newest release and to keep any installed one).
EOF
}

# ---------- argument parsing ----------
while (($#)); do
  case "$1" in
    --name1)        (($# >= 2)) || die "--name1 needs a value"; NAME1="$2"; shift 2 ;;
    --name2)        (($# >= 2)) || die "--name2 needs a value"; NAME2="$2"; NAME2_SET=1; shift 2 ;;
    --video)        (($# >= 2)) || die "--video needs a value"; VIDEO="$2"; shift 2 ;;
    --no-wallpaper) NO_WALLPAPER=1; shift ;;
    --grant-permissions) ONLY_PERMS=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------- small utilities ----------
have() { command -v "$1" >/dev/null 2>&1; }

interactive() { [[ -t 0 && $ASSUME_YES -eq 0 ]]; }

ask() { # ask "prompt" "default"  -> REPLY_VAL
  local prompt=$1 def=${2-} ans=""
  if interactive; then
    if [[ -n $def ]]; then
      read -r -p "$prompt [$def]: " ans || true
    else
      read -r -p "$prompt: " ans || true
    fi
  fi
  REPLY_VAL="${ans:-$def}"
}

confirm() { # confirm "question" y|n
  local q=$1 def=${2:-y} ans="" hint="[Y/n]"
  ((ASSUME_YES)) && return 0
  if [[ ! -t 0 ]]; then
    [[ $def == y ]]
    return
  fi
  [[ $def == n ]] && hint="[y/N]"
  read -r -p "$q $hint " ans || true
  ans="${ans:-$def}"
  [[ $ans =~ ^[Yy] ]]
}

# escape a string for use as the replacement part of  sed 's|...|HERE|'
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# render_template SRC DST KEY VALUE [KEY VALUE ...]   (replaces @@KEY@@ with VALUE)
render_template() {
  local src=$1 dst=$2; shift 2
  local -a args=()
  while (($# >= 2)); do
    args+=(-e "s|@@$1@@|$(sed_escape "$2")|g")
    shift 2
  done
  sed "${args[@]}" "$src" > "$dst"
}

backup() { # move an existing path out of the way
  local p=$1
  if [[ -e $p || -L $p ]]; then
    mv "$p" "$p.bak-$STAMP"
    ok "backed up $p -> $p.bak-$STAMP"
  fi
}

# names end up inside a Starship format string / TOML string: reject the special characters
valid_name() {
  local s=$1
  [[ -n $s && ${#s} -le 30 ]] || return 1
  case $s in
    *'['*|*']'*|*'('*|*')'*|*'$'*|*'"'*|*'`'*|*'\'*) return 1 ;;
  esac
  return 0
}

# a path that ends up inside Exec='...' of a .desktop file
valid_video_path() {
  case $1 in
    *"'"*|*'"'*|*'$'*|*'`'*|*'\'*|*'%'*) return 1 ;;
  esac
  return 0
}

# Zellij asks "Allow? (y/n)" the first time each plugin runs. The top bar (zjstatus) is a single
# line tall, so you cannot even see the question: the bar stays blank and the keyboard focus
# sits on the plugin, which looks like a frozen terminal. Zellij remembers the answers in
# ~/.cache/zellij/permissions.kdl, so we write them there ourselves (merging with what is
# already in the file). These are the permissions each bundled plugin asks for; if a plugin
# is updated and needs more, Zellij simply asks again.
grant_plugin_permissions() {
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/zellij"
  local file="$dir/permissions.kdl" pdir="$CFG/zellij/plugins" tmp name perm paths=""
  local -A PERMS=(
    [zjstatus]="ReadApplicationState ChangeApplicationState RunCommands"
    [zjstatus-hints]="ReadApplicationState MessageAndLaunchOtherPlugins"
    [zellij-autolock]="ReadApplicationState ChangeApplicationState"
    [zellij-pane-picker]="ReadApplicationState ChangeApplicationState Reconfigure"
    [room]="ReadApplicationState ChangeApplicationState"
    [zellij_forgot]="ReadApplicationState ChangeApplicationState"
  )
  local -a ORDER=(zjstatus zjstatus-hints zellij-autolock zellij-pane-picker room zellij_forgot)

  mkdir -p "$dir"
  for name in "${ORDER[@]}"; do paths+="$pdir/$name.wasm"$'\n'; done
  tmp="$(mktemp)"; TMPDIRS+=("$tmp")
  {
    # keep every entry that is not one of ours ...
    if [[ -f $file ]]; then
      PLUGIN_PATHS="$paths" awk '
        BEGIN { n = split(ENVIRON["PLUGIN_PATHS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") mine[a[i]] = 1 }
        skip  { if ($0 ~ /^}/) skip = 0; next }
        /^"/  { k = $0; sub(/^"/, "", k); sub(/" *\{.*$/, "", k); if (k in mine) { skip = 1; next } }
        { print }
      ' "$file"
    fi
    # ... and add ours
    for name in "${ORDER[@]}"; do
      printf '"%s/%s.wasm" {\n' "$pdir" "$name"
      for perm in ${PERMS[$name]}; do printf '    %s\n' "$perm"; done
      printf '}\n'
    done
  } > "$tmp"

  if [[ -f $file ]] && cmp -s "$tmp" "$file"; then
    ok "zellij plugin permissions already granted"
  else
    if [[ -f $file ]]; then cp -p "$file" "$file.bak-$STAMP"; fi
    cat "$tmp" > "$file"
    ok "zellij plugin permissions granted ($file)"
  fi
}

# ---------- 0. preflight ----------
if ((EUID == 0)) && [[ -z ${ALLOW_ROOT:-} ]]; then
  die "Don't run this as root: it installs into your own home directory. (Override: ALLOW_ROOT=1)"
fi
if ((ONLY_PERMS)); then
  [[ -d $CFG/zellij/plugins ]] || die "no Zellij plugins in $CFG/zellij/plugins yet: run the full installer first (bash install.sh)"
  info "Granting Zellij plugin permissions"
  grant_plugin_permissions
  echo "    If Zellij is already running, close it first:  zellij kill-all-sessions -y   (then open a new terminal)"
  exit 0
fi
for d in starship zsh zellij wallpaper; do
  [[ -e $REPO_DIR/$d ]] || die "repo looks incomplete: missing '$d/' next to install.sh"
done
export PATH="$HOME/.local/bin:$PATH"

SUDO=""
if ((EUID != 0)) && have sudo; then SUDO="sudo"; fi

if [[ ${XDG_SESSION_TYPE:-} == wayland ]] && ((!NO_WALLPAPER)); then
  warn "You are on Wayland: xwinwrap only works on X11. The wallpaper will not show (everything else is fine)."
fi

# ---------- 1. questions (all up front) ----------
info "Prompt name"
echo "    Your Starship prompt will look like:  ~ › <name> ⚔ <name2> ›"

if [[ -z $NAME1 ]]; then
  while :; do
    ask "First name / handle" "${USER:-$(id -un)}"
    NAME1=$REPLY_VAL
    valid_name "$NAME1" && break
    warn 'Max 30 chars, and none of these characters:  [ ] ( ) $ " ` \'
    interactive || die "invalid --name1"
  done
fi
valid_name "$NAME1" || die "invalid --name1 (max 30 chars; no [ ] ( ) \$ \" \` \\)"

if ((!NAME2_SET)); then
  while :; do
    ask "Second name (optional, press Enter to skip)" ""
    NAME2=$REPLY_VAL
    [[ -z $NAME2 ]] && break
    valid_name "$NAME2" && break
    warn 'Max 30 chars, and none of these characters:  [ ] ( ) $ " ` \'
    interactive || die "invalid --name2"
  done
fi
if [[ -n $NAME2 ]]; then
  valid_name "$NAME2" || die "invalid --name2"
  LABEL="$NAME1 ⚔ $NAME2"
else
  LABEL="$NAME1"
fi

if ((!NO_WALLPAPER)); then
  info "Animated wallpaper"
  if [[ -z $VIDEO ]]; then
    ask "Path to your wallpaper video, e.g. ~/Videos/loop.mp4 (Enter to skip the wallpaper)" ""
    VIDEO=$REPLY_VAL
  fi
  if [[ -z $VIDEO ]]; then
    warn "No video given: skipping the animated wallpaper (re-run with --video PATH to add it later)."
    NO_WALLPAPER=1
  else
    VIDEO="${VIDEO/#\~/$HOME}"
    [[ -f $VIDEO ]] || die "video not found: $VIDEO"
    VIDEO="$(realpath "$VIDEO")"
    valid_video_path "$VIDEO" || die "the video path contains a character that is not allowed (' \" \$ \` \\ %): $VIDEO"
  fi
fi

# ---------- 2. dependencies ----------
info "Checking dependencies"

declare -A PKG=([mpv]=mpv [xclip]=xclip [git]=git [curl]=curl [ss]=iproute2 [zsh]=zsh)
want=(xclip git curl ss zsh)
((NO_WALLPAPER)) || want+=(mpv)

missing=(); pkgs=(); NEED_XWINWRAP=0
for c in "${want[@]}"; do
  if have "$c"; then
    ok "$c found"
  else
    warn "$c is missing"
    missing+=("$c"); pkgs+=("${PKG[$c]}")
  fi
done
if ((!NO_WALLPAPER)); then
  if have xwinwrap; then
    ok "xwinwrap found"
  else
    warn "xwinwrap is missing (will be built from source)"
    NEED_XWINWRAP=1
    pkgs+=(build-essential xorg-dev libx11-dev x11proto-xext-dev libxrender-dev libxext-dev)
  fi
fi

if ((${#pkgs[@]})); then
  have apt-get || die "apt-get not found. Install these yourself and re-run: ${missing[*]} ${NEED_XWINWRAP:+xwinwrap (+ X11 dev headers)}"
  if ((EUID != 0)) && [[ -z $SUDO ]]; then die "sudo not found; install the missing packages as root, then re-run."; fi
  confirm "Install the missing packages with apt now? (needs sudo)" y || die "Cannot continue without: ${missing[*]}"
  $SUDO apt-get update
  $SUDO apt-get install -y "${pkgs[@]}"
fi

if ((!NO_WALLPAPER)); then
  have mpv || die "mpv is still not available after installation."
  if ((NEED_XWINWRAP)); then
    info "Building xwinwrap"
    tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
    git clone --depth 1 https://github.com/mmhobi7/xwinwrap.git "$tmp/xwinwrap"
    make -C "$tmp/xwinwrap"
    $SUDO install -m 0755 "$tmp/xwinwrap/xwinwrap" /usr/local/bin/xwinwrap
    have xwinwrap || die "xwinwrap build finished but the binary is not on PATH"
    ok "xwinwrap installed to /usr/local/bin"
  fi
fi

arch_triple() {
  case "$(uname -m)" in
    x86_64)        echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    *)             return 1 ;;
  esac
}

install_release_bin() { # install_release_bin NAME URL  -> ~/.local/bin/NAME
  local name=$1 url=$2 tmp found
  tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
  info "Downloading $name"
  curl -fsSL "$url" -o "$tmp/pkg.tar.gz" || die "download failed: $url"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || die "could not unpack the $name archive"
  found="$(find "$tmp" -type f -name "$name" | head -n 1)"
  [[ -n $found ]] || die "'$name' binary not found inside the archive"
  mkdir -p "$HOME/.local/bin"
  if [[ -e $HOME/.local/bin/$name ]]; then backup "$HOME/.local/bin/$name"; fi   # only after the download worked
  install -m 0755 "$found" "$HOME/.local/bin/$name"
  ok "$name installed to ~/.local/bin"
}

triple="$(arch_triple)" || triple=""

if have starship; then
  ok "starship found"
else
  [[ -n $triple ]] || die "unsupported CPU ($(uname -m)); install starship manually (https://starship.rs) and re-run."
  confirm "starship is missing. Download the official release into ~/.local/bin?" y || die "starship is required."
  install_release_bin starship "https://github.com/starship/starship/releases/latest/download/starship-$triple.tar.gz"
fi

z_want="${ZELLIJ_VERSION#v}"
z_have=""
if have zellij; then
  z_have="$(zellij --version 2>/dev/null | awk '{print $2; exit}')" || z_have=""
  ok "zellij found (${z_have:-unknown version})"
fi

# the config and the bundled plugins (.wasm) only work with one Zellij version, so install
# exactly that one unless it is already there (ZELLIJ_VERSION=latest keeps whatever is installed)
z_install=0
if [[ $ZELLIJ_VERSION == latest ]]; then
  [[ -n $z_have ]] || z_install=1
elif [[ $z_have != "$z_want" ]]; then
  z_install=1
fi

if ((z_install)); then
  [[ -n $triple ]] || die "unsupported CPU ($(uname -m)); install zellij $z_want manually and re-run."
  if [[ -n $z_have ]]; then
    warn "zellij $z_have is installed, but the config and bundled plugins need zellij $z_want."
    if ! confirm "Install zellij $z_want into ~/.local/bin? (it takes priority over the other one)" y; then
      z_install=0
      warn "keeping zellij $z_have; if the plugins fail to load, re-run and accept the install of $z_want."
    fi
  else
    confirm "zellij is missing. Download the official release ($ZELLIJ_VERSION) into ~/.local/bin?" y || die "zellij is required."
  fi
fi

if ((z_install)); then
  if [[ $ZELLIJ_VERSION == latest ]]; then
    z_url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-$triple.tar.gz"
  else
    z_url="https://github.com/zellij-org/zellij/releases/download/v$z_want/zellij-$triple.tar.gz"
  fi
  install_release_bin zellij "$z_url"
  if [[ $ZELLIJ_VERSION != latest ]]; then
    z_now="$("$HOME/.local/bin/zellij" --version 2>/dev/null | awk '{print $2; exit}')" || z_now=""
    [[ $z_now == "$z_want" ]] || die "expected zellij $z_want after install, but got '${z_now:-nothing}'"
    ok "zellij $z_now ready"
  fi
fi

# ---------- 3. zellij ----------
info "Installing Zellij config"
mkdir -p "$CFG"
backup "$CFG/zellij"
cp -R "$REPO_DIR/zellij" "$CFG/zellij"

# zellij does not expand $HOME inside plugin paths, so write the real home directory in
for f in "$CFG/zellij/config.kdl" "$CFG"/zellij/layouts/*.kdl; do
  render_template "$f" "$f.tmp" HOME "$HOME"
  mv "$f.tmp" "$f"
done

# one script, several names: sysload.sh decides what to print from the name it is called with
chmod +x "$CFG/zellij/scripts/sysload.sh"
for n in zj-tgt zj-ports zj-net zj-ram; do
  ln -sfn sysload.sh "$CFG/zellij/scripts/$n.sh"
done
ok "zellij config, layout, plugins and scripts installed to ~/.config/zellij"
grant_plugin_permissions

# ---------- 4. starship ----------
info "Installing Starship config"
tmp_toml="$(mktemp)"; TMPDIRS+=("$tmp_toml")
render_template "$REPO_DIR/starship/starship.toml" "$tmp_toml" PROMPT_LABEL "$LABEL"
if [[ -f $CFG/starship.toml ]] && cmp -s "$tmp_toml" "$CFG/starship.toml"; then
  ok "starship.toml already up to date"
else
  backup "$CFG/starship.toml"
  install -m 0644 "$tmp_toml" "$CFG/starship.toml"
  ok "starship.toml installed (prompt label: $LABEL)"
fi

# ---------- 5. ~/.zshrc ----------
info "Updating ~/.zshrc"
rc="$HOME/.zshrc"
begin='# >>> nullsecure-dotfiles (managed by install.sh) >>>'
end='# <<< nullsecure-dotfiles <<<'
touch "$rc"
tmp_rc="$(mktemp)"; TMPDIRS+=("$tmp_rc")
# drop an older copy of our block (if any) and trailing blank lines, then append the fresh block
awk -v b="$begin" -v e="$end" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  !skip   { a[++n] = $0 }
  END     { while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }
' "$rc" > "$tmp_rc"
{
  [[ -s $tmp_rc ]] && echo
  echo "$begin"
  cat "$REPO_DIR/zsh/zshrc.snippet"
  echo "$end"
} >> "$tmp_rc"
if cmp -s "$tmp_rc" "$rc"; then
  ok "~/.zshrc already up to date"
else
  cp -p "$rc" "$rc.bak-$STAMP"
  cat "$tmp_rc" > "$rc"        # cat (not mv) keeps ~/.zshrc intact if it is a symlink
  ok "managed block written to ~/.zshrc (backup: ~/.zshrc.bak-$STAMP)"
fi

# ---------- 6. wallpaper ----------
if ((!NO_WALLPAPER)); then
  info "Setting up the wallpaper autostart"
  mkdir -p "$CFG/autostart"
  desktop="$CFG/autostart/safe-live-wallpaper.desktop"
  tmp_desktop="$(mktemp)"; TMPDIRS+=("$tmp_desktop")
  render_template "$REPO_DIR/wallpaper/live-wallpaper.desktop" "$tmp_desktop" VIDEO "$VIDEO"
  if [[ -f $desktop ]] && cmp -s "$tmp_desktop" "$desktop"; then
    ok "autostart entry already up to date"
  else
    backup "$desktop"
    install -m 0644 "$tmp_desktop" "$desktop"
    ok "autostart entry installed: $desktop"
  fi

  if [[ -n ${DISPLAY:-} ]] && ! pgrep -x xwinwrap >/dev/null 2>&1; then
    if confirm "Start the wallpaper now?" y; then
      exec_line="$(sed -n 's/^Exec=//p' "$desktop" | head -n 1)"
      setsid bash -c "$exec_line" >/dev/null 2>&1 &
      ok "wallpaper started"
    fi
  fi
fi

# ---------- done ----------
echo
info "Done."
cat <<EOF
  Next steps:
   1. Open a NEW terminal (or run: exec zsh) to load the prompt + Zellij.
   2. For the wallpaper to show through, enable transparency in your terminal
      (and the compositor on XFCE). See README.md -> "Terminal transparency".
EOF
if [[ ${SHELL##*/} != zsh ]]; then
  warn "Your login shell is ${SHELL:-unknown}, but the config lives in ~/.zshrc. Switch with:  chsh -s \"\$(command -v zsh)\""
fi
