#!/usr/bin/env bash
# shellcheck disable=SC2155
# Disabled "Declare and assign separately to avoid masking return values": https://github.com/koalaman/shellcheck/wiki/SC2155

#
# log <type> <msg>
#

log() {
  printf "  ${SGR_CYAN}%10s${SGR_RESET} : ${SGR_FAINT}%s${SGR_RESET}\n" "$1" "$2"
}

#
# verbose_log <type> <msg>
# Can suppress with --quiet.
# Like log but to stderr rather than stdout, so can also be used from "display" routines.
#

verbose_log() {
  if [[ "${SHOW_VERBOSE_LOG}" == "true" ]]; then
    >&2 printf "  ${SGR_CYAN}%10s${SGR_RESET} : ${SGR_FAINT}%s${SGR_RESET}\n" "$1" "$2"
  fi
}

#
# Exit with the given <msg ...>
#

abort() {
  >&2 printf "\n  ${SGR_RED}Error: %s${SGR_RESET}\n\n" "$*" && exit 1
}

#
# Synopsis: trace message ...
# Debugging output to stderr, not used in production code.
#

function trace() {
  >&2 printf "trace: %s\n" "$*"
}

#
# Synopsis: echo_red message ...
# Highlight message in colour (on stdout).
#

function echo_red() {
  printf "${SGR_RED}%s${SGR_RESET}\n" "$*"
}

#
# Synopsis: n_grep <args...>
# grep wrapper to ensure consistent grep options and circumvent aliases.
#

function n_grep() {
  GREP_OPTIONS='' command grep "$@"
}

#
# Setup and state
#

VERSION="v9.0.1"

N_PREFIX="${N_PREFIX-/usr/local}"
N_PREFIX=${N_PREFIX%/}
readonly N_PREFIX

N_CACHE_PREFIX="${N_CACHE_PREFIX-${N_PREFIX}}"
N_CACHE_PREFIX=${N_CACHE_PREFIX%/}
CACHE_DIR="${N_CACHE_PREFIX}/n/versions"
readonly N_CACHE_PREFIX CACHE_DIR

N_NODE_MIRROR=${N_NODE_MIRROR:-${NODE_MIRROR:-https://nodejs.org/dist}}
N_NODE_MIRROR=${N_NODE_MIRROR%/}
readonly N_NODE_MIRROR

N_NODE_DOWNLOAD_MIRROR=${N_NODE_DOWNLOAD_MIRROR:-https://nodejs.org/download}
N_NODE_DOWNLOAD_MIRROR=${N_NODE_DOWNLOAD_MIRROR%/}
readonly N_NODE_DOWNLOAD_MIRROR

# Using xz instead of gzip is enabled by default, if xz compatibility checks pass.
# User may set N_USE_XZ to 0 to disable, or set to anything else to enable.
# May also be overridden by command line flags.

# Normalise external values to true/false
if [[ "${N_USE_XZ}" = "0" ]]; then
  N_USE_XZ="false"
elif [[ -n "${N_USE_XZ+defined}" ]]; then
  N_USE_XZ="true"
fi
# Not setting to readonly. Overriden by CLI flags, and update_xz_settings_for_version.

N_MAX_REMOTE_MATCHES=${N_MAX_REMOTE_MATCHES:-20}
# modified by update_mirror_settings_for_version
g_mirror_url=${N_NODE_MIRROR}
g_mirror_folder_name="node"

# Options for curl and wget.
# Defining commands in variables is fraught (https://mywiki.wooledge.org/BashFAQ/050)
# but we can follow the simple case and store arguments in an array.

GET_SHOWS_PROGRESS="false"
# --location to follow redirects
# --fail to avoid happily downloading error page from web server for 404 et al
# --show-error to show why failed (on stderr)
CURL_OPTIONS=( "--location" "--fail" "--show-error" )
if [[ -t 1 ]]; then
  CURL_OPTIONS+=( "--progress-bar" )
  command -v curl &> /dev/null && GET_SHOWS_PROGRESS="true"
else
  CURL_OPTIONS+=( "--silent" )
fi
WGET_OPTIONS=( "-q" "-O-" )

# Legacy support using unprefixed env. No longer documented in README.
if [ -n "$HTTP_USER" ];then
  if [ -z "$HTTP_PASSWORD" ]; then
    abort "Must specify HTTP_PASSWORD when supplying HTTP_USER"
  fi
  CURL_OPTIONS+=( "-u $HTTP_USER:$HTTP_PASSWORD" )
  WGET_OPTIONS+=( "--http-password=$HTTP_PASSWORD"
                "--http-user=$HTTP_USER" )
elif [ -n "$HTTP_PASSWORD" ]; then
  abort "Must specify HTTP_USER when supplying HTTP_PASSWORD"
fi

# Set by set_active_node
g_active_node=

# set by various lookups to allow mixed logging and return value from function, especially for engine and node
g_target_node=

DOWNLOAD=false # set to opt-out of activate (install), and opt-in to download (run, exec)
ARCH=
SHOW_VERBOSE_LOG="true"

# ANSI escape codes
# https://en.wikipedia.org/wiki/ANSI_escape_code
# https://no-color.org
# https://bixense.com/clicolors

USE_COLOR="true"
if [[ -n "${CLICOLOR_FORCE+defined}" && "${CLICOLOR_FORCE}" != "0" ]]; then
  USE_COLOR="true"
elif [[ -n "${NO_COLOR+defined}" || "${CLICOLOR}" = "0" || ! -t 1 ]]; then
  USE_COLOR="false"
fi
readonly USE_COLOR
# Select Graphic Rendition codes
if [[ "${USE_COLOR}" = "true" ]]; then
  # KISS and use codes rather than tput, avoid dealing with missing tput or TERM.
  readonly SGR_RESET="\033[0m"
  readonly SGR_FAINT="\033[2m"
  readonly SGR_RED="\033[31m"
  readonly SGR_CYAN="\033[36m"
else
  readonly SGR_RESET=
  readonly SGR_FAINT=
  readonly SGR_RED=
  readonly SGR_CYAN=
fi

#
# set_arch <arch> to override $(uname -a)
#

set_arch() {
  if test -n "$1"; then
    ARCH="$1"
  else
    abort "missing -a|--arch value"
  fi
}

#
# Synopsis: set_insecure
# Globals modified:
# - CURL_OPTIONS
# - WGET_OPTIONS
#

function set_insecure() {
  CURL_OPTIONS+=( "--insecure" )
  WGET_OPTIONS+=( "--no-check-certificate" )
}

#
# Synposis: display_major_version numeric-version
#
display_major_version() {
    local version=$1
    version="${version#v}"
    version="${version%%.*}"
    echo "${version}"
}

#
# Synopsis: update_mirror_settings_for_version version
# e.g. <nightly/latest> means using download mirror and folder is nightly
# Globals modified:
# - g_mirror_url
# - g_mirror_folder_name
#

function update_mirror_settings_for_version() {
  if is_download_folder "$1" ; then
    g_mirror_folder_name="$1"
    g_mirror_url="${N_NODE_DOWNLOAD_MIRROR}/${g_mirror_folder_name}"
  elif is_download_version "$1"; then
    [[ "$1" =~ ^([^/]+)/(.*) ]]
    local remote_folder="${BASH_REMATCH[1]}"
    g_mirror_folder_name="${remote_folder}"
    g_mirror_url="${N_NODE_DOWNLOAD_MIRROR}/${g_mirror_folder_name}"
  fi
}

#
# Synopsis: update_xz_settings_for_version numeric-version
# Globals modified:
# - N_USE_XZ
#

function update_xz_settings_for_version() {
  # tarballs in xz format were available in later version of iojs, but KISS and only use xz from v4.
  if [[ "${N_USE_XZ}" = "true" ]]; then
    local major_version="$(display_major_version "$1")"
    if [[ "${major_version}" -lt 4 ]]; then
      N_USE_XZ="false"
    fi
  fi
}

#
# Synopsis: update_arch_settings_for_version numeric-version
# Globals modified:
# - ARCH
#

function update_arch_settings_for_version() {
  local tarball_platform="$(display_tarball_platform)"
  if [[ -z "${ARCH}" && "${tarball_platform}" = "darwin-arm64" ]]; then
    # First native builds were for v16, but can use x64 in rosetta for older versions.
    local major_version="$(display_major_version "$1")"
    if [[ "${major_version}" -lt 16 ]]; then
      ARCH=x64
    fi
  fi
}

#
# Synopsis: is_lts_codename version
#

function is_lts_codename() {
  # https://github.com/nodejs/Release/blob/master/CODENAMES.md
  # e.g. argon, Boron
  [[ "$1" =~ ^([Aa]rgon|[Bb]oron|[Cc]arbon|[Dd]ubnium|[Ee]rbium|[Ff]ermium|[Gg]allium|[Hh]ydrogen|[Ii]ron|[Jj]od)$ ]]
}

#
# Synopsis: is_download_folder version
#

function is_download_folder() {
  # e.g. nightly
  [[ "$1" =~ ^(next-nightly|nightly|rc|release|test|v8-canary)$ ]]
}

#
# Synopsis: is_download_version version
#

function is_download_version() {
  # e.g. nightly/, nightly/latest, nightly/v11
  if [[ "$1" =~ ^([^/]+)/(.*) ]]; then
    local remote_folder="${BASH_REMATCH[1]}"
    is_download_folder "${remote_folder}"
    return
  fi
  return 2
}

#
# Synopsis: is_numeric_version version
#

function is_numeric_version() {
  # e.g. 6, v7.1, 8.11.3
  [[ "$1" =~ ^[v]{0,1}[0-9]+(\.[0-9]+){0,2}$ ]]
}

#
# Synopsis: is_exact_numeric_version version
#

function is_exact_numeric_version() {
  # e.g. 6, v7.1, 8.11.3
  [[ "$1" =~ ^[v]{0,1}[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

#
# Synopsis: is_node_support_version version
# Reference: https://github.com/nodejs/package-maintenance/issues/236#issue-474783582
#

function is_node_support_version() {
  [[ "$1" =~ ^(active|lts_active|lts_latest|lts|current|supported)$ ]]
}

#
# Synopsis: display_latest_node_support_alias version
# Map aliases onto existing n aliases, current and lts
#

function display_latest_node_support_alias() {
  case "$1" in
    "active") printf "current" ;;
    "lts_active") printf "lts" ;;
    "lts_latest") printf "lts" ;;
    "lts") printf "lts" ;;
    "current") printf "current" ;;
    "supported") printf "current" ;;
    *) printf "unexpected-version"
  esac
}

