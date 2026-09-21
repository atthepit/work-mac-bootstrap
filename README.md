# work-mac-bootstrap

Takes a factory-fresh Mac from the state it arrives in to a clone of your
configuration repository, then hands over to that repository's own
`bootstrap.sh`.

This half knows nothing about any particular configuration. It takes the
repository to clone as its only argument — or asks you which one, from a list
— so it never needs changing when the configuration it serves does.

## Use it

```sh
curl -fsSL https://raw.githubusercontent.com/atthepit/work-mac-bootstrap/v1/bootstrap.sh \
  | bash -s -- owner/repo
```

Pin to a release tag, as above, rather than to a branch: the command runs as
you, with sudo, so an unfinished commit on `main` should not be able to.

See the plan without running any of it:

```sh
curl -fsSL https://raw.githubusercontent.com/atthepit/work-mac-bootstrap/v1/bootstrap.sh \
  | bash -s -- --dry-run owner/repo
```

Leave the slug off and the wizard lists the repositories on your GitHub
account once you have signed in, and asks which one to clone:

```sh
curl -fsSL https://raw.githubusercontent.com/atthepit/work-mac-bootstrap/v1/bootstrap.sh \
  | bash -s
```

The slug is the only argument either way, and the clone lands in
`$HOME/<repo>`.

| Option | Meaning |
| --- | --- |
| `-n`, `--dry-run` | Print the plan and exit, executing nothing. |
| `-h`, `--help` | Usage. |

A dry run reads the machine, downloads nothing and makes nobody wait. That is
worth knowing when you read its output: the two phases that need `gh` to
answer will use a `gh` the machine already has, but will not fetch one, so on
a machine without it they report as needed rather than claiming to know.

## What it does

Ten phases, in dependency order. Each one first checks whether its effect is
already present and skips if so, which is what makes a re-run after an
interrupted attempt cost seconds instead of starting over. Resumability is by
guard, never by a state file: a state file lies the moment something is fixed
by hand outside the wizard.

| Phase | Guard: skipped when | Otherwise |
| --- | --- | --- |
| `command-line-tools` | `xcode-select -p` answers and the `CLTools_Executables` package receipt is present | Opens the Apple installer dialog for you to click, then polls the receipt until it lands |
| `rosetta` | Not Apple Silicon, or the Rosetta receipt is present | `softwareupdate --install-rosetta`, licence accepted |
| `nix` | `nix` is on `PATH`, or the daemon profile exists | Installs Nix from the upstream installer, in daemon mode, unattended |
| `nix-profile` | `nix` is on this shell's `PATH` | Sources the daemon profile, so the running script gains Nix without a new terminal |
| `github-auth` | `gh auth status` reports an account | Signs in through the browser with a one-time code |
| `git-credentials` | A credential helper for github.com is configured | Points git at that sign-in |
| `ssh-key` | `~/.ssh/id_ed25519` is registered with your account | Generates an ed25519 key and registers it |
| `choose-repository` | A repository was named on the command line | Lists your repositories and asks which one to clone |
| `clone` | The destination is already a git repository | Clones the repository |
| `handoff` | Never | `exec`s `bootstrap.sh` from the clone root |

The picker sits where it does because listing repositories needs the GitHub
sign-in, and nothing before the clone needs to know which repository you
meant. It accepts a number from the list or a typed `owner/repo`, so a
repository you do not own — and which therefore is not on the list — is still
reachable.

Two properties worth stating plainly, because they are the reason to trust the
command with sudo:

- **No token is ever created or pasted.** GitHub sign-in is the browser flow;
  you type a one-time code into a page you opened yourself.
- **Nothing is installed outside your configuration.** The wizard owns no
  tooling. `gh` is used from the machine if it is already there and otherwise
  run ephemerally through `nix run`; `git` comes from the Command Line Tools,
  which Apple installs. Nothing else is added, so your machine ends up with
  exactly what your configuration says it should have.

## The handoff convention

The last thing this wizard does is `exec bootstrap.sh` at the root of the
clone, with the clone as the working directory — what takes over is a
configuration, and a configuration is entitled to assume it is being run from
its own root. That file is the entire contract between the two halves: a
configuration repository is bootstrappable by this wizard if it provides an
executable `bootstrap.sh` at its root that can be run with no arguments.

Everything from that point on belongs to the configuration — it knows what it
needs, and this wizard should not.

If the clone has no `bootstrap.sh`, the wizard says so and stops, leaving you
with a cloned repository and a working machine.

## Tests

The dry-run plan is the contract, so the tests assert on it: phase order, the
guard each phase consults, and how each guard reads on a fresh machine, a
partly-configured one, and one that has already been bootstrapped.

```sh
bats tests            # or: nix run nixpkgs#bats -- tests
shellcheck bootstrap.sh tests/helpers/fakes.bash
bash -n bootstrap.sh
```

No test runs an installer and none needs a spare Mac. Every guard reaches the
machine through a command on `PATH`, through `$HOME`, or through
`$NIX_DAEMON_PROFILE`; a test describes a machine by putting fake commands on
`PATH` and pointing those at a temporary directory. The script has no idea it
is being tested. `tests/helpers/fakes.bash` is where a new kind of machine gets
described.

CI runs the lint and the suite on both Linux and macOS. The macOS run matters:
a new Mac ships with bash 3.2, and the wizard has to work there. The sandbox
`PATH` in `fakes.bash` deliberately excludes Homebrew, so `#!/usr/bin/env bash`
resolves to `/bin/bash` — meaning the macOS suite is a bash 3.2 run, not a
bash 5 one. CI also checks the syntax through `/bin/bash` directly, so that
property cannot quietly lapse.

## Structure

`bootstrap.sh` is generated with a wizard skill. Everything above the `STAGES`
marker is that skill's shared library, unedited — it is identical in every
wizard, which is the point of it. The phases below the marker are this
wizard's own. A few of the library's helpers go unused here; leave them be
rather than trimming the library out of step with the skill.

## Licence

MIT. See [LICENSE](LICENSE).
