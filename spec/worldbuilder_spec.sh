Describe 'worldbuilder clone'
  WB="$PWD/worldbuilder"

  BeforeEach 'tmp=$(mktemp -d); mkdir -p "$tmp/bin"'
  AfterEach 'rm -rf "$tmp"'

  setup_stubs() {
    cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
cat
EOF
    cat >"$tmp/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
if [ "$1" = clone ]; then
  mkdir -p "$3"
fi
EOF
    chmod +x "$tmp/bin/fzf" "$tmp/bin/git"
  }

  run_clone() {
    env WORLDBUILDER_FILE="$tmp/wb.toml" GIT_LOG="$tmp/git.log" PATH="$tmp/bin:$PATH" zsh "$WB" clone demo
  }

  It 'keeps a string repo as origin'
    setup_stubs
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = "git@example.test:demo.git"
dir = "$tmp/checkout"
EOF
    When call run_clone
    The status should be success
    The contents of file "$tmp/git.log" should include 'clone git@example.test:demo.git'
  End

  It 'clones origin and adds named remotes from a map'
    setup_stubs
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = { upstream = "git@example.test:upstream.git", origin = "git@example.test:demo.git" }
dir = "$tmp/checkout"
EOF
    When call run_clone
    The status should be success
    The contents of file "$tmp/git.log" should include 'clone git@example.test:demo.git'
    The contents of file "$tmp/git.log" should include 'remote add upstream git@example.test:upstream.git'
  End

  It 'rejects a repo map without origin before cloning'
    setup_stubs
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = { upstream = "git@example.test:upstream.git" }
dir = "$tmp/checkout"
EOF
    When call run_clone
    The status should equal 2
    The stderr should include 'Invalid repo map'
  End
End

Describe 'worldbuilder doctor'
  WB="$PWD/worldbuilder"

  BeforeEach 'tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/home"; for tool in mlr fzf trivy docker; do ln -s /usr/bin/true "$tmp/bin/$tool"; done'
  AfterEach 'rm -rf "$tmp"'

  run_doctor() {
    env HOME="$tmp/home" WORLDBUILDER_FILE="$tmp/wb.toml" PATH="$tmp/bin:$PATH" zsh "$WB" doctor
  }

  remote_extra() { git -C "$tmp/checkout" remote get-url extra; }
  remote_origin() { git -C "$tmp/checkout" remote get-url origin; }

  It 'accepts a checkout with the configured remotes and leaves extra remotes alone'
    git init -q "$tmp/checkout"
    git -C "$tmp/checkout" remote add origin git@example.test:demo.git
    git -C "$tmp/checkout" remote add upstream git@example.test:upstream.git
    git -C "$tmp/checkout" remote add extra git@example.test:extra.git
    cat >"$tmp/wb.toml" <<EOF
[demo]
dir = "$tmp/checkout"
repo = { origin = "git@example.test:demo.git", upstream = "git@example.test:upstream.git" }
EOF
    When call run_doctor
    The status should be success
    The output should include 'look good'
    The stderr should be blank
    The result of function remote_extra should equal 'git@example.test:extra.git'
  End

  It 'warns about a missing checkout without requiring a repo'
    cat >"$tmp/wb.toml" <<EOF
[demo]
dir = "$tmp/not-cloned"
EOF
    When call run_doctor
    The status should be success
    The stderr should include '[demo] checkout directory is missing'
    The output should include 'warnings'
  End

  It 'warns about missing and mismatched remotes without modifying them'
    git init -q "$tmp/checkout"
    git -C "$tmp/checkout" remote add origin git@example.test:other.git
    cat >"$tmp/wb.toml" <<EOF
[demo]
dir = "$tmp/checkout"
repo = { origin = "git@example.test:demo.git", upstream = "git@example.test:upstream.git" }
EOF
    When call run_doctor
    The status should be success
    The stderr should include '[demo] remote URL differs from config: origin'
    The stderr should include '[demo] missing remote: upstream'
    The output should include 'warnings'
    The result of function remote_origin should equal 'git@example.test:other.git'
  End

  It 'warns when a directory is inside another checkout'
    git init -q "$tmp/parent"
    mkdir -p "$tmp/parent/nested"
    cat >"$tmp/wb.toml" <<EOF