#
# Functions used when showing versions installed
#

enter_fullscreen() {
  # Set cursor to be invisible
  tput civis 2> /dev/null
  # Save screen contents
  tput smcup 2> /dev/null
  stty -echo
}

leave_fullscreen() {
  # Set cursor to normal
  tput cnorm 2> /dev/null
  # Restore screen contents
  tput rmcup 2> /dev/null
  stty echo
}

handle_sigint() {
  leave_fullscreen
  S="$?"
  kill 0
  exit $S
}

handle_sigtstp() {
  leave_fullscreen
  kill -s SIGSTOP $$
}

#
# Output usage information.
#

display_help() {
  cat <<-EOF

Usage: n [options] [COMMAND] [args]

Commands:

  n                              Display downloaded Node.js versions and install selection
  n latest                       Install the latest Node.js release (downloading if necessary)
  n lts                          Install the latest LTS Node.js release (downloading if necessary)
  n <version>                    Install Node.js <version> (downloading if necessary)
  n install <version>            Install Node.js <version> (downloading if necessary)
  n run <version> [args ...]     Execute downloaded Node.js <version> with [args ...]
  n which <version>              Output path for downloaded node <version>
  n exec <vers> <cmd> [args...]  Execute command with modified PATH, so downloaded node <version> and npm first
  n rm <version ...>             Remove the given downloaded version(s)
  n prune                        Remove all downloaded versions except the installed version
  n --latest                     Output the latest Node.js version available
  n --lts                        Output the latest LTS Node.js version available
  n ls                           Output downloaded versions
  n ls-remote [version]          Output matching versions available for download
  n uninstall                    Remove the installed Node.js

Options:

  -V, --version         Output version of n
  -h, --help            Display help information
  -p, --preserve        Preserve npm and npx during install of Node.js
  -q, --quiet           Disable curl output. Disable log messages processing "auto" and "engine" labels.
  -d, --download        Download if necessary, and don't make active
  -a, --arch            Override system architecture
  --all                 ls-remote displays all matches instead of last 20
  --insecure            Turn off certificate checking for https requests (may be needed from behind a proxy server)
  --use-xz/--no-use-xz  Override automatic detection of xz support and enable/disable use of xz compressed node downloads.

Aliases:

  install: i
  latest: current
  ls: list
  lsr: ls-remote
  lts: stable
  rm: -
  run: use, as
  which: bin

Versions:

  Numeric version numbers can be complete or incomplete, with an optional leading 'v'.
  Versions can also be specified by label, or codename,
  and other downloadable releases by <remote-folder>/<version>

    4.9.1, 8, v6.1    Numeric versions
    lts               Newest Long Term Support official release
    latest, current   Newest official release
    auto              Read version from file: .n-node-version, .node-version, .nvmrc, or package.json
    engine            Read version from package.json
    boron, carbon     Codenames for release streams
    lts_latest        Node.js support aliases

    and nightly, rc/10 et al

EOF
}

err_no_installed_print_help() {
  display_help
  abort "no downloaded versions yet, see above help for commands"
}

