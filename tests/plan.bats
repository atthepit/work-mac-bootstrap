#!/usr/bin/env bats
#
# The dry-run plan is the contract this repository is tested against: what the
# wizard will do, in what order, and which guard decides whether each phase is
# needed. These tests assert on that plan. Nothing here runs an installer.

load helpers/fakes

setup() {
  BOOTSTRAP="$BATS_TEST_DIRNAME/../bootstrap.sh"
  sandbox
}

# ── Arguments ─────────────────────────────────────────────────────────────

@test "runs without a repository slug, planning to ask for one instead" {
  plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"chosen from your GitHub account after sign-in"* ]]
}

@test "refuses a slug that is not owner/repo" {
  run "$BOOTSTRAP" --dry-run notaslug
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner/repo"* ]]
}

@test "--help explains the entry command and exits cleanly" {
  run "$BOOTSTRAP" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"owner/repo"* ]]
}

@test "refuses to run on anything but macOS" {
  fake uname 'echo Linux'
  plan owner/repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS"* ]]
}

# ── Plan shape ────────────────────────────────────────────────────────────

@test "the plan lists every phase in dependency order" {
  plan owner/repo
  [ "$status" -eq 0 ]
  [ "$(plan_ids)" = "command-line-tools
rosetta
nix
nix-profile
github-auth
git-credentials
ssh-key
choose-repository
clone
handoff" ]
}

@test "the plan names the repository and where it will be cloned" {
  plan owner/config-repo
  [[ "$output" == *"owner/config-repo"* ]]
  [[ "$output" == *"$HOME/config-repo"* ]]
}

@test "the repository slug is the only argument taken" {
  run "$BOOTSTRAP" --dry-run owner/repo extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected argument"* ]]
}

@test "the plan states that nothing was executed" {
  plan owner/repo
  [[ "$output" == *"Nothing was executed"* ]]
}

@test "a dry run executes no fake command that changes the machine" {
  plan owner/repo
  run grep -E '^(xcode-select --install|softwareupdate|curl|git clone|sudo)' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "every phase states the guard that decides whether it runs" {
  plan owner/repo
  local guards
  guards=$(printf '%s\n' "$output" | grep -c 'guard:')
  [ "$guards" -eq 10 ]
}

# ── Guards: a factory-fresh machine ───────────────────────────────────────

@test "on a fresh machine every phase runs" {
  plan owner/repo
  [ "$(phase_status command-line-tools)" = RUN ]
  [ "$(phase_status rosetta)" = RUN ]
  [ "$(phase_status nix)" = RUN ]
  [ "$(phase_status nix-profile)" = RUN ]
  [ "$(phase_status github-auth)" = RUN ]
  [ "$(phase_status git-credentials)" = RUN ]
  [ "$(phase_status ssh-key)" = RUN ]
  [ "$(phase_status clone)" = RUN ]
  [ "$(phase_status handoff)" = RUN ]
  # The exception: a slug was given, so there is nothing to choose.
  [ "$(phase_status choose-repository)" = SKIP ]
}

@test "a fresh machine is told the Command Line Tools dialog needs a click" {
  plan owner/repo
  [[ "$output" == *"xcode-select --install"* ]]
  [[ "$output" == *"receipt"* ]]
}

@test "the GitHub phase promises a browser sign-in and no access token" {
  plan owner/repo
  [[ "$output" == *"browser"* ]]
  [[ "$output" == *"one-time code"* ]]
  [[ "$output" != *"personal access token"* ]]
}

@test "the repository is taken only from the argument, never baked in" {
  plan alpha/one
  [[ "$output" == *"alpha/one"* ]]
  plan beta/two
  [[ "$output" == *"beta/two"* ]]
  [[ "$output" != *"alpha/one"* ]]
}

# ── Guards: a machine that is partly or wholly set up ─────────────────────

@test "the Command Line Tools phase is skipped once the receipt is present" {
  clt_installed
  plan owner/repo
  [ "$(phase_status command-line-tools)" = SKIP ]
}

@test "Rosetta is skipped on Intel hardware" {
  fake uname 'case "${1:-}" in -m) echo x86_64 ;; *) echo Darwin ;; esac'
  plan owner/repo
  [ "$(phase_status rosetta)" = SKIP ]
  [[ "$output" == *"Apple Silicon"* ]]
}

@test "Rosetta is skipped once its receipt is present" {
  fake pkgutil 'case "${1:-}" in *Rosetta*) exit 0 ;; *) exit 1 ;; esac'
  plan owner/repo
  [ "$(phase_status rosetta)" = SKIP ]
}

@test "the Nix install is skipped once the daemon profile exists" {
  fake_nix_present
  plan owner/repo
  [ "$(phase_status nix)" = SKIP ]
}

@test "sourcing the daemon profile is skipped once nix is on PATH" {
  fake_nix_present
  plan owner/repo
  [ "$(phase_status nix-profile)" = SKIP ]
}

@test "sourcing the daemon profile still runs when Nix is installed but absent from this shell" {
  fake_nix_present
  rm -f "$FAKE_BIN/nix"
  plan owner/repo
  [ "$(phase_status nix)" = SKIP ]
  [ "$(phase_status nix-profile)" = RUN ]
}

@test "GitHub sign-in is not probed while Nix is missing" {
  plan owner/repo
  [ "$(phase_status github-auth)" = RUN ]
  run grep -q '^gh ' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "GitHub sign-in is skipped once gh reports an authenticated account" {
  fake_nix_present
  fake_gh_authenticated
  plan owner/repo
  [ "$(phase_status github-auth)" = SKIP ]
}

@test "GitHub sign-in runs when gh reports no account" {
  fake_nix_present
  fake_gh_signed_out
  plan owner/repo
  [ "$(phase_status github-auth)" = RUN ]
}

@test "the credential helper is skipped once git is configured to use gh" {
  fake_nix_present
  fake_gh_authenticated
  fake git 'case "$*" in *credential*) echo "!gh auth git-credential" ;; *) exit 1 ;; esac'
  plan owner/repo
  [ "$(phase_status git-credentials)" = SKIP ]
}

@test "the SSH key phase runs when a key exists but GitHub does not know it" {
  fake_nix_present
  fake_gh_authenticated
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAA test\n' > "$HOME/.ssh/id_ed25519.pub"
  fake ssh-keygen 'echo "256 SHA256:deadbeef test (ED25519)"'
  plan owner/repo
  [ "$(phase_status ssh-key)" = RUN ]
}

@test "the SSH key phase is skipped once the key is registered with GitHub" {
  everything_installed
  plan owner/repo
  [ "$(phase_status ssh-key)" = SKIP ]
}

@test "the clone is skipped when the destination is already a git repository" {
  mkdir -p "$HOME/repo/.git"
  plan owner/repo
  [ "$(phase_status clone)" = SKIP ]
}

@test "the handoff is never skipped" {
  everything_installed
  bootstrapped_clone repo
  plan owner/repo
  [ "$(phase_status handoff)" = RUN ]
}

@test "an already-bootstrapped machine skips everything but the handoff" {
  everything_installed
  bootstrapped_clone repo
  plan owner/repo
  local runs
  runs=$(printf '%s\n' "$output" | grep -c ' RUN')
  [ "$runs" -eq 1 ]
}

# ── Choosing the repository ───────────────────────────────────────────────

@test "choosing is skipped when the repository was named on the command line" {
  plan owner/repo
  [ "$(phase_status choose-repository)" = SKIP ]
  [[ "$output" == *"owner/repo was named on the command line"* ]]
}

@test "choosing runs when no repository was named" {
  plan
  [ "$(phase_status choose-repository)" = RUN ]
  [[ "$output" == *"list the repositories on your GitHub account"* ]]
}

@test "with nothing named, the plan says where the clone will land is not yet known" {
  plan
  [[ "$output" == *"$HOME/<the repository you choose>"* ]]
}

@test "choosing happens after sign-in, since listing needs it, and before the clone" {
  plan
  local ids auth_at choose_at clone_at
  ids=$(plan_ids)
  auth_at=$(printf '%s\n' "$ids" | grep -n '^github-auth$' | cut -d: -f1)
  choose_at=$(printf '%s\n' "$ids" | grep -n '^choose-repository$' | cut -d: -f1)
  clone_at=$(printf '%s\n' "$ids" | grep -n '^clone$' | cut -d: -f1)
  [ "$auth_at" -lt "$choose_at" ]
  [ "$choose_at" -lt "$clone_at" ]
}

@test "a malformed slug is still refused rather than treated as absent" {
  run "$BOOTSTRAP" --dry-run notaslug
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner/repo"* ]]
}

# ── The handoff contract ──────────────────────────────────────────────────

@test "the handoff execs bootstrap.sh at the clone root" {
  plan owner/repo
  [[ "$output" == *"$HOME/repo/bootstrap.sh"* ]]
}

@test "the handoff warns when the cloned repository has no bootstrap.sh" {
  everything_installed
  mkdir -p "$HOME/repo/.git"
  plan owner/repo
  [[ "$output" == *"bootstrap.sh"* ]]
  [[ "$output" == *"not"* ]]
}

@test "the handoff hands over from inside the clone" {
  plan owner/repo
  [[ "$output" == *"from $HOME/repo"* ]]
}

@test "the Command Line Tools guard states both of its checks" {
  plan owner/repo
  [[ "$output" == *"xcode-select -p"* ]]
  [[ "$output" == *"pkgutil --pkg-info=com.apple.pkg.CLTools_Executables"* ]]
}

@test "a dry run never fetches ephemeral tooling" {
  fake_nix_present
  fake_gh_authenticated
  plan owner/repo
  # A gh is already here, so nothing is fetched to ask it anything.
  run grep -q '^nix ' "$FAKE_LOG"
  [ "$status" -ne 0 ]
  run grep -q '^gh auth status' "$FAKE_LOG"
  [ "$status" -eq 0 ]
}

@test "a dry run with Nix but no gh reports the gh phases rather than fetching one" {
  fake_nix_present
  rm -f "$FAKE_BIN/gh"
  plan owner/repo
  [ "$(phase_status github-auth)" = RUN ]
  [ "$(phase_status ssh-key)" = RUN ]
  run grep -q '^nix ' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "a failure names the phase and says a re-run is safe" {
  # The error trap must be reachable from inside an action, which needs
  # errtrace: without it a failing action exits silently.
  run grep -qE '^set -E' "$BOOTSTRAP"
  [ "$status" -eq 0 ]
  run grep -q 'trap on_error ERR' "$BOOTSTRAP"
  [ "$status" -eq 0 ]
}

# ── Ordering constraints the plan must never lose ─────────────────────────

@test "Nix is installed before anything that needs ephemeral tooling" {
  plan owner/repo
  local ids
  ids=$(plan_ids)
  local nix_at github_at
  nix_at=$(printf '%s\n' "$ids" | grep -n '^nix$' | cut -d: -f1)
  github_at=$(printf '%s\n' "$ids" | grep -n '^github-auth$' | cut -d: -f1)
  [ "$nix_at" -lt "$github_at" ]
}

@test "the clone happens after authentication and before the handoff" {
  plan owner/repo
  local ids
  ids=$(plan_ids)
  local auth_at clone_at handoff_at
  auth_at=$(printf '%s\n' "$ids" | grep -n '^github-auth$' | cut -d: -f1)
  clone_at=$(printf '%s\n' "$ids" | grep -n '^clone$' | cut -d: -f1)
  handoff_at=$(printf '%s\n' "$ids" | grep -n '^handoff$' | cut -d: -f1)
  [ "$auth_at" -lt "$clone_at" ]
  [ "$clone_at" -lt "$handoff_at" ]
}

@test "the Command Line Tools come before the clone, which needs git" {
  plan owner/repo
  local ids
  ids=$(plan_ids)
  local clt_at clone_at
  clt_at=$(printf '%s\n' "$ids" | grep -n '^command-line-tools$' | cut -d: -f1)
  clone_at=$(printf '%s\n' "$ids" | grep -n '^clone$' | cut -d: -f1)
  [ "$clt_at" -lt "$clone_at" ]
}