[demo]
dir = "$tmp/parent/nested"
EOF
    When call run_doctor
    The status should be success
    The stderr should include '[demo] directory is inside a Git checkout, not its root'
    The output should include 'warnings'
  End

  It 'reports invalid sections and repo maps in one run'
    cat >"$tmp/wb.toml" <<EOF
bad_section = "not a section"
[bad_repo]
dir = "$tmp/not-cloned"
repo = { upstream = "git@example.test:upstream.git" }
[bad_key]
"bad-key" = "value"
dir = 42
EOF
    When call run_doctor
    The status should equal 1
    The stderr should include 'Invalid worldbuilder section [bad_section]'
    The stderr should include 'Invalid repo map for [bad_repo]'
    The stderr should include 'Invalid worldbuilder key [bad_key].bad-key'
    The stderr should include 'Invalid dir for [bad_key]'
  End

  It 'rejects malformed configuration'
    printf '[demo\n' >"$tmp/wb.toml"
    When call run_doctor
    The status should equal 1
    The stderr should include 'Invalid worldbuilder config'
  End

  It 'supports INI files and warns about non-Git directories'
    mkdir -p "$tmp/checkout"
    cat >"$tmp/wb.ini" <<EOF
[demo]
dir=$tmp/checkout
repo=git@example.test:demo.git
EOF
    When call env HOME="$tmp/home" WORLDBUILDER_FILE="$tmp/wb.ini" PATH="$tmp/bin:$PATH" zsh "$WB" doctor
    The status should be success
    The stderr should include '[demo] is not a Git checkout'
    The output should include 'warnings'
  End
End

Describe 'worldbuilder push'
  WB="$PWD/worldbuilder"

  BeforeEach 'tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/checkout"'
  AfterEach 'rm -rf "$tmp"'

  setup_push_stubs() {
    cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
cat
EOF
    cat >"$tmp/bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = -C ]; then shift 2; fi
case "$1" in
  symbolic-ref) printf 'feature\n' ;;
  show-ref)
    case "$4" in
      refs/heads/stable|refs/heads/main) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  check-ref-format) printf '%s\n' "$3" ;;
  push)
    printf '%s\n' "$*" >>"$GIT_LOG"
    case "$4" in *refs/heads/bad:*) exit 1 ;; esac
    ;;
esac
EOF
    chmod +x "$tmp/bin/fzf" "$tmp/bin/git"
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = "git@example.test:demo.git"
dir = "$tmp/checkout"
EOF
  }

  run_push() {
    env WORLDBUILDER_FILE="$tmp/wb.toml" GIT_LOG="$tmp/git.log" PATH="$tmp/bin:$PATH" zsh "$WB" push "$@"
  }

  It 'tries every requested branch and warns for each failure'
    setup_push_stubs
    When call run_push demo --remote=upstream --also first bad main
    The status should equal 1
    The stderr should include "Failed to push branch 'bad' to 'upstream'"
    The contents of file "$tmp/git.log" should include 'push -- upstream refs/heads/first:refs/heads/first'
    The contents of file "$tmp/git.log" should include 'push -- upstream refs/heads/bad:refs/heads/bad'
    The contents of file "$tmp/git.log" should include 'push -- upstream refs/heads/main:refs/heads/main'
    The contents of file "$tmp/git.log" should include 'push -- upstream refs/heads/stable:refs/heads/stable'
  End

  It 'pushes the current branch and common local branches by default'
    setup_push_stubs
    When call run_push demo --also
    The status should be success
    The contents of file "$tmp/git.log" should include 'push -- origin refs/heads/feature:refs/heads/feature'
    The contents of file "$tmp/git.log" should include 'push -- origin refs/heads/stable:refs/heads/stable'
    The contents of file "$tmp/git.log" should include 'push -- origin refs/heads/main:refs/heads/main'
  End
End