#
# Synopsis: next_version_installed selected_version
# Output version after selected (which may be blank under some circumstances).
#

function next_version_installed() {
  display_cache_versions | n_grep "$1" -A 1 | tail -n 1
}

#
# Synopsis: prev_version_installed selected_version
# Output version before selected  (which may be blank under some circumstances).
#

function prev_version_installed() {
  display_cache_versions | n_grep "$1" -B 1 | head -n 1
}

#
# Output n version.
#

display_n_version() {
  echo "$VERSION" && exit 0
}

#
# Synopsis: set_active_node
# Checks cached downloads for a binary matching the active node.
# Globals modified:
# - g_active_node
#

function set_active_node() {
  g_active_node=
  local node_path="$(command -v node)"
  if [[ -x "${node_path}" ]]; then
    local installed_version=$(node --version)
    installed_version=${installed_version#v}
    for dir in "${CACHE_DIR}"/*/ ; do
      local folder_name="${dir%/}"
      folder_name="${folder_name##*/}"
      if diff &> /dev/null \
        "${CACHE_DIR}/${folder_name}/${installed_version}/bin/node" \
        "${node_path}" ; then
        g_active_node="${folder_name}/${installed_version}"
        break
      fi
    done
  fi
}

#
# Display sorted versions directories paths.
#

display_versions_paths() {
  find "$CACHE_DIR" -maxdepth 2 -type d \
    | sed 's|'"$CACHE_DIR"'/||g' \
    | n_grep -E "/[0-9]+\.[0-9]+\.[0-9]+" \
    | sed 's|/|.|' \
    | sort -k 1,1 -k 2,2n -k 3,3n -k 4,4n -t . \
    | sed 's|\.|/|'
}

#
# Display installed versions with <selected>
#

display_versions_with_selected() {
  local selected="$1"
  echo
  for version in $(display_versions_paths); do
    if test "$version" = "$selected"; then
      printf "  ${SGR_CYAN}ο${SGR_RESET} %s\n" "$version"
    else
      printf "    ${SGR_FAINT}%s${SGR_RESET}\n" "$version"
    fi
  done
  echo
  printf "Use up/down arrow keys to select a version, return key to install, d to delete, q to quit"
}

#
# Synopsis: display_cache_versions
#

function display_cache_versions() {
  for folder_and_version in $(display_versions_paths); do
    echo "${folder_and_version}"
  done
}

#
# Display current node --version and others installed.
#

menu_select_cache_versions() {
  enter_fullscreen
  set_active_node
  local selected="${g_active_node}"

  clear
  display_versions_with_selected "${selected}"

  trap handle_sigint INT
  trap handle_sigtstp SIGTSTP

  ESCAPE_SEQ=$'\033'
  UP=$'A'
  DOWN=$'B'
  CTRL_P=$'\020'
  CTRL_N=$'\016'

  while true; do
    read -rsn 1 key
    case "$key" in
      "$ESCAPE_SEQ")
        # Handle ESC sequences followed by other characters, i.e. arrow keys
        read -rsn 1 -t 1 tmp
        # See "[" if terminal in normal mode, and "0" in application mode
        if [[ "$tmp" == "[" || "$tmp" == "O" ]]; then
          read -rsn 1 -t 1 arrow
          case "$arrow" in
            "$UP")
              clear
              selected="$(prev_version_installed "${selected}")"
              display_versions_with_selected "${selected}"
              ;;
            "$DOWN")
              clear
              selected="$(next_version_installed "${selected}")"
              display_versions_with_selected "${selected}"
              ;;
          esac
        fi
        ;;
      "d")
        if [[ -n "${selected}" ]]; then
          clear
          # Note: prev/next is constrained to min/max
          local after_delete_selection="$(next_version_installed "${selected}")"
          if [[ "${after_delete_selection}" == "${selected}"  ]]; then
            after_delete_selection="$(prev_version_installed "${selected}")"
          fi
          remove_versions "${selected}"

          if [[ "${after_delete_selection}" == "${selected}" ]]; then
            clear
            leave_fullscreen
            echo "All downloaded versions have been deleted from cache."
            exit
          fi

          selected="${after_delete_selection}"
          display_versions_with_selected "${selected}"
        fi
        ;;
      # Vim or Emacs 'up' key
      "k"|"$CTRL_P")
        clear
        selected="$(prev_version_installed "${selected}")"
        display_versions_with_selected "${selected}"
        ;;
      # Vim or Emacs 'down' key
      "j"|"$CTRL_N")
        clear
        selected="$(next_version_installed "${selected}")"
        display_versions_with_selected "${selected}"
        ;;
      "q")
        clear
        leave_fullscreen
        exit
        ;;
      "")
        # enter key returns empty string
        leave_fullscreen
        [[ -n "${selected}" ]] && activate "${selected}"
        exit
        ;;
    esac
  done
}

#
# Move up a line and erase.
#

erase_line() {
  printf "\033[1A\033[2K"
}

#
# Disable PaX mprotect for <binary>
#

disable_pax_mprotect() {
  test -z "$1" && abort "binary required"
  local binary="$1"

  # try to disable mprotect via XATTR_PAX header
  local PAXCTL="$(PATH="/sbin:/usr/sbin:$PATH" command -v paxctl-ng 2>&1)"
  local PAXCTL_ERROR=1
  if [ -x "$PAXCTL" ]; then
    $PAXCTL -l && $PAXCTL -m "$binary" >/dev/null 2>&1
    PAXCTL_ERROR="$?"
  fi

  # try to disable mprotect via PT_PAX header
  if [ "$PAXCTL_ERROR" != 0 ]; then
    PAXCTL="$(PATH="/sbin:/usr/sbin:$PATH" command -v paxctl 2>&1)"
    if [ -x "$PAXCTL" ]; then
      $PAXCTL -Cm "$binary" >/dev/null 2>&1
    fi
  fi
}

#
# clean_copy_folder <source> <target>
#

clean_copy_folder() {
  local source="$1"
  local target="$2"
  if [[ -d "${source}" ]]; then
    rm -rf "${target}"
    cp -fR "${source}" "${target}"
  fi
}

#
# Activate <version>
#

