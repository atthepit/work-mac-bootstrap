# shellcheck shell=bash
# shellcheck disable=SC2016  # fake bodies are deliberately unexpanded
# shellcheck disable=SC2154  # $output and $BATS_* come from bats
#
# Test fakes.
#
# Every guard in bootstrap.sh reaches the machine through a command looked up
# on PATH, or through $HOME, or through $NIX_DAEMON_PROFILE. A test describes a
# machine by putting fake commands on PATH and pointing those two paths at a
# temporary directory; nothing in bootstrap.sh knows it is being tested.

# sandbox prepares an empty machine: a private HOME, a private PATH whose only
# entries are the fake bin directory and the system directories, and a log
# every fake appends its invocation to.
sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  FAKE_BIN="$SANDBOX/bin"
  FAKE_LOG="$SANDBOX/calls.log"
  mkdir -p "$FAKE_BIN" "$SANDBOX/home"
  : > "$FAKE_LOG"

  export HOME="$SANDBOX/home"
  # This PATH deliberately excludes /usr/local/bin and /opt/homebrew/bin, so
  # the wizard's `#!/usr/bin/env bash` resolves to /bin/bash. On macOS that is
  # bash 3.2, which is what a new Mac ships and what the wizard must survive.
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FAKE_LOG
  # A path that does not exist, so Nix reads as not installed by default.
  export NIX_DAEMON_PROFILE="$SANDBOX/absent/nix-daemon.sh"

  # An Apple Silicon Mac, unless a test says otherwise.
  fake uname 'case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac'

  # A factory-fresh machine: no receipts, no developer tools, no git config.
  fake pkgutil 'exit 1'
  fake xcode-select 'exit 2'
  fake softwareupdate 'exit 0'
  fake git 'exit 1'
  fake ssh-keygen 'exit 0'
  fake curl 'exit 0'
  fake sudo 'exit 0'
  fake scutil 'echo test-mac'

  fake_nix_absent
}

# fake NAME BODY writes an executable NAME onto the sandbox PATH. BODY is bash
# run with the fake's own arguments; the call is logged before BODY runs.
fake() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> "$FAKE_LOG"\n' "$name"
    printf '%s\n' "$body"
  } > "$FAKE_BIN/$name"
  chmod +x "$FAKE_BIN/$name"
}

# fake_nix_absent removes nix from the sandbox, so the machine reads as one
# that has never had Nix installed.
fake_nix_absent() {
  rm -f "$FAKE_BIN/nix"
}

# fake_nix_present installs a nix that dispatches `nix run <flake>#<attr> --
# args` to a fake named <attr>, the way the real one dispatches to a real
# package. Ephemeral tooling is therefore described by faking `gh`, not `nix`.
fake_nix_present() {
  cat > "$FAKE_BIN/nix" <<'NIX'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >> "$FAKE_LOG"
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
  if [[ ${args[i]} == run ]]; then
    ref="${args[i+1]}"
    attr="${ref##*#}"
    rest=("${args[@]:i+2}")
    if [[ ${#rest[@]} -gt 0 && ${rest[0]} == -- ]]; then
      rest=("${rest[@]:1}")
    fi
    exec "$attr" "${rest[@]}"
  fi
done
exit 0
NIX
  chmod +x "$FAKE_BIN/nix"

  # The daemon profile exists once Nix is installed.
  mkdir -p "$(dirname "$NIX_DAEMON_PROFILE")"
  printf '%s\n' '# fake nix daemon profile' > "$NIX_DAEMON_PROFILE"
}

# fake_gh AUTH_EXIT [SSH_KEY_LIST_OUTPUT] installs the one gh fake these tests
# need: whether an account is signed in, and what keys GitHub knows about.
fake_gh() {
  local auth_exit="$1" ssh_keys="${2:-}"
  fake gh "
case \"\$1 \${2:-}\" in
  \"auth status\") exit $auth_exit ;;
  \"ssh-key list\") printf '%s' '$ssh_keys' ;;
  *) exit 0 ;;
esac"
}

# fake_gh_authenticated: signed in, with no key registered.
fake_gh_authenticated() { fake_gh 0; }

# fake_gh_signed_out: no account.
fake_gh_signed_out() { fake_gh 1; }

# clt_installed marks the Command Line Tools as present.
clt_installed() {
  fake xcode-select 'echo /Library/Developer/CommandLineTools'
  fake pkgutil 'case "${1:-}" in *CLTools_Executables) exit 0 ;; *) exit 1 ;; esac'
}

# everything_installed describes a machine that has already been bootstrapped.
everything_installed() {
  clt_installed
  fake pkgutil 'exit 0'
  fake_nix_present
  fake git 'case "$*" in *credential*) echo "!gh auth git-credential" ;; *) exit 0 ;; esac'
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAA test\n' > "$HOME/.ssh/id_ed25519.pub"
  printf 'PRIVATE\n' > "$HOME/.ssh/id_ed25519"
  fake ssh-keygen 'echo "256 SHA256:deadbeef test (ED25519)"'
  fake_gh 0 'test  ssh-ed25519 AAAA  SHA256:deadbeef  authentication'
}

# bootstrapped_clone NAME puts a clone at $HOME/NAME that already provides the
# bootstrap.sh this wizard hands over to.
bootstrapped_clone() {
  mkdir -p "$HOME/$1/.git"
  printf '#!/usr/bin/env bash\n' > "$HOME/$1/bootstrap.sh"
  chmod +x "$HOME/$1/bootstrap.sh"
}

# plan runs bootstrap.sh in dry-run mode and captures its output.
plan() {
  run "$BOOTSTRAP" --dry-run "$@"
}

# plan_ids prints the phase identifiers, in the order the plan lists them.
plan_ids() {
  printf '%s\n' "$output" | sed -n 's/^ *\[ *[0-9]*\] \([a-z-]*\) .*/\1/p'
}

# phase_status ID prints RUN or SKIP for that phase.
phase_status() {
  printf '%s\n' "$output" | sed -n "s/^ *\[ *[0-9]*\] $1  *\([A-Z]*\).*/\1/p"
}
