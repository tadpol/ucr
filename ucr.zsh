#!/usr/bin/env zsh
# set -e

# would love for the core to be a separate file that you source in, then add your stuff.
# But for now we'll just lump in one file.

# compute this from script name
# Plan is to enable having multiple versions of this with different names
argv0=${${0:t}:r}

# This loads only the key=values and does not execute any code that might be included.
# This is for files that are like .env
# When overwrite is false, won't set an already set variable
function load_config {
  if [[ -f "$1" ]]; then
    local overwrite=${2:-true}
    while read -r line; do
      if [[ "$line" =~ "^(export )?([a-zA-Z0-9_]+)=(.*)" ]]; then
        if [[ $overwrite == true || ! -v "$match[2]" ]]; then
          typeset -g -x ${match[2]}=${match[3]}
        fi
      fi
    done < "$1"
  fi
}

# This loads only the key=values for a given section
# If no section, then loads key=values up to first defined section
# When overwrite is false, won't set an already set variable
function load_from_ini {
  if [[ -f "$1" ]]; then
    local section=${2:-default}
    local overwrite=${3:-true}
    # echo ">S ${section} O ${overwrite}" >&2
    local current_section=default
    while read -r line; do
      if [[ "$line" =~ "^(export )?([a-zA-Z0-9_]+)=(.*)" ]]; then
        if [[ "$current_section" == "$section" ]]; then
          # echo ">VAR ${match[2]} = ${match[3]}" >&2
          if [[ $overwrite == true || ! -v "$match[2]" ]]; then
            typeset -g -x ${match[2]}=${match[3]}
          fi
        fi
      elif [[  "$line" =~ "^\[([^]]*)\]"  ]]; then
        # echo ">SECTION ${match[1]}" >&2
        current_section=${match[1]}
      fi
    done < "$1"
  fi
}

# First load user defaults (under any existing ENVs)
load_from_ini ~/.${argv0}rc default false
# Then check for directory specifics
load_config .env

# Parsed options are saved here for everyone to look at
typeset -A ucr_opts