activate() {
  local version="$1"
  local dir="$CACHE_DIR/$version"
  local original_node="$(command -v node)"
  local installed_node="${N_PREFIX}/bin/node"
  log "copying" "$version"


  # Ideally we would just copy from cache to N_PREFIX, but there are some complications
  # - various linux versions use symlinks for folders in /usr/local and also error when copy folder onto symlink
  # - we have used cp for years, so keep using it for backwards compatibility (instead of say rsync)
  # - we allow preserving npm
  # - we want to be somewhat robust to changes in tarball contents, so use find instead of hard-code expected subfolders
  #
  # This code was purist and concise for a long time.
  # Now twice as much code, but using same code path for all uses, and supporting more setups.

  # Copy lib before bin so symlink targets exist.
  # lib
  mkdir -p "$N_PREFIX/lib"
  # Copy everything except node_modules.
  find "$dir/lib" -mindepth 1 -maxdepth 1 \! -name node_modules -exec cp -fR "{}" "$N_PREFIX/lib" \;
  if [[ -z "${N_PRESERVE_NPM}" ]]; then
    mkdir -p "$N_PREFIX/lib/node_modules"
    # Copy just npm, skipping possible added global modules after download. Clean copy to avoid version change problems.
    clean_copy_folder "$dir/lib/node_modules/npm" "$N_PREFIX/lib/node_modules/npm"
  fi
  # Takes same steps for corepack (experimental in node 16.9.0) as for npm, to avoid version problems.
  if [[ -e "$dir/lib/node_modules/corepack" && -z "${N_PRESERVE_COREPACK}" ]]; then
    mkdir -p "$N_PREFIX/lib/node_modules"
    clean_copy_folder "$dir/lib/node_modules/corepack" "$N_PREFIX/lib/node_modules/corepack"
  fi

  # bin
  mkdir -p "$N_PREFIX/bin"
  # Remove old node to avoid potential problems with firewall getting confused on Darwin by overwrite.
  rm -f "$N_PREFIX/bin/node"
  # Copy bin items by hand, in case user has installed global npm modules into cache.
  cp -f "$dir/bin/node" "$N_PREFIX/bin"
  [[ -e "$dir/bin/node-waf" ]] && cp -f "$dir/bin/node-waf" "$N_PREFIX/bin" # v0.8.x
  if [[ -z "${N_PRESERVE_COREPACK}" ]]; then
    [[ -e "$dir/bin/corepack" ]] && cp -fR "$dir/bin/corepack" "$N_PREFIX/bin" # from 16.9.0
  fi
  if [[ -z "${N_PRESERVE_NPM}" ]]; then
    [[ -e "$dir/bin/npm" ]] && cp -fR "$dir/bin/npm" "$N_PREFIX/bin"
    [[ -e "$dir/bin/npx" ]] && cp -fR "$dir/bin/npx" "$N_PREFIX/bin"
  fi

  # include
  mkdir -p "$N_PREFIX/include"
  find "$dir/include" -mindepth 1 -maxdepth 1 -exec cp -fR "{}" "$N_PREFIX/include" \;

  # share
  mkdir -p "$N_PREFIX/share"
  # Copy everything except man, at it is a symlink on some Linux (e.g. archlinux).
  find "$dir/share" -mindepth 1 -maxdepth 1 \! -name man -exec cp -fR "{}" "$N_PREFIX/share" \;
  mkdir -p "$N_PREFIX/share/man"
  find "$dir/share/man" -mindepth 1 -maxdepth 1 -exec cp -fR "{}" "$N_PREFIX/share/man" \;

  disable_pax_mprotect "${installed_node}"

  local active_node="$(command -v node)"
  if [[ -e "${active_node}" && -e "${installed_node}" && "${active_node}" != "${installed_node}" ]]; then
    # Installed and active are different which might be a PATH problem. List both to give user some clues.
    log "installed" "$("${installed_node}" --version) to ${installed_node}"
    log "active" "$("${active_node}" --version) at ${active_node}"
  else
    local npm_version_str=""
    local installed_npm="${N_PREFIX}/bin/npm"
    local active_npm="$(command -v npm)"
    if [[ -z "${N_PRESERVE_NPM}" && -e "${active_npm}" && -e "${installed_npm}" && "${active_npm}" = "${installed_npm}" ]]; then
      npm_version_str=" (with npm $(npm --version))"
    fi

    log "installed" "$("${installed_node}" --version)${npm_version_str}"

    # Extra tips for changed location.
    if [[ -e "${active_node}" && -e "${original_node}" && "${active_node}" != "${original_node}" ]]; then
      printf '\nNote: the node command changed location and the old location may be remembered in your current shell.\n'
      log old "${original_node}"
      log new "${active_node}"
      printf 'If "node --version" shows the old version then start a new shell, or reset the location hash with:\nhash -r  (for bash, zsh, ash, dash, and ksh)\nrehash   (for csh and tcsh)\n'
    fi
  fi
}

#
# Install <version>
#

install() {
  [[ -z "$1" ]] && abort "version required"
  local version
  get_latest_resolved_version "$1" || return 2
  version="${g_target_node}"
  [[ -n "${version}" ]] || abort "no version found for '$1'"
  update_mirror_settings_for_version "$1"
  update_xz_settings_for_version "${version}"
  update_arch_settings_for_version "${version}"

  local dir="${CACHE_DIR}/${g_mirror_folder_name}/${version}"

  # Note: decompression flags ignored with default Darwin tar which autodetects.
  if test "$N_USE_XZ" = "true"; then
    local tarflag="-Jx"
  else
    local tarflag="-zx"
  fi

  if test -d "$dir"; then
    if [[ ! -e "$dir/n.lock" ]] ; then
      if [[ "$DOWNLOAD" == "false" ]] ; then
        activate "${g_mirror_folder_name}/${version}"
      fi
      exit
    fi
  fi

  log installing "${g_mirror_folder_name}-v$version"

  local url="$(tarball_url "$version")"
  is_ok "${url}" || abort "download preflight failed for '$version' (${url})"

  log mkdir "$dir"
  mkdir -p "$dir" || abort "sudo required (or change ownership, or define N_PREFIX)"
  touch "$dir/n.lock"

  cd "${dir}" || abort "Failed to cd to ${dir}"

  log fetch "$url"
  do_get "${url}" | tar "$tarflag" --strip-components=1 --no-same-owner -f -
  pipe_results=( "${PIPESTATUS[@]}" )
  if [[ "${pipe_results[0]}" -ne 0 ]]; then
    abort "failed to download archive for $version"
  fi
  if [[ "${pipe_results[1]}" -ne 0 ]]; then
    abort "failed to extract archive for $version"
  fi
  [ "$GET_SHOWS_PROGRESS" = "true" ] && erase_line
  rm -f "$dir/n.lock"

  disable_pax_mprotect bin/node

  if [[ "$DOWNLOAD" == "false" ]]; then
    activate "${g_mirror_folder_name}/$version"
  fi
}

#
# Be more silent.
#

set_quiet() {
  SHOW_VERBOSE_LOG="false"
  command -v curl > /dev/null && CURL_OPTIONS+=( "--silent" ) && GET_SHOWS_PROGRESS="false"
}

#
# Synopsis: do_get [option...] url
# Call curl or wget with combination of global and passed options.
#

function do_get() {
  if command -v curl &> /dev/null; then
    curl "${CURL_OPTIONS[@]}" "$@"
  elif command -v wget &> /dev/null; then
    wget "${WGET_OPTIONS[@]}" "$@"
  else
    abort "curl or wget command required"
  fi
}

