
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
