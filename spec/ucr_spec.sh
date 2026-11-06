Describe 'ucr device list'
  UCR="$PWD/ucr"

  It 'passes filters as typed listIdentities parameters'
    When call env UCR_API_URL=https://example.com UCR_DIS_URL=https://example.com UCR_SID=test zsh "$UCR" device list --limit=25 --offset=10 --order=lastseen.desc,state.temp.asc --before=123.5 --status=online,offline --identity='^abc.*' --ipaddress=1.2.3.4 --tag.name=color --tag.value=blue --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include '"limit":25'
    The stderr should include '"offset":10'
    The stderr should include '"order":["lastseen.desc","state.temp.asc"]'
    The stderr should include '"before":123.5'
    The stderr should include '"status":"online,offline"'
    The stderr should include '"tag.name":"color"'
    The stderr should include '"tag.value":"blue"'
  End

  It 'requires a tag name when filtering by tag value'
    When call env UCR_API_URL=https://example.com UCR_DIS_URL=https://example.com UCR_SID=test zsh "$UCR" device list --tag.value=blue --dry
    The status should equal 2
    The stderr should include 'Option --tag.value requires --tag.name'
  End
End

Describe 'ucr env set'
  UCR="$PWD/ucr"

  It 'sets multiple key/value pairs'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" env set FIRST one SECOND two --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include '-d {"FIRST":"one","SECOND":"two"}'
  End

  It 'rejects an unmatched key'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" env set FIRST one SECOND --curl --dry
    The status should equal 2
    The stderr should include 'Expected key/value pairs'
  End
End

Describe 'ucr service add'
  UCR="$PWD/ucr"

  It 'adds a service without optional values'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" service add weather --debug --curl --dry
    The status should be success
    The stderr should include '"solution_id":"test"'
    The stderr should include '"service":"weather"'
  End

  It 'includes supplied script key and name in the request'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" service add weather --script_key=weatherV1 --name='Weather Service' --debug --curl --dry
    The status should be success
    The stderr should include '"script_key":"weatherV1"'
    The stderr should include '"name":"Weather Service"'
  End

  It 'rejects a script key that starts with a digit'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" service add weather --script_key=1weather --dry
    The status should equal 2
    The stderr should include 'Option --script_key has invalid value: 1weather'
  End
End

Describe 'ucr ev list'
  UCR="$PWD/ucr"

  It 'serializes selected fields as a comma-separated query parameter'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev list --select=id,name,script --curl --dry
    The status should be success
    The stderr should include 'select=id%2Cname%2Cscript'
  End

  It 'rejects fields outside the Swagger enum'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev list --select=id,invalid --dry
    The status should equal 2
    The stderr should include 'Option --select has invalid value: id,invalid'
  End
End

Describe 'ucr logs'
  UCR="$PWD/ucr"

  It 'serializes filters into the API query parameter'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" logs --limit=10 --offset=5 --severity=1,2 --timestamp=100,200 --message='x.*[y]' --event=evt_a,evt_b --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include 'limit=10'
    The stderr should include 'offset=5'
    The stderr should include '%22severity%22%3A%7B%22%24in%22%3A%5B1%2C2%5D%7D'
    The stderr should include '%22timestamp%22%3A%7B%22%24gte%22%3A100%2C%22%24lte%22%3A200%7D'
    The stderr should include '%22message%22%3A%7B%22%24regex%22%3A%22.%2Ax%5C%5C.%5C%5C%2A%5C%5C%5By%5C%5C%5D.%2A%22%7D'
    The stderr should include '%22event%22%3A%7B%22%24in%22%3A%5B%22evt_a%22%2C%22evt_b%22%5D%7D'
  End

  It 'omits the query parameter when no filters are given'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" logs --limit=10 --curl --dry
    The status should be success
    The stderr should include 'limit=10'
    The stderr should not include 'query='
  End

  It 'rejects malformed severity lists'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" logs --severity=1,nope --dry
    The status should equal 2
    The stderr should include 'Option --severity has invalid value: 1,nope'
  End
End

Describe 'ucr event handler tasks'
  UCR="$PWD/ucr"

  It 'creates an event handler with a JSON request body'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev create --name=alarm --service=weather --event=on_start --script='return 1' --debug --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include 'https://example.com/eventhandler'
    The stderr should include '-X POST'
    The stderr should include '"solution_id":"test"'
    The stderr should include '"name":"alarm"'
    The stderr should include '"service":"weather"'
    The stderr should include '"event":"on_start"'
    The stderr should include '"script":"return 1"'
  End

  It 'accepts wildcard event and script-key patterns without a service'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev create --event='*' --script_key='P/*' --script='return 1' --debug --curl --dry
    The status should be success
    The stderr should include '"event":"*"'
    The stderr should include '"script_key":"P/*"'
  End

  It 'updates only supplied event handler fields'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev update ev-123 --name=updated --debug --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include 'https://example.com/eventhandler/ev-123'
    The stderr should include '-X PUT'
    The stderr should include '{"name":"updated"}'
  End

  It 'accepts a wildcard script key without a service when updating'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev update ev-123 --event='*' --script_key='*' --debug --curl --dry
    The status should be success
    The stderr should include '"script_key":"*"'
    The stderr should include '"event":"*"'
  End

  It 'rejects wildcard script keys when a service is supplied'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev create --service=weather --script_key='*' --dry
    The status should equal 3
    The stderr should include "Option --script_key patterns '*' and 'P/*' require --service to be omitted"
  End

  It 'gets an event handler by id'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev info ev-123 --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include 'https://example.com/eventhandler/ev-123'
  End

  It 'deletes an event handler by id'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev delete ev-123 --curl --dry
    The status should be success
    The output should equal ''
    The stderr should include '-X DELETE https://example.com/eventhandler/ev-123'
  End

  It 'prefixes UCR_SID to an alias suffix when updating'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev update _config_fallback --name=updated --curl --dry
    The status should be success
    The stderr should include 'https://example.com/eventhandler/test_config_fallback'
  End

  It 'prefixes UCR_SID to an alias suffix when getting'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev info _config_fallback --curl --dry
    The status should be success
    The stderr should include 'https://example.com/eventhandler/test_config_fallback'
  End

  It 'prefixes UCR_SID to an alias suffix when deleting'
    When call env UCR_API_URL=https://example.com UCR_SID=test zsh "$UCR" ev delete _config_fallback --curl --dry
    The status should be success
    The stderr should include '-X DELETE https://example.com/eventhandler/test_config_fallback'
  End
End