#
# Synopsis: do_get_index [option...] url
# Call curl or wget with combination of global and passed options,
# with options tweaked to be more suitable for getting index.
#

function do_get_index() {
  if command -v curl &> /dev/null; then
    # --silent to suppress progress et al
    curl --silent --compressed "${CURL_OPTIONS[@]}" "$@"
  elif command -v wget &> /dev/null; then
    wget "${WGET_OPTIONS[@]}" "$@"
  else
    abort "curl or wget command required"
  fi
}

#
# Synopsis: remove_versions version ...
#

function remove_versions() {
  [[ -z "$1" ]] && abort "version(s) required"
  while [[ $# -ne 0 ]]; do
    local version
    get_latest_resolved_version "$1" || break
    version="${g_target_node}"
    if [[ -n "${version}" ]]; then
      update_mirror_settings_for_version "$1"
      local dir="${CACHE_DIR}/${g_mirror_folder_name}/${version}"
      if [[ -s "${dir}" ]]; then
        rm -rf "${dir}"
      else
        echo "$1 (${version}) not in downloads cache"
      fi
    else
      echo "No version found for '$1'"
    fi
    shift
  done
}

#
# Synopsis: prune_cache
#

function prune_cache() {
  set_active_node

  for folder_and_version in $(display_versions_paths); do
    if [[ "${folder_and_version}" != "${g_active_node}" ]]; then
      echo "${folder_and_version}"
      rm -rf "${CACHE_DIR:?}/${folder_and_version}"
    fi
  done
}

#
# Synopsis: find_cached_version version
# Finds cache directory for resolved version.
# Globals modified:
# - g_cached_version

function find_cached_version() {
  [[ -z "$1" ]] && abort "version required"
  local version
  get_latest_resolved_version "$1" || exit 1
  version="${g_target_node}"
  [[ -n "${version}" ]] || abort "no version found for '$1'"

  update_mirror_settings_for_version "$1"
  g_cached_version="${CACHE_DIR}/${g_mirror_folder_name}/${version}"
  if [[ ! -d "${g_cached_version}" && "${DOWNLOAD}" == "true" ]]; then
    (install "${version}")
  fi
  [[ -d "${g_cached_version}" ]] || abort "'$1' (${version}) not in downloads cache"
}


#
# Synopsis: display_bin_path_for_version version
#

function display_bin_path_for_version() {
  find_cached_version "$1"
  echo "${g_cached_version}/bin/node"
}

#
# Synopsis: run_with_version version [args...]
# Run the given <version> of node with [args ..]
#

function run_with_version() {
  find_cached_version "$1"
  shift # remove version from parameters
  exec "${g_cached_version}/bin/node" "$@"
}

#
# Synopsis: exec_with_version <version> command [args...]
# Modify the path to include <version> and execute command.
#

function exec_with_version() {
  find_cached_version "$1"
  shift # remove version from parameters
  PATH="${g_cached_version}/bin:$PATH" exec "$@"
}

#
# Synopsis: is_ok url
# Check the HEAD response of <url>.
#

function is_ok() {
  # Note: both curl and wget can follow redirects, as present on some mirrors (e.g. https://npm.taobao.org/mirrors/node).
  # The output is complicated with redirects, so keep it simple and use command status rather than parse output.
  if command -v curl &> /dev/null; then
    do_get --silent --head "$1" > /dev/null || return 1
  else
    do_get --spider "$1" > /dev/null || return 1
  fi
}

#
# Synopsis: can_use_xz
# Test system to see if xz decompression is supported by tar.
#

function can_use_xz() {
  # Be conservative and only enable if xz is likely to work. Unfortunately we can't directly query tar itself.
  # For research, see https://github.com/shadowspawn/nvh/issues/8
  local uname_s="$(uname -s)"
  if [[ "${uname_s}" = "Linux" ]] && command -v xz &> /dev/null ; then
    # tar on linux is likely to support xz if it is available as a command
    return 0
  elif [[ "${uname_s}" = "Darwin" ]]; then
    local macos_version="$(sw_vers -productVersion)"
    local macos_major_version="$(echo "${macos_version}" | cut -d '.' -f 1)"
    local macos_minor_version="$(echo "${macos_version}" | cut -d '.' -f 2)"
    if [[ "${macos_major_version}" -gt 10 || "${macos_minor_version}" -gt 8 ]]; then
      # tar on recent Darwin has xz support built-in
      return 0
    fi
  fi
  return 2 # not supported
}

#
# Synopsis: display_tarball_platform
#

function display_tarball_platform() {
  # https://en.wikipedia.org/wiki/Uname

  local os="unexpected_os"
  local uname_a="$(uname -a)"
  case "${uname_a}" in
    Linux*) os="linux" ;;
    Darwin*) os="darwin" ;;
    SunOS*) os="sunos" ;;
    AIX*) os="aix" ;;
    CYGWIN*) >&2 echo_red "Cygwin is not supported by n" ;;
    MINGW*) >&2 echo_red "Git BASH (MSYS) is not supported by n" ;;
  esac

  local arch="unexpected_arch"
  local uname_m="$(uname -m)"
  case "${uname_m}" in
    x86_64) arch=x64 ;;
    i386 | i686) arch="x86" ;;
    aarch64) arch=arm64 ;;
    armv8l) arch=arm64 ;; # armv8l probably supports arm64, and there is no specific armv8l build so give it a go
    *)
      # e.g. armv6l, armv7l, arm64
      arch="${uname_m}"
      ;;
  esac
    # Override from command line, or version specific adjustment.
  [ -n "$ARCH" ] && arch="$ARCH"

  echo "${os}-${arch}"
}

#
# Synopsis: display_compatible_file_field
# display <file> for current platform, as per <file> field in index.tab, which is different than actual download
#

function display_compatible_file_field {
  local compatible_file_field="$(display_tarball_platform)"
  if [[ -z "${ARCH}" && "${compatible_file_field}" = "darwin-arm64" ]]; then
    # Look for arm64 for native but also x64 for older versions which can run in rosetta.
    # (Downside is will get an install error if install version above 16 with x64 and not arm64.)
    compatible_file_field="osx-arm64-tar|osx-x64-tar"
  elif [[ "${compatible_file_field}" =~ darwin-(.*) ]]; then
    compatible_file_field="osx-${BASH_REMATCH[1]}-tar"
  fi
  echo "${compatible_file_field}"
}

#
# Synopsis: tarball_url version
#

function tarball_url() {
  local version="$1"
  local ext=gz
  [ "$N_USE_XZ" = "true" ] && ext="xz"
  echo "${g_mirror_url}/v${version}/node-v${version}-$(display_tarball_platform).tar.${ext}"
}

#
# Synopsis: get_file_node_version filename
# Sets g_target_node
#

