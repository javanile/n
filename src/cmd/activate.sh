
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
