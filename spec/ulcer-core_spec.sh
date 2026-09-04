Describe 'ulcer-core.zsh'
  CORE="$PWD/ulcer-core.zsh"

  make_curl_stubs() {
    tmp=$(mktemp -d)
    mkdir "$tmp/bin"
    cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl:%s\n' "$*"
EOF
    cat >"$tmp/bin/op" <<'EOF'
#!/bin/sh
printf 'op:%s\n' "$*"
EOF
    chmod +x "$tmp/bin/curl" "$tmp/bin/op"
  }

  run_core() {
    zsh -f -c 'argv0=fixture; HOME=$1; cd "$2"; source "$3"; shift 3; "$@"' \
      zsh "$1" "$2" "$CORE" "${@:3}"
  }

  Describe 'syntax and loading'
    It 'passes zsh syntax checking'
      When call zsh -n "$CORE"
      The status should be success
    End

    It 'loads without running as a script and defines the core API'
      When call zsh -f -c 'argv0=fixture; source "$1"; (( ${+functions[load_config]} && ${+functions[load_from_ini]} && ${+functions[load_option_envs]} && ${+functions[options_to_json]} && ${+functions[want_envs]} && ${+functions[task_runner]} )); (( ${+parameters[ucr_opts]} ))' zsh "$CORE"
      The status should be success
      The stderr should equal ''
    End
  End

  Describe 'load_config'
    BeforeEach 'tmp=$(mktemp -d)'
    AfterEach 'rm -rf "$tmp"'

    It 'loads valid entries, exports values, ignores comments, and preserves spaces'
      cat >"$tmp/env" <<'EOF'