function get_file_node_version() {
  g_target_node=
  local filepath="$1"
  verbose_log "found" "${filepath}"
  # read returns a non-zero status but does still work if there is no line ending
  local version
  <"${filepath}" read -r version
  # trim possible trailing \d from a Windows created file
  version="${version%%[[:space:]]}"
  verbose_log "read" "${version}"
  g_target_node="${version}"
}

#
# Synopsis: get_package_engine_version\
# Sets g_target_node
#

function get_package_engine_version() {
  g_target_node=
  local filepath="$1"
  verbose_log "found" "${filepath}"
  command -v node &> /dev/null || abort "an active version of node is required to read 'engines' from package.json"
  local range
  range="$(node -e "package = require('${filepath}'); if (package && package.engines && package.engines.node) console.log(package.engines.node)")"
  verbose_log "read" "${range}"
  [[ -n "${range}" ]] || return 2
  if [[ "*" == "${range}" ]]; then
    verbose_log "target" "current"
    g_target_node="current"
    return
  fi

  local version
  if [[ "${range}" =~ ^([>~^=]|\>\=)?v?([0-9]+(\.[0-9]+){0,2})(.[xX*])?$ ]]; then
    local operator="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    case "${operator}" in
      '' | =) ;;
      \> | \>=) version="current" ;;
      \~) [[ "${version}" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]] && version="${BASH_REMATCH[1]}" ;;
      ^) [[ "${version}" =~ ^([0-9]+) ]] && version="${BASH_REMATCH[1]}" ;;
    esac
    verbose_log "target" "${version}"
  else
    command -v npx &> /dev/null || abort "an active version of npx is required to use complex 'engine' ranges from package.json"
    verbose_log "resolving" "${range}"
    local version_per_line="$(n lsr --all)"
    local versions_one_line=$(echo "${version_per_line}" | tr '\n' ' ')
    # Using semver@7 so works with older versions of node.
    # shellcheck disable=SC2086
    version=$(npm_config_yes=true npx --quiet semver@7 -r "${range}" ${versions_one_line} | tail -n 1)
  fi
  g_target_node="${version}"
}

#
# Synopsis: get_nvmrc_version
# Sets g_target_node
#

