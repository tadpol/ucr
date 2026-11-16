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
