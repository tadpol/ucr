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
