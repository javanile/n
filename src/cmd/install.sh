
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