Describe 'worldbuilder update --remote'
  WB="$PWD/worldbuilder"

  BeforeEach 'setup_update_repos'
  AfterEach 'rm -rf "$tmp"'

  setup_update_repos() {
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/home"
    cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
cat
EOF
    chmod +x "$tmp/bin/fzf"
    export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

    git init -q --bare "$tmp/origin.git"
    git init -q --bare "$tmp/upstream.git"
    git init -q -b main "$tmp/seed"
    git -C "$tmp/seed" config user.name 'Worldbuilder test'
    git -C "$tmp/seed" config user.email 'test@example.test'
    printf 'base\n' >"$tmp/seed/tracked"
    git -C "$tmp/seed" add tracked
    git -C "$tmp/seed" commit -q -m base
    base=$(git -C "$tmp/seed" rev-parse HEAD)
    git -C "$tmp/seed" remote add origin "$tmp/origin.git"
    git -C "$tmp/seed" remote add upstream "$tmp/upstream.git"
    git -C "$tmp/seed" push -q origin main
    git -C "$tmp/seed" push -q upstream main
    git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$tmp/origin.git" "$tmp/checkout"
    git -C "$tmp/checkout" config user.name 'Worldbuilder test'
    git -C "$tmp/checkout" config user.email 'test@example.test'
    git -C "$tmp/checkout" remote add upstream "$tmp/upstream.git"

    git -C "$tmp/seed" commit -q --allow-empty -m origin
    git -C "$tmp/seed" push -q origin main
    git -C "$tmp/seed" reset -q --hard "$base"
    git -C "$tmp/seed" commit -q --allow-empty -m upstream
    upstream_tip=$(git -C "$tmp/seed" rev-parse HEAD)
    git -C "$tmp/seed" push -q upstream main
    write_update_config "$tmp/upstream.git"
  }

  write_update_config() {
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = { origin = "$tmp/origin.git", upstream = "$1" }
dir = "$tmp/checkout"
commit = "main"
EOF
  }

  run_update() {
    env WORLDBUILDER_FILE="$tmp/wb.toml" PATH="$tmp/bin:$PATH" zsh -f "$WB" update demo "$@"
  }

  branch_tip() { git -C "$tmp/checkout" rev-parse refs/heads/main; }
  current_branch() { git -C "$tmp/checkout" branch --show-current; }
  tracking_remote() { git -C "$tmp/checkout" config branch.main.remote; }
  upstream_url() { git -C "$tmp/checkout" remote get-url upstream 2>/dev/null; }
  upstream_tracking_tip() { git -C "$tmp/checkout" rev-parse refs/remotes/upstream/main; }
  remote_names() { git -C "$tmp/checkout" remote; }

  It 'updates the checked-out branch from the selected remote instead of its configured upstream'
    When call run_update --remote=upstream
    The status should be success
    The result of function branch_tip should equal "$upstream_tip"
    The result of function current_branch should equal 'main'
    The result of function tracking_remote should equal 'origin'
  End

  It 'adds a missing selected remote from the section repo map'
    git -C "$tmp/checkout" remote remove upstream
    When call run_update --remote=upstream
    The status should be success
    The result of function upstream_url should equal "$tmp/upstream.git"
    The result of function branch_tip should equal "$upstream_tip"
    The result of function tracking_remote should equal 'origin'
  End

  It 'finds a missing remote when the config path is relative'
    git -C "$tmp/checkout" remote remove upstream
    When call env WORLDBUILDER_FILE=wb.toml PATH="$tmp/bin:$PATH" zsh -f -c 'cd "$1" && exec zsh -f "$2" update demo --remote=upstream' zsh "$tmp" "$WB"
    The status should be success
    The result of function upstream_url should equal "$tmp/upstream.git"
    The result of function branch_tip should equal "$upstream_tip"
  End

  It 'adds and fetches the selected remote when no commit is configured'
    git -C "$tmp/checkout" remote remove upstream
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = { origin = "$tmp/origin.git", upstream = "$tmp/upstream.git" }
dir = "$tmp/checkout"
commit = ""
EOF
    When call run_update --remote=upstream
    The status should be success
    The result of function upstream_url should equal "$tmp/upstream.git"
    The result of function branch_tip should equal "$base"
    The result of function upstream_tracking_tip should equal "$upstream_tip"
  End

  It 'adds origin from a string repo in an INI file'
    git -C "$tmp/checkout" remote remove origin
    cat >"$tmp/wb.ini" <<EOF
