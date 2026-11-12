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