function get_nvmrc_version() {
  g_target_node=
  local filepath="$1"
  verbose_log "found" "${filepath}"
  local version
  <"${filepath}" read -r version
  verbose_log "read" "${version}"
  # Translate from nvm aliases
  case "${version}" in
    lts/\*) version="lts" ;;
    lts/*) version="${version:4}" ;;
    node) version="current" ;;
    *) ;;
  esac
  g_target_node="${version}"
}

#
# Synopsis: get_engine_version [error-message]
# Sets g_target_node
#

function get_engine_version() {
  g_target_node=
  local error_message="${1-package.json not found}"
  local parent
  parent="${PWD}"
  while [[ -n "${parent}" ]]; do
    if [[ -e "${parent}/package.json" ]]; then
      get_package_engine_version "${parent}/package.json"
    else
      parent=${parent%/*}
      continue
    fi
    break
  done
  [[ -n "${parent}" ]] || abort "${error_message}"
  [[ -n "${g_target_node}" ]] || abort "did not find supported version of node in 'engines' field of package.json"
}

#
# Synopsis: get_auto_version
# Sets g_target_node
#

function get_auto_version() {
  g_target_node=
  # Search for a version control file first
  local parent
  parent="${PWD}"
  while [[ -n "${parent}" ]]; do
    if [[ -e "${parent}/.n-node-version" ]]; then
      get_file_node_version "${parent}/.n-node-version"
    elif [[ -e "${parent}/.node-version" ]]; then
      get_file_node_version "${parent}/.node-version"
    elif [[ -e "${parent}/.nvmrc" ]]; then
      get_nvmrc_version "${parent}/.nvmrc"
    else
      parent=${parent%/*}
      continue
    fi
    break
  done
  # Fallback to package.json
  [[ -n "${parent}" ]] || get_engine_version "no file found for auto version (.n-node-version, .node-version, .nvmrc, or package.json)"
  [[ -n "${g_target_node}" ]] || abort "file found for auto did not contain target version of node"
}

#
# Synopsis: get_latest_resolved_version version
# Sets g_target_node
#

function get_latest_resolved_version() {
  g_target_node=
  local version=${1}
  simple_version=${version#node/} # Only place supporting node/ [sic]
  if is_exact_numeric_version "${simple_version}"; then
    # Just numbers, already resolved, no need to lookup first.
    simple_version="${simple_version#v}"
    g_target_node="${simple_version}"
  else
    # Complicated recognising exact version, KISS and lookup.
    g_target_node=$(N_MAX_REMOTE_MATCHES=1 display_remote_versions "$version")
  fi
}

#
# Synopsis: display_remote_index
# index.tab reference: https://github.com/nodejs/nodejs-dist-indexer
# Index fields are: version	date	files	npm	v8	uv	zlib	openssl	modules	lts security
# KISS and just return fields we currently care about: version files lts
#

display_remote_index() {
  local index_url="${g_mirror_url}/index.tab"
  # tail to remove header line
  do_get_index "${index_url}" | tail -n +2 | cut -f 1,3,10
  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    # Reminder: abort will only exit subshell, but consistent error display
    abort "failed to download version index (${index_url})"
  fi
}

#
# Synopsis: display_match_limit limit
#

function display_match_limit(){
  if [[ "$1" -gt 1 && "$1" -lt 32000 ]]; then
    echo "Listing remote... Displaying $1 matches (use --all to see all)."
  fi
}

#
# Synopsis: display_remote_versions version
#

function display_remote_versions() {
  local version="$1"
  update_mirror_settings_for_version "${version}"
  local match='.'
  local match_count="${N_MAX_REMOTE_MATCHES}"

  # Transform some labels before processing further.
  if is_node_support_version "${version}"; then
    version="$(display_latest_node_support_alias "${version}")"
    match_count=1
  elif [[ "${version}" = "auto" ]]; then
    # suppress stdout logging so lsr layout same as usual for scripting
    get_auto_version || return 2
    version="${g_target_node}"
  elif [[ "${version}" = "engine" ]]; then
    # suppress stdout logging so lsr layout same as usual for scripting
    get_engine_version || return 2
    version="${g_target_node}"
  fi

  if [[ -z "${version}" ]]; then
    match='.'
  elif [[ "${version}" = "lts" || "${version}" = "stable" ]]; then
    match_count=1
    # Codename is last field, first one with a name is newest lts
    match="${TAB_CHAR}[a-zA-Z]+\$"
  elif [[ "${version}" = "latest" || "${version}" = "current" ]]; then
    match_count=1
    match='.'
  elif is_numeric_version "${version}"; then
    version="v${version#v}"
    # Avoid restriction message if exact version
    is_exact_numeric_version "${version}" && match_count=1
    # Quote any dots in version so they are literal for expression
    match="${version//\./\.}"
    # Avoid 1.2 matching 1.23
    match="^${match}[^0-9]"
  elif is_lts_codename "${version}"; then
    # Capitalise (could alternatively make grep case insensitive)
    codename="$(echo "${version:0:1}" | tr '[:lower:]' '[:upper:]')${version:1}"
    # Codename is last field
    match="${TAB_CHAR}${codename}\$"
  elif is_download_folder "${version}"; then
    match='.'
  elif is_download_version "${version}"; then
    version="${version#"${g_mirror_folder_name}"/}"
    if [[ "${version}" = "latest" || "${version}" = "current" ]]; then
      match_count=1
      match='.'
    else
      version="v${version#v}"
      match="${version//\./\.}"
      match="^${match}" # prefix
      if is_numeric_version "${version}"; then
        # Exact numeric match
        match="${match}[^0-9]"
      fi
    fi
  else
    abort "invalid version '$1'"
  fi
  display_match_limit "${match_count}"

  # Implementation notes:
  # - using awk rather than head so do not close pipe early on curl
  # - restrict search to compatible files as not always available, or not at same time
  # - return status of curl command (i.e. PIPESTATUS[0])
  display_remote_index \
    | n_grep -E "$(display_compatible_file_field)" \
    | n_grep -E "${match}" \
    | awk "NR<=${match_count}" \
    | cut -f 1 \
    | n_grep -E -o '[^v].*'
  return "${PIPESTATUS[0]}"
}

#
# Synopsis: delete_with_echo target
#

function delete_with_echo() {
  if [[ -e "$1" ]]; then
    echo "$1"
    rm -rf "$1"
  fi
}

#
# Synopsis: uninstall_installed
# Uninstall the installed node and npm (leaving alone the cache),
# so undo install, and may expose possible system installed versions.
#

uninstall_installed() {
  # npm: https://docs.npmjs.com/misc/removing-npm
  #   rm -rf /usr/local/{lib/node{,/.npm,_modules},bin,share/man}/npm*
  # node: https://stackabuse.com/how-to-uninstall-node-js-from-mac-osx/
  # Doing it by hand rather than scanning cache, so still works if cache deleted first.
  # This covers tarballs for at least node 4 through 10.

  while true; do
      read -r -p "Do you wish to delete node and npm from ${N_PREFIX}? " yn
      case $yn in
          [Yy]* ) break ;;
          [Nn]* ) exit ;;
          * ) echo "Please answer yes or no.";;
      esac
  done

  echo ""
  echo "Uninstalling node and npm"
  delete_with_echo "${N_PREFIX}/bin/node"
  delete_with_echo "${N_PREFIX}/bin/npm"
  delete_with_echo "${N_PREFIX}/bin/npx"
  delete_with_echo "${N_PREFIX}/bin/corepack"
  delete_with_echo "${N_PREFIX}/include/node"
  delete_with_echo "${N_PREFIX}/lib/dtrace/node.d"
  delete_with_echo "${N_PREFIX}/lib/node_modules/npm"
  delete_with_echo "${N_PREFIX}/lib/node_modules/corepack"
  delete_with_echo "${N_PREFIX}/share/doc/node"
  delete_with_echo "${N_PREFIX}/share/man/man1/node.1"
  delete_with_echo "${N_PREFIX}/share/systemtap/tapset/node.stp"
}

#
# Synopsis: show_permission_suggestions
#

function show_permission_suggestions() {
  echo "Suggestions:"
  echo "- run n with sudo, or"
  echo "- define N_PREFIX to a writeable location, or"
}

#
# Synopsis: show_diagnostics
# Show environment and check for common problems.
#

function show_diagnostics() {
  echo "This information is to help you diagnose issues, and useful when reporting an issue."
  echo "Note: some output may contain passwords. Redact before sharing."

  printf "\n\nCOMMAND LOCATIONS AND VERSIONS\n"

  printf "\nbash\n"
  command -v bash && bash --version

  printf "\nn\n"
  command -v n && n --version

  printf "\nnode\n"
  if command -v node &> /dev/null; then
    command -v node && node --version
    node -e 'if (process.versions.v8) console.log("JavaScript engine: v8");'

    printf "\nnpm\n"
    command -v npm && npm --version
  fi

  printf "\ntar\n"
  if command -v tar &> /dev/null; then
    command -v tar && tar --version
  else
    echo_red "tar not found. Needed for extracting downloads."
  fi

  printf "\ncurl or wget\n"
  if command -v curl &> /dev/null; then
    command -v curl && curl --version
  elif command -v wget &> /dev/null; then
    command -v wget && wget --version
  else
    echo_red "Neither curl nor wget found. Need one of them for downloads."
  fi

  printf "\nuname\n"
  uname -a

  printf "\n\nSETTINGS\n"

  printf "\nn\n"
  echo "node mirror: ${N_NODE_MIRROR}"
  echo "node downloads mirror: ${N_NODE_DOWNLOAD_MIRROR}"
  echo "install destination: ${N_PREFIX}"
  [[ -n "${N_PREFIX}" ]] && echo "PATH: ${PATH}"
  echo "ls-remote max matches: ${N_MAX_REMOTE_MATCHES}"
   [[ -n "${N_PRESERVE_NPM}" ]] && echo "installs preserve npm by default"
   [[ -n "${N_PRESERVE_COREPACK}" ]] && echo "installs preserve corepack by default"

  printf "\nProxy\n"
  # disable "var is referenced but not assigned": https://github.com/koalaman/shellcheck/wiki/SC2154
  # shellcheck disable=SC2154
  [[ -n "${http_proxy}" ]] && echo "http_proxy: ${http_proxy}"
  # shellcheck disable=SC2154
  [[ -n "${https_proxy}" ]] && echo "https_proxy: ${https_proxy}"
  if command -v curl &> /dev/null; then
    # curl supports lower case and upper case!
    # shellcheck disable=SC2154
    [[ -n "${all_proxy}" ]] && echo "all_proxy: ${all_proxy}"
    [[ -n "${ALL_PROXY}" ]] && echo "ALL_PROXY: ${ALL_PROXY}"
    [[ -n "${HTTP_PROXY}" ]] && echo "HTTP_PROXY: ${HTTP_PROXY}"
    [[ -n "${HTTPS_PROXY}" ]] && echo "HTTPS_PROXY: ${HTTPS_PROXY}"
    if [[ -e "${CURL_HOME}/.curlrc" ]]; then
       echo "have \$CURL_HOME/.curlrc"
    elif [[ -e "${HOME}/.curlrc" ]]; then
      echo "have \$HOME/.curlrc"
    fi
  elif command -v wget &> /dev/null; then
    if [[ -e "${WGETRC}" ]]; then
      echo "have \$WGETRC"
    elif [[ -e "${HOME}/.wgetrc" ]]; then
      echo "have \$HOME/.wgetrc"
    fi
  fi

  printf "\n\nCHECKS\n"

  printf "\nChecking n install destination is in PATH...\n"
  local install_bin="${N_PREFIX}/bin"
  local path_wth_guards=":${PATH}:"
  if [[ "${path_wth_guards}" =~ :${install_bin}/?: ]]; then
    printf "good\n"
  else
    echo_red "'${install_bin}' is not in PATH"
  fi
  if command -v node &> /dev/null; then
    printf "\nChecking n install destination priority in PATH...\n"
    local node_dir="$(dirname "$(command -v node)")"

    local index=0
    local path_entry
    local path_entries
    local install_bin_index=0
    local node_index=999
    IFS=':' read -ra path_entries <<< "${PATH}"
    for path_entry in "${path_entries[@]}"; do
      (( index++ ))
      [[ "${path_entry}" =~ ^${node_dir}/?$ ]] && node_index="${index}"
      [[ "${path_entry}" =~ ^${install_bin}/?$ ]] && install_bin_index="${index}"
    done
    if [[ "${node_index}" -lt "${install_bin_index}" ]]; then
      echo_red "There is a version of node installed which will be found in PATH before the n installed version."
    else
      printf "good\n"
    fi
  fi

  printf "\nChecking permissions for cache folder...\n"
  # Most likely problem is ownership rather than than permissions as such.
  local cache_root="${N_PREFIX}/n"
  if [[ -e "${N_PREFIX}" && ! -w "${N_PREFIX}" && ! -e "${cache_root}" ]]; then
    echo_red "You do not have write permission to create: ${cache_root}"
    show_permission_suggestions
    echo "- make a folder you own:"
    echo "      sudo mkdir -p \"${cache_root}\""
    echo "      sudo chown $(whoami) \"${cache_root}\""
  elif [[ -e "${cache_root}" && ! -w "${cache_root}" ]]; then
    echo_red "You do not have write permission to: ${cache_root}"
    show_permission_suggestions
    echo "- change folder ownership to yourself:"
    echo "      sudo chown -R $(whoami) \"${cache_root}\""
  elif [[ ! -e "${cache_root}" ]]; then
    echo "Cache folder does not exist: ${cache_root}"
    echo "This is normal if you have not done an install yet, as cache is only created when needed."
  elif [[ -e "${CACHE_DIR}" && ! -w "${CACHE_DIR}" ]]; then
    echo_red "You do not have write permission to: ${CACHE_DIR}"
    show_permission_suggestions
    echo "- change folder ownership to yourself:"
    echo "      sudo chown -R $(whoami) \"${CACHE_DIR}\""
  else
    echo "good"
  fi

  if [[ -e "${N_PREFIX}" ]]; then
    # Most likely problem is ownership rather than than permissions as such.
    printf "\nChecking permissions for install folders...\n"
    local install_writeable="true"
    for subdir in bin lib include share; do
      if [[ -e "${N_PREFIX}/${subdir}" && ! -w "${N_PREFIX}/${subdir}" ]]; then
        install_writeable="false"
        echo_red "You do not have write permission to: ${N_PREFIX}/${subdir}"
        break
      fi
    done
    if [[ "${install_writeable}" = "true" ]]; then
      echo "good"
    else
      show_permission_suggestions
      echo "- change folder ownerships to yourself:"
      echo "      (cd \"${N_PREFIX}\" && sudo chown -R $(whoami) bin lib include share)"
    fi
  fi

  printf "\nChecking mirror is reachable...\n"
  if is_ok "${N_NODE_MIRROR}/"; then
    printf "good\n"
  else
    echo_red "mirror not reachable"
    printf "Showing failing command and output\n"
    if command -v curl &> /dev/null; then
      ( set -x; do_get --head "${N_NODE_MIRROR}/" )
    else
      ( set -x; do_get --spider "${N_NODE_MIRROR}/" )
    printf "\n"
   fi
  fi
}

#
# Handle arguments.
#

# First pass. Process the options so they can come before or after commands,
# particularly for `n lsr --all` and `n install --arch x686`
# which feel pretty natural.

unprocessed_args=()
positional_arg="false"

while [[ $# -ne 0 ]]; do
  case "$1" in
    --all) N_MAX_REMOTE_MATCHES=32000 ;;
    -V|--version) display_n_version ;;
    -h|--help|help) display_help; exit ;;
    -q|--quiet) set_quiet ;;
    -d|--download) DOWNLOAD="true" ;;
    --insecure) set_insecure ;;
    -p|--preserve) N_PRESERVE_NPM="true" N_PRESERVE_COREPACK="true" ;;
    --no-preserve) N_PRESERVE_NPM="" N_PRESERVE_COREPACK="" ;;
    --use-xz) N_USE_XZ="true" ;;
    --no-use-xz) N_USE_XZ="false" ;;
    --latest) display_remote_versions latest; exit ;;
    --stable) display_remote_versions lts; exit ;; # [sic] old terminology
    --lts) display_remote_versions lts; exit ;;
    -a|--arch) shift; set_arch "$1";; # set arch and continue
    exec|run|as|use)
      unprocessed_args+=( "$1" )
      positional_arg="true"
      ;;
    *)
      if [[ "${positional_arg}" == "true" ]]; then
        unprocessed_args+=( "$@" )
        break
      fi
      unprocessed_args+=( "$1" )
      ;;
  esac
  shift
done

if [[ -z "${N_USE_XZ+defined}" ]]; then
  N_USE_XZ="true" # Default to using xz
  can_use_xz || N_USE_XZ="false"
fi

set -- "${unprocessed_args[@]}"

if test $# -eq 0; then
  test -z "$(display_versions_paths)" && err_no_installed_print_help
  menu_select_cache_versions
else
  while test $# -ne 0; do
    case "$1" in
      bin|which) display_bin_path_for_version "$2"; exit ;;
      run|as|use) shift; run_with_version "$@"; exit ;;
      exec) shift; exec_with_version "$@"; exit ;;
      doctor) show_diagnostics; exit ;;
      rm|-) shift; remove_versions "$@"; exit ;;
      prune) prune_cache; exit ;;
      latest) install latest; exit ;;
      stable) install stable; exit ;;
      lts) install lts; exit ;;
      ls|list) display_versions_paths; exit ;;
      lsr|ls-remote|list-remote) shift; display_remote_versions "$1"; exit ;;
      uninstall) uninstall_installed; exit ;;
      i|install) shift; install "$1"; exit ;;
      N_TEST_DISPLAY_LATEST_RESOLVED_VERSION) shift; get_latest_resolved_version "$1" > /dev/null || exit 2; echo "${g_target_node}"; exit ;;
      *) install "$1"; exit ;;
    esac
    shift
  done
fi
