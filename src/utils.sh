
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
