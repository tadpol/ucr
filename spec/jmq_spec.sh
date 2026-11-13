setup_prc_test() {
  tmp=$(mktemp -d)
  mkdir "$tmp/bin"
  printf '%s' 'PR body from file' >"$tmp/body"
  cat >"$tmp/bin/jq" <<'EOF'
#!/bin/sh
case "$*" in
  *".issues[]"*) printf 'PR title\n' ;;
  *".transitions[]"*) printf '31\n' ;;
esac
EOF
  cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s' "$8"
EOF
  chmod +x "$tmp/bin/jq" "$tmp/bin/gh"
}

Describe 'jmq prc'
  JMQ="$PWD/jmq"

  BeforeEach 'setup_prc_test'
  AfterEach 'rm -rf "$tmp"'

  It 'uses the body file contents for the pull request'
    When call env PATH="$tmp/bin:$PATH" JMQ_HOST=example.com zsh "$JMQ" prc ABC-1 --body="$tmp/body" --dry
    The status should be success
    The output should equal 'PR body from file'
  End
End
