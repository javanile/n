
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