# Scan arguments and pull out options and envs, then find the function to call, and call it.
# This is most of what ucr is.
function task_runner {
  local leftovers=()
  local ucr_cmdline=()
  local double_dash=false

  # First pass, look for long options, short options, and env pairGs
  for arg in ${(s: :)*}; do
    if [[ "$double_dash" = "true" ]]; then
      leftovers[${#leftovers}+1]=$arg
    elif [[ "$arg" =~ "^--$" ]]; then
      double_dash=true
    elif [[ "$arg" =~ "^--" ]]; then
      # long option
      local opt=${arg#--}
      if [[ "$opt" =~ "^([^=]+)=(.*)" ]]; then
        ucr_opts[${match[1]}]=${match[2]}
      elif [[ "$opt" =~ "^no-" ]]; then
        ucr_opts[${opt#no-}]=false
      else
        ucr_opts[$opt]=true
      fi
    elif [[ "$arg" =~ "^-" ]]; then
      # short option
      local opt=${arg#-}
      for so in ${(s::)opt}; do
        if [[ -z "$ucr_opts[$so]" ]]; then
          ucr_opts[$so]=1
        else
          (( ucr_opts[$so]++ ))
        fi
      done
    elif [[ "$arg" =~ "^([^=]+)=(.*)" ]]; then
      # ENV key-value
      typeset -g -x ${(U)argv0}_${(U)match[1]}=${match[2]}
    else
      # plain argument
      leftovers[${#leftovers}+1]=$arg
    fi
  done

  # Second pass, look for functions
  local func_list=(${(ok)functions[(I)${(L)argv0}_*]})
  local remaining=()

  # loop with args dropping off tail
  while (( ${#leftovers} > 0 ))
  do
    try_cmd=${(L)argv0}_${(j:_:)leftovers}
    found=${func_list[(Ie)$try_cmd]}
    if (( found != 0 )); then
      ucr_cmdline=($try_cmd ${remaining[@]})
      break
    fi
    remaining=(${leftovers[-1]} ${remaining[@]})
    shift -p leftovers
  done
  if (( ${#leftovers} == 0 )); then
    ucr_cmdline=(${(L)argv0}_function_not_found ${remaining[@]})
  fi

  # Handle Global Options here:
  if [[ -n "$ucr_opts[sec]" ]]; then
    # echo "> Using ${ucr_opts[sec]}" >&2
    local cfg=${ucr_opts[cfg]:-~/.${argv0}rc}
    load_from_ini "$cfg" "${ucr_opts[sec]}"
  fi

  # echo "do: $ucr_cmdline" >&2
  ${=ucr_cmdline}
}

# Checks that specified ENVs exist.
# Call with pairs of key names and regexp to validate
function want_envs {
  typeset -A tests=($*)
  local key
  for key in ${(k)tests}; do
    if [[ ! -v "$key" ]]; then
      echo "Missing ENV[$key]" >&2
      exit 2
    elif [[ ! "${(P)key}" =~ "${tests[$key]}" ]]; then
      echo "ENV[$key] invalid by: ${tests[$key]}" >&2
      exit 3
    fi
  done
}

# Checks that if an option was specified, it validates
# Then outputs a JSON object of the options and values.
function options_to_json {
  typeset -A maybe_opts=($*)
  local build_req=()
  local key
  for key in ${(k)maybe_opts}; do
    if [[ -n "${ucr_opts[$key]}" ]]; then
      if [[ ${ucr_opts[$key]} =~ ${maybe_opts[$key]} ]]; then
        # if it looks like a number, use a number.
        if [[ ${ucr_opts[$key]} =~ "^[0-9]+$" ]]; then
          build_req+="\"${key}\":${ucr_opts[$key]}"
        else
          build_req+="\"${key}\":\"${ucr_opts[$key]}\""
        fi
      else
        echo "Option: '$key' is not valid according to ${maybe_opts[$key]}" >&2
        exit 3
      fi
    fi
  done
  echo "{ ${(j:, :)build_req} }"
}

# Helper function to get passwords out of a netrc file
function scan_netrc {
  local host_to_find=$1
  local user_to_find=$2
  local netrc=($(< ~/.netrc ))
  # This does not correctly handle `macrodef`
  # netrc is a series of key-value pairs seperated by anysort of white space.
  # (netrc explicitly does not handle password with whitespace in them)
  # Strictly, netrc only matches on `machine` and there can only be one of each.
  # But this matches both machine and login, and handles multiple machines
  local key=''
  local state=START
  local found_password=''
  for i in $netrc
  do
  # echo "[k: $key s: $state] $i" >&2
  case $i in
    machine)
      key=machine
      state=machine
      ;;
    login)
      key=login
      ;;
    password)
      key=password
      ;;
    *)
      if [[ $key = machine && "$i" = "$host_to_find" ]]; then
        state=MACHINE_FOUND
      fi
      if [[ $state = MACHINE_FOUND* && $key = password ]]; then
        found_password=$i
        if [[ $state == MACHINE_FOUND_LOGIN ]]; then
          echo $found_password
          return 0
        else
          state=MACHINE_FOUND_PASSWORD
        fi
      fi
      if [[ $state = MACHINE_FOUND* && $key = login && "$i" = "$user_to_find" ]]; then
        if [[ $state == MACHINE_FOUND_PASSWORD ]]; then
          echo $found_password
          return 0
        else
          state=MACHINE_FOUND_LOGIN
        fi
      fi
      ;;
  esac
  done
}

# Helper function for getting a password from a hierarchy of password stores.
function password_for {
  # Two params, 1: host, 2: user
  # If env password set, just return that
  if [[ -v UCR_PASSWORD ]]; then
    echo $UCR_PASSWORD
    return
  fi
  # Check .netrc
  if [ -f ${HOME}/.netrc ]; then
    password=$(scan_netrc $1 $2)
    if [[ -n "$password" ]]; then
      echo $password
      return
    fi
  fi

  # On Macs, try Keychain
  if (which security >/dev/null); then
    password=$(security find-internet-password -a "$2" -s "$1" -w 2>/dev/null)
    if [[ -z "$password" ]]; then
      password=$(security find-generic-password -a "$2" -s "$1" -w 2>/dev/null)
    fi
    if [[ -n "$password" ]]; then
      echo $password
      return
    fi
  fi

  # Check 1password (op)
  # if (which op >/dev/null); then
  # fi
}

# Above is functions and such to be the core.
##############################################################################

# Get a murano login token and save it in env to use by following commands.
# Just smart enough not to call more than once per evocation, could save token somewhere for multiple.
# Not worth the extra work.
function get_token {
  if [[ -z "$UCR_TOKEN" ]]; then
    local psd=$(password_for $UCR_HOST $UCR_USER)
    # echo "X: $psd" >&2
    # Murano doesn't accept basic auth…
    local req=$(jq -n --arg psd "$psd" --arg user "$UCR_USER" '{"email": $user, "password": $psd}')
    export UCR_TOKEN=$(curl -s https://${UCR_HOST}/api:1/token/ -H 'Content-Type: application/json' -d "$req" | jq -r .token)
  fi
}

function v_curl {
  # When --curl, print out a copy/pastable curl … that is also nice-ish to read.
  if [[ -n "$ucr_opts[curl]" ]]; then
    # Add quoting
    local wk=(curl $@)
    local i
    for (( i = 1; i <= $#wk; i++ )) do
      if [[ "${wk[i]}" =~ " " ]];then
        wk[i]="${(qq)wk[i]}"
      fi
    done

    # Break lines with '\\\n' when too long (but don't break and arg)
    typeset -a fin
    typeset -a line
    for a in $wk; do
      if (( ( $#line + $#a ) > $COLUMNS )); then
        fin+=$line
        line=()
      fi
      line+=$a
    done
    fin+=${(j: :)line}
    echo ${(j: \\\n  :)fin} >&2
  fi
  # Just skipping causes issues in some places where output is piped
  if [[ -z "$ucr_opts[dry]" ]]; then
    curl "$@"
  fi
}

##############################################################################
# Below is the functions defined as tasks callable from cmdline args
# They are all prefixed with `${(L)argv0}_`

# This is called if a function based on the passed args couldn't be found.
function ${(L)argv0}_function_not_found {
  echo "Couldn't find a task based on these arguments: " >&2
  echo "  $*" >&2
  exit 1
}

# List all of the tasks that have been defined
function ${(L)argv0}_tasks {
  for fn in ${(@ok)functions[(I)${(L)argv0}_*]}; do
    echo ${${fn#${(L)argv0}_}//_/ }
  done
}
function ${(L)argv0}_state {
  echo "ENV:"
  typeset -g | grep -e "^${(U)argv0}_" | sed -e 's/=/: /' -e 's/^/ /'
  echo "OPTIONS:"
  for k in ${(@k)ucr_opts}; do
    if [[ ${#k} == 1 && ${ucr_opts[$k]} =~ "^[0-9]+$" ]]; then
      echo " -${(pl:${ucr_opts[$k]}::$k:)}"
    else
      echo " --${k}=${ucr_opts[$k]}"
    fi
  done
  echo "ARGS:"
  for k in "$@"; do
    echo " $k"
  done
}

function ucr_token {
  get_token
  echo $UCR_TOKEN
}

function ucr_dump_script {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/route/${UCR_SID}/script \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_env_get {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/env \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_env_set {
  # <key> <value> [<key <value> …]
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local req=$(jq -n -c '[$ARGS.positional|_nwise(2)|{"key":.[0],"value":.[1]}]|from_entries' --args -- "${@}")
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/env \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_services {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_uuid {
  ucr_service_details $1
}

function ucr_service_usage {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${(L)service}/info \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_details {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${(L)service} \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_add {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  local req=$(jq -n -c --arg service "${(L)service}" --arg sid "$UCR_SID" '{"solution_id": $sid, "service": $service}')
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${(L)service} \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_service_schema {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/service/${(L)service}/schema \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_business_solutions {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_BID "^[a-zA-Z0-9]+$"
  get_token

  v_curl -s "https://${UCR_HOST}/api:1/business/${UCR_BID}/solution/" \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_template_update {
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local repo_url
  if [[ $# > 0 ]]; then
    repo_url=$1
  else
    repo_url=https://github.com/${${$(git remote get-url origin)#git@github.com:}%%.git}
    repo_url+="/tree/$(git rev-parse --abbrev-ref HEAD)"
  fi
  local req=$(jq -n -c --arg url "$repo_url" '{"url": $url}')
  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/update \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_query {
  # metric names are just args, tags are <tag name>@<tag value>
  # others are all --options=value
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)
  # Validate a list of the options we will care about.
  local opt_req=$(
    options_to_json \
    start_time "[1-9][0-9]*(u|ms|s)?" \
    end_time "[1-9][0-9]*(u|ms|s)?" \
    relative_start "-[1-9][0-9]*(u|ms|s|m|h|d|w)?" \
    relative_end "-[1-9][0-9]*(u|ms|s|m|h|d|w)?" \
    sampling_size "[1-9][0-9]*(u|ms|s|m|h|d|w)?" \
    limit "[1-9][0-9]*" \
    epoch "(u|ms|s)" \
    mode "(merge|split)" \
    fill "(null|previous|none|[1-9][0-9]*|~s:.+)" \
    order_by "(desc|asc)" \
    aggregate "((avg|min|max|count|sum),?)+"
  )
  [[ -z "$opt_req" ]] && exit 4

  local req=$(jq -c '. + ($ARGS.positional | map(split("@") | {"key": .[0], "value": .[1]} ) |
    {
      "tags": map(select(.value)) | group_by(.key) | map({"key":.[0].key,"value":(map(.value) | if length==1 then first else . end)}) | from_entries,
      "metrics": map(select(.value | not) | .key)
    })' --args -- "${@}" <<< $opt_req)

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/query \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_recent {
  # recent <tag name> <metrics>… @<tag values>… 
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  local tag_name=${1:?Need tag name}
  shift
  [[ $# == 0 ]] && echo "Missing metrics and tag values" >&2 && exit 2
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  local req=$(jq -n -c --arg tn "${tag_name}" '{
    "metrics": ($ARGS.positional | map(select(. | startswith("@") | not))),
    "tag_name": $tn,
    "tag_values": ($ARGS.positional | map(select(. | startswith("@"))) | map(split("@") | .[1] )),  
  }' --args -- "${@}")

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/recent \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_list_tags {
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listTags \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" | jq '.tags |keys'
}

function ucr_tsdb_list_metrics {
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listMetrics \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" | jq .metrics
  # someday: Look for .next, and handle repeated calls if need be
}

function ucr_tsdb_imports {
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/importJobList \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_tsdb_import_info {
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)
  local job_id=${1:?Need job id argument}

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/importJobInfo \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "{\"job_id\":\"${job_id}\"}"
}

function ucr_tsdb_write {
  # write [--ts=<timestamp>] <metric> <value> [<metric> <value> …] [<tag>@<value> …]
  want_envs UCR_HOST "^[\.A-Za-z0-9-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  local opt_req=$(options_to_json ts "[1-9][0-9]*(u|ms|s)?")
  [[ -z "$opt_req" ]] && exit 4

  local req=$(jq -c '. + ($ARGS.positional | map(split("@") | {"key": .[0], "value": .[1]} ) |
    { "tags": (map(select(.value)) | from_entries),
      "metrics": ([map(select(.value|not)|.key) | _nwise(2) | {"key": .[0], "value": .[1]}] | from_entries)
    })' --args -- "${@}" <<< $opt_req)
  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/write \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_list {
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local match=${1:-*}
  local req=$(jq -n -c --arg match "$match" '{"match":$match,"cursor":0}')

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_get {
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  [[ $# == 0 ]] && echo "Missing keys to get" >&2 && exit 2
  local req=$(jq -n -c '{"keys":$ARGS.positional}' --args -- "${@}")

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/mget \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_set {
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local key=${1:?Need key argument}
  local value=${2:?Need value to set}
  if [[ "$value" = "-" ]]; then
    value=$(</dev/stdin)
  fi

  local req=$(jq -n -c --arg key "$key" --arg value "$value" '{"key":$key,"value":$value}')

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/set \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_delete {
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  [[ $# == 0 ]] && echo "Missing keys to delete" >&2 && exit 2
  local req=$(jq -n -c '{"keys":$ARGS.positional}' --args -- "${@}")

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/mdelete \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"  
}

function ucr_keystore_cmd {
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local cmd=${1:?Need command argument}
  local key=${2:?Need key argument}
  shift 2
  local req=$(jq -n -c --arg key "$key" --arg cmd "$cmd" \
    '{"key":$key,"command":$cmd, "args": $ARGS.positional}' \
    --args -- "${@}")

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/command \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req" 
}

function ucr_insight_info {
  get_token
  local service=${1:?Need Insight Service Name}
  local service_uuid=$(ucr_service_uuid ${(L)service} | jq -r .id)

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/info \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_insight_functions {
  get_token
  local service=${1:?Need Insight Service Name}
  local service_uuid=$(ucr_service_uuid ${(L)service} | jq -r .id)

  curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listInsights \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d '{"limit":1000}'
}

function ucr_content_list {
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local opt_req=$(options_to_json \
    limit "^[1-9][0-9]*$" \
    op "^(AND|OR)$" \
    cursor ".+"
  )
  [[ -z "$opt_req" ]] && exit 4

  local req=$(jq -c '. + {"prefix": $ARGS.positional[0] } | with_entries(select( .value != null ))' --args -- "${@}" <<< $opt_req)

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_deleteMulti {
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local req=$(jq -n -c '{ "body" : $ARGS.positional }' --args -- "$@")

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/deleteMulti \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_download {
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local cid=${1:?Need content id to download}
  local opt_req=$(options_to_json \
    expires_in "^\d+$" \
  )
  [[ -z "$opt_req" ]] && exit 4
  local req=$(jq -c --arg cid "$cid" '. + {"id": $cid }' <<< $opt_req)

  v_curl -s https://${UCR_HOST}/api:1/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/download \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"

  # ??? Should we extract the URL info and then run a curl on that right away?  Or would I rather not have that be automatic?
  # Or maybe options to select?
}

function jmq_q {
  # --fields=*all to get everything
  local jql=($@)
  local fields=(key summary)
  if [[ -n ${ucr_opts[fields]} ]]; then
    fields=(${(s:,:)ucr_opts[fields]})
  fi
  local req=$(jq -n -c --arg jql "${(j: :)jql}" '{"jql": $jql, "fields": $ARGS.positional }' --args -- ${fields})
  v_curl -s https://exosite.atlassian.net/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req"
}

function jmq_pr {
  local key=${1:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  if [[ $key =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    key="key=$key"
  fi
  local req=$(jq -n -c --arg jql "$key" '{"jql": $jql, "fields": ["key","summary"] }')

  curl -s https://exosite.atlassian.net/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | .fields.summary + " (" + .key + ")"'
}

function jmq_next {
  local key=${1:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  # Get what transitions can be made.
  local transitions=$(v_curl -s https://exosite.atlassian.net/rest/api/2/issue/${key}/transitions --netrc)

  # Display menu list and ask which to take. (If only one, then just take that without asking)
  local trn=$(jq -r '.transitions[] | [.id, .name] | @tsv' <<< $transitions | fzf \
    --select-1 --no-multi --nth=2.. --with-nth=2.. --height 30% --prompt="Follow which transition? ")
  if [[ -z "$trn" ]]; then
    exit
  fi
  local transition_id=$(awk '{print $1}' <<< $trn )
  # Take it
  v_curl -s https://exosite.atlassian.net/rest/api/2/issue/${key}/transitions \
    --netrc \
    -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\": ${transition_id} }}"
}

# Move tickets to named state
# jmq move FOO-0000 In Progress
function jmq_move {
  local key=${1:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  shift
  if [[ $# < 1 ]]; then
    echo "Missing state" >&2
    exit 1
  fi
  local state="${(j: :)*}"

  # Get what transitions can be made.
  local transitions=$(v_curl -s https://exosite.atlassian.net/rest/api/2/issue/${key}/transitions --netrc)

  local inp_id=$(jq --arg nme "$state" '.transitions[]|select(.name==$nme)|.id' <<< $transitions)
  if [[ -z "$inp_id" ]]; then
    echo "Cannot directly transition to $state" 
    exit
  fi

  v_curl -s https://exosite.atlassian.net/rest/api/2/issue/${key}/transitions \
    --netrc \
    -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\": ${inp_id} }}"
}

# Move an issue back to In Progress
# Used for "undoing" automatic CI transitions.
function jmq_inp {
  jmq_move "$1" In Progress
}

function jmq_todo {
  want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local jql=(
    "assignee = currentUser()"
    "status = \"On Deck\" ORDER BY Rank"
  )
  if [[ -z "${ucr_opts[all]}" ]]; then
    jql=(
      "project in (${JMQ_PROJECTS})"
      "sprint in openSprints()"
      "sprint not in futureSprints()"
      $jql
    )
  fi
  local req=$(jq -n -c --arg jql "${(j: AND :)jql}" '{"jql": $jql, "fields": ["key","summary"] }')

  v_curl -s https://exosite.atlassian.net/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | [.key, .fields.summary] | @tsv'
}

function jmq_info {
  local key=${1:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  if [[ $key =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    key="key=$key"
  fi
  local fields=(key summary description assignee reporter priority issuetype status resolution votes watches customfield_10820)
  local req=$(jq -n -c --arg jql "$key" '{"jql": $jql, "fields": $ARGS.positional }' --args -- ${fields})

  v_curl -s https://exosite.atlassian.net/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | 
      "        Key: \(.key)
    Summary: \(.fields.summary)
   Reporter: \(.fields.reporter.displayName)
   Assignee: \(.fields.assignee.displayName)
     Tester: \(.fields.customfield_10820.displayName)
       Type: \(.fields.issuetype.name) (\(.fields.priority.name))
     Status: \(.fields.status.name) (Resolution: \(.fields.resolution.name))
    Watches: \(.fields.watches.watchCount)  Votes: \(.fields.votes.votes)
Description: \(.fields.description)"'
}

function jmq_status {
  want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local jql=(
    "project in (${JMQ_PROJECTS})"
    "sprint in openSprints()"
    "sprint not in futureSprints()"
    "assignee = currentUser() ORDER BY Rank"
  )
  local req=$(jq -n -c --arg jql "${(j: AND :)jql}" '{"jql": $jql, "fields": ["key","summary","status"] }')

  curl -s https://exosite.atlassian.net/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues |
  group_by(.fields.status.name) |
  map({"key": .[0].fields.status.name, "value": map([("- "+.key), .fields.summary] | @tsv) | join("\n")}) |
  map(select([.key] | inside(["In Progress","On Deck"]))) |
  map([(.key+":"), .value]) |
  flatten | 
  join("\n")'
}

function jmq_open {
  local key=${1:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  open https://exosite.atlassian.net/browse/${(U)key}
}

function murdoc_images {
  want_envs SSHTO ".*"
  ${=SSHTO} "sudo bash -s" <<-'EOS'
    docker inspect $(docker inspect $(docker ps -q) --format='{{.Image}}')
EOS
}

function murdoc_ps {
  # --name|-n
  want_envs SSHTO ".*"
  local filter='.'
  if [[ -n "${ucr_opts[name]}" || -n "${ucr_opts[n]}" ]]; then
    filter='map( {(.Name | tostring): .}) | add'
  fi
  ${=SSHTO} 'sudo docker inspect $(sudo docker ps -q)' | jq "${filter}"
}

function murdoc_status {
  want_envs SSHTO ".*"
  filter='sort_by(.Name)|.[]|[.Name, .State.Status, .State.Health.Status]|@csv'
  ${=SSHTO} 'sudo docker inspect $(sudo docker ps -q)' | jq -r "${filter}" | xsv table
}

function murdoc_names {
  want_envs SSHTO ".*"
  ${=SSHTO} "sudo bash -s" <<-'EOS' | jq -r 'map(.Name) | sort | .[]'
    docker inspect $(docker ps -q)
EOS
}

function murdoc_env {
  want_envs SSHTO ".*"
  local key=${1:?Missing Container Name}
  ${=SSHTO} "sudo docker inspect $1" | jq -r '.[0].Config.Env[]'
}

# Get envs for service, reshape into envs for psql, load them and call psql.
function murdoc_psql {
  local ens=($(murdoc_env $1 | grep DB_ | sed -e 's/^DB_/PG/'))
  for r in $ens; do
    if [[ "$r" =~ "([a-zA-Z0-9_]+)=(.*)" ]]; then
      typeset -g -x ${match[1]}=${match[2]}
    fi
  done
  if [[ -n "${PGURL}" ]]; then
    psql "$PGURL"
  else
    psql
  fi
}

# Get envs for service, reshape into envs for redis, load them and call redis-cli.
# Redis-cli only takes password via env, others need options.
function murdoc_redis {
  local prefix=REDIS_
  if [[ -n "${ucr_opts[live]}" ]]; then
    prefix=LIVE_DATA_REDIS_
  fi
  if [[ -n "${ucr_opts[prefix]}" ]]; then
    prefix=${ucr_opts[prefix]}
  fi

  ens=($(murdoc_env $1 | grep ^${prefix} |sed -e "s/^${prefix}//" ))

  # HOST, PORT, PASSWORD, USER, DB
  typeset -A redis_keys
  redis_keys[PORT]=6379
  redis_keys[HOST]=127.0.0.1
  redis_keys[USER]=''
  redis_keys[DB]=0
  for r in $ens; do
    if [[ "$r" =~ "([a-zA-Z0-9_]+)=(.*)" ]]; then
      redis_keys[${match[1]}]=${match[2]}
    fi
  done

  if [[ -n "${redis_keys[PASSWORD]}" ]]; then
    typeset -g -x REDISCLI_AUTH=${redis_keys[PASSWORD]}
  fi
  shift 1

  if [[ -n "${redis_keys[URL]}" ]];then
    redis-cli -u "${redis_keys[URL]}" "$@"
  else
    redis-cli -h ${redis_keys[HOST]} -p ${redis_keys[PORT]} -n ${redis_keys[DB]} "$@"
  fi
}


##############################################################################
# This needs to be last.
task_runner "$*"