# ignored
GOOD=hello world
export OTHER=value
not valid
EOF
      When call zsh -f -c 'argv0=fixture; HOME=$1; source "$2"; load_config "$3"; [[ $GOOD == "hello world" && $OTHER == value && -v GOOD && -v OTHER ]]' zsh "$tmp" "$CORE" "$tmp/env"
      The status should be success
    End

    It 'does not overwrite an existing value when disabled'
      printf 'VALUE=file\n' >"$tmp/env"
      When call zsh -f -c 'argv0=fixture; source "$1"; VALUE=existing; load_config "$2" false; print -r -- "$VALUE"' zsh "$CORE" "$tmp/env"
      The output should equal 'existing'
    End

    It 'does not execute shell syntax'
      printf 'VALUE=$(touch %s/pwned)\n' "$tmp" >"$tmp/env"
      When call zsh -f -c 'argv0=fixture; source "$1"; load_config "$2"; [[ ! -e "$3/pwned" ]]' zsh "$CORE" "$tmp/env" "$tmp"
      The status should be success
    End
  End

  Describe 'load_from_ini'
    BeforeEach 'tmp=$(mktemp -d); printf "BEFORE=one\n[dev]\nDEV=two\n[other]\nNO=three\n" >"$tmp/config"'
    AfterEach 'rm -rf "$tmp"'

    It 'loads the default section and a selected section only'
      When call zsh -f -c 'argv0=fixture; HOME=$1; source "$2"; unset BEFORE DEV NO; load_from_ini "$3"; print -r -- "$BEFORE ${DEV-unset} ${NO-unset}"' zsh "$tmp" "$CORE" "$tmp/config"
      The output should equal 'one unset unset'
    End

    It 'loads a named section without other sections'
      When call zsh -f -c 'argv0=fixture; HOME=$1; source "$2"; unset BEFORE DEV NO; load_from_ini "$3" dev; print -r -- "${BEFORE-unset} $DEV ${NO-unset}"' zsh "$tmp" "$CORE" "$tmp/config"
      The output should equal 'unset two unset'
    End
  End

  Describe 'load_option_envs'
    It 'loads matching environment options with lowercase names'
      When call env FIXTURE_OPTION_VERBOSE=false FIXTURE_OPTION_COUNT=0 FIXTURE_IGNORE=yes zsh -f -c 'argv0=fixture; source "$1"; load_option_envs; print -r -- "$ucr_opts[verbose]|$ucr_opts[count]|${ucr_opts[ignore]-unset}"' zsh "$CORE"
      The output should equal 'false|0|unset'
    End

    It 'honors an explicit prefix'
      When call env CUSTOM_OPTION_NAME=value zsh -f -c 'argv0=fixture; source "$1"; load_option_envs CUSTOM_OPTION_; print -r -- "$ucr_opts[name]"' zsh "$CORE"
      The output should equal 'value'
    End
  End

  Describe 'options_to_json'
    It 'converts automatic, string, boolean, and array values'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[n]=42; ucr_opts[s]=hello; ucr_opts[b]=yes; ucr_opts[a]=x,y; options_to_json n 42 s::string hello b::boolean yes a::array "x,y"' zsh "$CORE"
      The status should be success
      The output should include '"n":42'
      The output should include '"s":"hello"'
      The output should include '"b":true'
      The output should include '"a":["x","y"]'
    End

    It 'omits absent options'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[x]=yes; options_to_json x yes missing yes' zsh "$CORE"
      The output should equal '{"x":"yes"}'
    End

    It 'converts explicit number and false boolean values'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[count]=007; ucr_opts[enabled]=false; options_to_json count::number "^[0-9]+$" enabled::boolean "^(true|false)$"' zsh "$CORE"
      The status should be success
      The output should include '"count":7'
      The output should include '"enabled":false'
    End

    It 'converts an explicit JSON object'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[o]=$'"'"'{"x":1}'"'"'; options_to_json o::object "^.+$"' zsh "$CORE"
      The output should equal '{"o":{"x":1}}'
    End

    It 'rejects a value that does not match its validation pattern'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[count]=abc; options_to_json count::number "^[0-9]+$"' zsh "$CORE"
      The status should equal 3
      The stderr should include "Option: 'count' is not valid according to ^[0-9]+$"
    End

    It 'rejects invalid JSON object values'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[o]=not-json; options_to_json o::json "^.+$"' zsh "$CORE"
      The status should equal 5
      The stderr should include 'jq:'
    End
  End

  Describe 'want_envs'
    It 'accepts a matching value'
      When call env VALUE=abc zsh -f -c 'argv0=fixture; source "$1"; want_envs VALUE "^[a-z]+$"' zsh "$CORE"
      The status should be success
    End

    It 'reports missing and invalid values'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; unset VALUE; want_envs VALUE "^x$"' zsh "$CORE"
      The status should equal 2
      The stderr should include 'Missing ENV[VALUE]'
    End

    It 'rejects an invalid value'
      When call env VALUE=no zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; want_envs VALUE "^x$"' zsh "$CORE"
      The status should equal 3
      The stderr should include 'ENV[VALUE]'
    End
  End

  Describe 'generated task and config helpers'
    BeforeEach 'tmp=$(mktemp -d)'
    AfterEach 'rm -rf "$tmp"'

    It 'lists only public tasks and supports filtering'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; function fixture_help_alpha { : }; function fixture_alpha { : }; function fixture_help_parent_child { : }; function fixture_parent_child { : }; function fixture_private { : }; fixture_tasks' zsh "$CORE"
      The output should include 'alpha'
      The output should include 'parent child'
      The output should not include 'private'
    End

    It 'reports parsed environment, options, and arguments as state'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; FIXTURE_KEY=value; ucr_opts[flag]=true; fixture_state one two' zsh "$CORE"
      The output should include 'ENV:'
      The output should include 'FIXTURE_KEY: value'
      The output should include 'OPTIONS:'
      The output should include '--flag=true'
      The output should include 'ARGS:'
      The output should include ' one'
      The output should include ' two'
    End

    It 'prints help for each config operation'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; fixture_help_config_edit; fixture_help_config_show; fixture_help_config_where; fixture_help_config_sections' zsh "$CORE"
      The output should include 'fixture config edit'
      The output should include 'fixture config show'
      The output should include 'fixture config where'
      The output should include 'fixture config sections'
    End

    It 'shows the config file through the configured pager'
      When call zsh -f -c 'argv0=fixture; HOME=$2; printf "CONFIG=content\\n" > "$2/.fixturerc"; source "$1"; PAGER=cat fixture_config_show' zsh "$CORE" "$tmp"
      The output should equal 'CONFIG=content'
    End

    It 'opens the config file through the configured editor'
      When call zsh -f -c 'argv0=fixture; HOME=$2; printf "CONFIG=content\\n" > "$2/.fixturerc"; source "$1"; VISUAL=true fixture_config_edit' zsh "$CORE" "$tmp"
      The status should be success
    End

    It 'prints the computed config location'
      When call zsh -f -c 'argv0=fixture; HOME=$2; source "$1"; fixture_config_where' zsh "$CORE" /tmp
      The output should equal '/tmp/.fixturerc'
    End

    It 'lists config sections in sorted order'
      When call zsh -f -c 'argv0=fixture; HOME=$2; printf "[prod]\\n[dev]\\n" > "$2/.fixturerc"; source "$1"; fixture_config_sections | tr "\\n" " "' zsh "$CORE" "$tmp"
      The output should equal 'dev prod '
    End
  End

  Describe 'completion'
    It 'lists every child once per prefix, without duplicates'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_foo_bar_baz { : }; function fixture_foo_bar_baz { : }; function fixture_help_foo_bar_qux { : }; function fixture_foo_bar_qux { : }; function fixture_help_foo_other { : }; function fixture_foo_other { : }; fixture_completion' zsh "$CORE"
      The output should include 'foo bar\ other'
      The output should not include 'bar\ bar'
    End

    It 'accumulates a positional spec for every ancestor prefix, not just the deepest one'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_foo_bar_baz { : }; function fixture_foo_bar_baz { : }; function fixture_help_foo_bar_qux { : }; function fixture_foo_bar_qux { : }; function fixture_help_foo_other { : }; function fixture_foo_other { : }; function _arguments { shift; print -l -- "$@" }; function compdef { : }; eval "$(fixture_completion)"; words=(fixture foo bar ""); _fixture' zsh "$CORE"
      The output should include '2:foo:(bar other)'
      The output should include '3:bar:(baz qux)'
    End

    It 'still attaches a leaf task option alongside the accumulated positional specs'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_foo_bar_baz { : }; function fixture_foo_bar_baz { : }; function fixture_help_foo_bar_qux { : }; function fixture_foo_bar_qux { : }; function fixture_help_foo_other { : }; function fixture_foo_other { : }; function fixture_spec_foo_bar_baz { reply=($'"'"'opt\tflag\tvalue\tdescription=A flag value'"'"') }; function _arguments { shift; print -l -- "$@" }; function compdef { : }; eval "$(fixture_completion)"; words=(fixture foo bar baz ""); _fixture' zsh "$CORE"
      The output should include '2:foo:(bar other)'
      The output should include '3:bar:(baz qux)'
      The output should include '--flag=[A flag value]:flag:'
    End

    It 'uses command-backed positional completion'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { : }; function fixture_spec_echo { reply=($'"'"'arg\t1\tname\trequired\tcompletion=fixture candidates'"'"') }; function _arguments { shift; print -l -- "$@" }; function compdef { : }; eval "$(fixture_completion)"; words=(fixture echo ""); _fixture' zsh "$CORE"
      The output should include '2:name:{compadd "${expl[@]}" -- "${(@f)$(fixture candidates 2>/dev/null)}"}'
    End
  End

  Describe 'v_curl'
    BeforeEach 'make_curl_stubs'
    AfterEach 'rm -rf "$tmp"'

    It 'forwards arguments to curl'
      When call env PATH="$tmp/bin:$PATH" zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; v_curl -s https://example.test/path' zsh "$CORE"
      The status should be success
      The output should equal 'curl:-s https://example.test/path'
    End

    It 'skips curl in dry mode'
      When call env PATH="$tmp/bin:$PATH" zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[dry]=true; v_curl https://example.test/path' zsh "$CORE"
      The output should equal ''
    End

    It 'prints the curl command when curl output is requested'
      When call env PATH="$tmp/bin:$PATH" zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; ucr_opts[curl]=true; v_curl -s https://example.test/path' zsh "$CORE"
      The output should equal 'curl:-s https://example.test/path'
      The stderr should include 'curl -s https://example.test/path'
    End

    It 'uses op for variable requests'
      When call env PATH="$tmp/bin:$PATH" zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; v_curl --variable %token https://example.test/path' zsh "$CORE"
      The output should equal 'op:run -- curl --variable %token https://example.test/path'
    End
  End

  Describe 'task_runner'
    It 'dispatches the longest public task path and preserves arguments'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- "echo:$*:$ucr_opts[name]" }; function fixture_help_echo_deep { : }; function fixture_echo_deep { print -r -- "deep:$*" }; task_runner echo deep --name=value one two' zsh "$CORE"
      The output should equal 'deep:one two'
    End

    It 'parses boolean, grouped short, env, and passthrough arguments'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- "$*|$ucr_opts[dry]|$ucr_opts[v]|$FIXTURE_KEY" }; task_runner -vv --dry KEY=value echo -- trailing' zsh "$CORE"
      The output should equal 'trailing|true|2|value'
    End

    It 'dispatches standalone --help to the help task'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; function fixture_help { print -r -- "general help" }; task_runner --help' zsh "$CORE"
      The output should equal 'general help'
    End

    It 'dispatches --help after a task path to its task help'
      When call zsh -f -c 'argv0=fixture; HOME=/nonexistent; source "$1"; function fixture_echo { : }; function fixture_help_echo { print -r -- "echo help" }; task_runner echo --help' zsh "$CORE"
      The output should equal 'echo help'
    End

    It 'rejects a value option without a value'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- ran }; task_runner echo --sec' zsh "$CORE"
      The status should equal 2
      The stderr should include 'Option --sec requires a value'
    End

    It 'accepts a value option with value 1'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- "$ucr_opts[count]" }; function fixture_spec_echo { reply=($'"'"'opt\tcount\tvalue'"'"'); }; task_runner echo --count=1' zsh "$CORE"
      The status should equal 0
      The output should equal '1'
    End

    It 'validates task option values from their specification'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- ran }; function fixture_spec_echo { reply=($'"'"'opt\tmode\tvalue\tenum=fast,slow'"'"'); }; task_runner echo --mode=invalid' zsh "$CORE"
      The status should equal 2
      The stderr should include 'Option --mode has invalid value: invalid'
    End

    It 'requires declared positional arguments'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- ran }; function fixture_spec_echo { reply=($'"'"'arg\t1\tname\trequired'"'"'); }; task_runner echo' zsh "$CORE"
      The status should equal 2
      The stderr should include 'Missing required argument: name'
    End

    It 'rejects positional arguments beyond a task specification'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- ran }; function fixture_spec_echo { reply=($'"'"'arg\t1\tname\trequired'"'"'); }; task_runner echo one two' zsh "$CORE"
      The status should equal 2
      The stderr should include 'Too many positional arguments'
    End

    It 'allows passthrough arguments declared by a task specification'
      When call zsh -f -c 'argv0=fixture; source "$1"; function fixture_help_echo { : }; function fixture_echo { print -r -- "$*" }; function fixture_spec_echo { reply=($'"'"'arg\t1\tcommand\trequired\tpassthrough=true'"'"'); }; task_runner echo command -- --flag value' zsh "$CORE"
      The output should equal 'command --flag value'
    End

    It 'uses the not-found task for unknown commands'
      When call zsh -f -c 'argv0=fixture; source "$1"; task_runner missing' zsh "$CORE"
      The status should equal 1
      The stderr should include "Couldn't find a task"
    End
  End
End