[demo]
repo=$tmp/origin.git
dir=$tmp/checkout
commit=
EOF
    When call env WORLDBUILDER_FILE="$tmp/wb.ini" PATH="$tmp/bin:$PATH" zsh -f "$WB" update demo --remote=origin
    The status should be success
    The result of function remote_names should include 'origin'
    The result of function branch_tip should equal "$base"
  End

  It 'fails for a missing remote not in the repo map without moving the branch'
    When call run_update --remote=missing
    The status should be failure
    The stderr should include 'missing'
    The result of function branch_tip should equal "$base"
    The result of function remote_names should not include 'missing'
  End

  It 'fails without updating the branch when fetching the selected remote fails'
    git -C "$tmp/checkout" remote set-url upstream "$tmp/not-a-repo"
    When call run_update --remote=upstream
    The status should be failure
    The result of function branch_tip should equal "$base"
  End

  It 'uses an existing remote without replacing its URL from the repo map'
    write_update_config "$tmp/origin.git"
    When call run_update --remote=upstream
    The status should be success
    The result of function upstream_url should equal "$tmp/upstream.git"
    The result of function branch_tip should equal "$upstream_tip"
  End

  It 'updates an off-branch target from the selected remote without switching branches'
    git -C "$tmp/checkout" checkout -q -b other
    When call run_update --remote=upstream
    The status should be success
    The result of function branch_tip should equal "$upstream_tip"
    The result of function current_branch should equal 'other'
    The result of function tracking_remote should equal 'origin'
  End

  It 'forces a divergent checked-out branch to the selected remote'
    git -C "$tmp/checkout" commit -q --allow-empty -m local
    When call run_update --remote=upstream --force
    The status should be success
    The result of function branch_tip should equal "$upstream_tip"
    The result of function tracking_remote should equal 'origin'
  End

  It 'reports a failed pull and restores stashed local changes'
    git -C "$tmp/checkout" commit -q --allow-empty -m local
    git -C "$tmp/checkout" config pull.ff only
    local_tip=$(git -C "$tmp/checkout" rev-parse HEAD)
    printf 'local change\n' >"$tmp/checkout/tracked"
    When call run_update --remote=upstream
    The status should be failure
    The result of function branch_tip should equal "$local_tip"
    The contents of file "$tmp/checkout/tracked" should equal 'local change'
  End

  It 'still updates from the configured upstream and restores local changes when no remote is selected'
    git -C "$tmp/checkout" config branch.main.remote upstream
    printf 'local change\n' >"$tmp/checkout/tracked"
    When call run_update
    The status should be success
    The result of function branch_tip should equal "$upstream_tip"
    The result of function tracking_remote should equal 'upstream'
    The contents of file "$tmp/checkout/tracked" should equal 'local change'
  End
End

Describe 'worldbuilder build'
  WB="$PWD/worldbuilder"

  BeforeEach 'tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/checkout"'
  AfterEach 'rm -rf "$tmp"'

  It 'accepts a repo map when building from an existing checkout'
    cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
cat
EOF
    chmod +x "$tmp/bin/fzf"
    cat >"$tmp/wb.toml" <<EOF
[demo]
repo = { origin = "git@example.test:demo.git", upstream = "git@example.test:upstream.git" }
dir = "$tmp/checkout"
image = "demo:latest"
type = "build"
platform = "linux/amd64"
commit = ""
build_cmd = "true"
EOF
    When call env WORLDBUILDER_FILE="$tmp/wb.toml" PATH="$tmp/bin:$PATH" zsh -f -c 'cd "$1" && exec zsh "$2" build demo --head' zsh "$tmp" "$WB"
    The status should be success
  End
End
