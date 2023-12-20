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

  # First pass, look for long options, short options, and env pairs
  for arg in ${(s: :)*}; do
    if [[ "$double_dash" = "true" ]]; then
      leftovers[${#leftovers}+1]=$arg
    elif [[ "$arg" =~ "^--$" ]]; then
      double_dash=true
    elif [[ "$arg" =~ "^--sec=(.*)$" ]]; then
      # Handle --sec as it appears; this allows the keys it sets to be overridden by following args
      ucr_opts[sec]=${match[1]}
      local cfg=${ucr_opts[cfg]:-~/.${argv0}rc}
      load_from_ini "$cfg" "${ucr_opts[sec]}"
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
# TODO: ? maybe if --help, then dump all of the options and exit?
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
    # echo "X: $psd" >&2
    # Murano doesn't accept basic auth…
    local req=""
    if [[ "$UCR_USER" =~ '^op:' || "$UCR_PASSWORD" =~ '^op:' ]] && (which op >/dev/null); then
      # They have 1password and are using it, so op run
      req=$(op run --no-masking -- jq -n '{"email": $ENV.UCR_USER, "password": $ENV.UCR_PASSWORD}')
    else
      # Try other ways
      local psd=$(password_for $UCR_HOST $UCR_USER)
      req=$(jq -n --arg psd "$psd" '{"email": $ENV.UCR_USER, "password": $psd}')
    fi
    # echo "X: $req" >&2
    export UCR_TOKEN=$(curl -s https://${UCR_HOST}/api:1/token/ -H 'Content-Type: application/json' -d "$req" | jq -r .token)
  fi
}

# Add a wrapper to curl that will print out the curls.
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
# The first set a for every tool, so they are all prefixed with `${(L)argv0}_`

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

##############################################################################
# Below are the tool specific functions
# They start with the tool name which must match the script file. (that is ARGV[0])

# Repeating this in every command gets messy; so we'll do it once here.
ucr_base_url='${UCR_SCHEME:-https}://${UCR_HOST}/${UCR_URL_PREFIX:-api:1}'

# Everything here is designed to go thru BIZAPI.  A lot of the stuff here is
# historical from blind discovery.  There are more 'correct' ways to talk to services within a solution.
# It would be really nice to be able to also talk directly to dispatcher/api.
# I _think_ that is possible, but can we use the same URLs with just a different prefix to do that?
#
# http://127.0.0.1:4020/api/v1/
# UCR_SCHEME=http UCR_HOST=127.0.0.1:4020 UCR_URL_PREFIX=api/v1 UCR_TOKEN=' '
#
#  !!AH-HA! BIZAPI is mostly just a proxy to peg-api.  So we can just change the base url to talk to peg-api directly.
# 
# The newer "better" way that doesn't require getting the UUID of the service doesn't work when going direct to peg-api.
# So there is just a few commands that are using the new way, and those are going to need to be reworked.


function ucr_token {
  get_token
  echo $UCR_TOKEN
}

function ucr_dump_script {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/route/${UCR_SID}/script \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_env_get {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/env \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_env_set {
  # <key> <value> [<key <value> …]
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token

  local current="{}"
  # if not --reset, then get current values
  if [[ -z ${ucr_opts[reset]} ]]; then
    current=$(ucr_env_get)
  fi

  # merge current values with new values
  local req=$(jq -c '. + ([$ARGS.positional|_nwise(2)|{"key":.[0],"value":.[1]}]|from_entries)' --args -- "${@}" <<< $current)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/env \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_solution_info {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID} \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_services {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_uuid {
  ucr_service_details $1
}

function ucr_service_usage {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${(L)service}/info \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_details {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${(L)service} \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_service_add {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  local req=$(jq -n -c --arg service "${(L)service}" --arg sid "$UCR_SID" '{"solution_id": $sid, "service": $service}')
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${(L)service} \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_service_schema {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need service name}
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/service/${(L)service}/schema \
    -H "Authorization: token $UCR_TOKEN"
}

# Business are a bizapi concept; they are not used in peg-api.
function ucr_business_solutions {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_BID "^[a-zA-Z0-9]+$"
  get_token

  v_curl -s "${(e)ucr_base_url}/business/${UCR_BID}/solution/" \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_business_solution_delete {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_BID "^[a-zA-Z0-9]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token

  v_curl -s "${(e)ucr_base_url}/business/${UCR_BID}/solution/${UCR_SID}" -X DELETE \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_business_get {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_BID "^[a-zA-Z0-9]+$"
  get_token

  v_curl -s "${(e)ucr_base_url}/business/${UCR_BID}" \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_template_update {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local repo_url
  if [[ $# > 0 ]]; then
    repo_url=$1
  else
    repo_url=https://github.com/${${$(git remote get-url origin)#git@github.com:}%%.git}
    repo_url+="/tree/$(git rev-parse --abbrev-ref HEAD)"
  fi
  local req=$(jq -n -c --arg url "$repo_url" '{"url": $url}')
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/update \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_logs {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  # TODO: add support for the query option
  local opt_req=$(
    options_to_json \
    limit "[1-9][0-9]*" \
    offset "[1-9][0-9]*"
  )
  [[ -z "$opt_req" ]] && exit 4

  local q=$(jq -r 'to_entries|map("\(.key)=\(.value)")|join("&")' <<< $opt_req)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/logs\?${q} \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_tsdb_query {
  # metric names are just args, tags are <tag name>@<tag value>
  # others are all --options=value
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
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

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/query \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_recent {
  # recent <tag name> <metrics>… @<tag values>… 
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
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

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/recent \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_list_tags {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listTags \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" | jq '.tags |keys'
}

function ucr_tsdb_list_metrics {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listMetrics \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" | jq .metrics
  # someday: Look for .next, and handle repeated calls if need be
}

function ucr_tsdb_exports {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)
  local opt_req=$(
    options_to_json \
    limit "[1-9][0-9]*"
  )
  [[ -z "$opt_req" ]] && exit 4

  v_curl -s "${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/exportJobList?limit=${ucr_opts[limit]:-100}" \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_tsdb_export_info {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)
  local job_id=${1:?Need job id argument}

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/exportJobInfo \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "{\"job_id\":\"${job_id}\"}"
}

function ucr_tsdb_export {
  # metric names are just args, tags are <tag name>@<tag value>, formats are <metric>#<action>#<value>
  #
  # Formating parameters:
  # ORDER MATTERS! FE: round before label is different than label before round
  #
  # <metric>#label#<string>
  # 3456789#label#foo
  #   Prefix value with 'foo'
  #
  # <metric>#round#<number>
  # 3456789#round#9
  #   Round by 9
  #
  # <metric>#rename#<string>
  # 34567890#rename#bob
  #   Replace metric name with 'bob'
  #
  # <metric>#replace#<regexp>#<replace>
  # 123456#replace#([0-9])([0-9])#\2-\1
  #   Do regexp on value. replace uses '\1' for capture groups.
  #
  # <metric>|timestamp#datetime#<date format>#<offset>
  # 98765#datetime#year_%Y#-4
  #   Apply a datetime format to the value. Value should be microseconds since the EPOCH.
  #   Can use the `--timestamp` and `--offset` to shortcut for the `timestamp` column.

  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)
  # Validate a list of the options we will care about.
  # Ignored query options: (passing them does nothing)
  #  mode "(merge|split)"
  # Illegal query options: (passing them returns error)
  #  sampling_size "[1-9][0-9]*(u|ms|s|m|h|d|w)?"
  #  aggregate "((avg|min|max|count|sum),?)+" 
  local opt_req=$(
    options_to_json \
    start_time "[1-9][0-9]*(u|ms|s)?" \
    end_time "[1-9][0-9]*(u|ms|s)?" \
    relative_start "-[1-9][0-9]*(u|ms|s|m|h|d|w)?" \
    relative_end "-[1-9][0-9]*(u|ms|s|m|h|d|w)?" \
    limit "[1-9][0-9]*" \
    epoch "(u|ms|s)" \
    fill "(null|previous|none|[1-9][0-9]*|~s:.+)" \
    order_by "(desc|asc)"
  )
  [[ -z "$opt_req" ]] && exit 4

  # A few filtering only options.
  # These are all just once things, so it is cleaner to have them as options than as the '#' syntax
  local formated=$(
    options_to_json \
    timestamp ".*"\
    offset "-?[1-9][0-9]*" \
    include "[a-zA-Z0-9_,]+"
  )
  [[ -z "$formated" ]] && exit 4

  local filename=${ucr_opts[output]}
  if [[ -z "$filename" ]]; then
    filename="$(date +%s)_auto.csv"
  fi
  # if [[ "$filename" =~ "[\r\n\t\f\v ]" ]]; then
  #   echo "output file name cannot have spaces ($filename)" >&2
  #   exit 5
  # fi


  local req=$(jq --arg fn "$filename" --argjson ft "$formated" '{
    "query": (. + ($ARGS.positional | {
      "tags": ([.[] | select(contains("@")) | split("@") | {"key": .[0], "value": .[1]}] | group_by(.key) |
        map({"key":.[0].key,"value":(map(.value) | if length==1 then first else . end)}) | from_entries),
      "metrics": [.[]|select(contains("@") or contains("#")|not)]
    })),
    "filename": $fn,
    "format": (($ARGS.positional | [.[] | select(contains("#")) | split("#") | {
        "metric": .[0], "fn": .[1], "a": .[2], "b": .[3]
      }] | group_by(.metric) | map({"key":.[0].metric, "value": map(
        if .fn == "round" then {"round": .a|tonumber}
        elif .fn == "replace" then {replace: { match: .a, to: .b } }
        elif .fn == "datetime" then {datetime: { dt_format: (.a // "%Y-%m-%dT%H:%M:%S.%f%z"), offset: (.b // 0 | tonumber) }}
        else { (.fn): .a }
        end
      )}) | from_entries ) + if ($ft|has("timestamp") or has("offset")) then
        { "timestamp": [{datetime:{dt_format: ($ft.timestamp // "%Y-%m-%dT%H:%M:%S.%f%z"), offset: ($ft.offset // 0 | tonumber)}}] }
      else
        {}
      end + if ($ft|has("include")) then
        {"tags": [{normalize: $ft.include|split(",")}]}
      else
        {tags: [{discard: true}]}
      end
    )
  }' --args -- "${@}" <<< $opt_req)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/export \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_write {
  # write [--ts=<timestamp>] <metric> <value> [<metric> <value> …] [<tag>@<value> …]
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  local opt_req=$(options_to_json ts "[1-9][0-9]*(u|ms|s)?")
  [[ -z "$opt_req" ]] && exit 4

  local req=$(jq -c '. + ($ARGS.positional | map(split("@") | {"key": .[0], "value": .[1]} ) |
    { "tags": (map(select(.value)) | from_entries),
      "metrics": ([map(select(.value|not)|.key) | _nwise(2) | {"key": .[0], "value": .[1]}] | from_entries)
    })' --args -- "${@}" <<< $opt_req)
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/write \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_tsdb_multiWrite {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid tsdb | jq -r .id)

  # take STDIN
  local req=$(jq)
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/multiWrite \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_list {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local match=${1:-*}
  local req=$(jq -n -c --arg match "$match" '{"match":$match,"cursor":0}')

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_get {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  [[ $# == 0 ]] && echo "Missing keys to get" >&2 && exit 2
  local req=$(jq -n -c '{"keys":$ARGS.positional}' --args -- "${@}")

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/mget \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_set {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local key=${1:?Need key argument}
  local value=${2:?Need value to set}
  if [[ "$value" = "-" ]]; then
    value=$(</dev/stdin)
  fi

  local req=$(jq -n -c --arg key "$key" --arg value "$value" '{"key":$key,"value":$value}')

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/set \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_keystore_delete {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  [[ $# == 0 ]] && echo "Missing keys to delete" >&2 && exit 2
  local req=$(jq -n -c '{"keys":$ARGS.positional}' --args -- "${@}")

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/mdelete \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"  
}

function ucr_keystore_cmd {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid keystore | jq -r .id)
  local cmd=${1:?Need command argument}
  local key=${2:?Need key argument}
  shift 2
  local req=$(jq -n -c --arg key "$key" --arg cmd "$cmd" \
    '{"key":$key,"command":$cmd, "args": $ARGS.positional}' \
    --args -- "${@}")

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/command \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req" 
}

function ucr_insight_info {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need Insight Service Name}
  local service_uuid=$(ucr_service_uuid ${(L)service} | jq -r .id)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/info \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_insight_functions {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service=${1:?Need Insight Service Name}
  local service_uuid=$(ucr_service_uuid ${(L)service} | jq -r .id)
  local opt_req=$(
    options_to_json \
    limit "[1-9][0-9]*" \
    group_id "[0-9A-Za-z_]*"
  )
  [[ -z "$opt_req" ]] && exit 4
  local req=$(jq -c '{"limit":1000, "group_id":""} + .' <<< $opt_req)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listInsights \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_info {
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local id=${1:?Need file id}

  local req="{\"id\": \"$id\"}"

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/info \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_list {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  # list [--op=AND|OR] [--stop=#] [<prefix filter>] [<tag name filter>@<tag value filter> ...]
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local opt_req=$(options_to_json \
    op "^(AND|OR)$" 
  )
  [[ -z "$opt_req" ]] && exit 4

  local p_req=$(jq -c '. + ($ARGS.positional | map(split("@") | {"key": .[0], "value": .[1]} ) |
    {
      "tags": (map(select(.value)) | from_entries | tojson),
      "prefix": (map(select(.value|not)|.key) | first),
      "full": true
    } | del(.[] | select(. == null)))' --args -- "${@}" <<< $opt_req)

  local prior_count=1
  local total_count=0
  local stop_after=${ucr_opts[stop]:-999999999}
  local cursor=''

  # first call always happens and has no cursor.
  local ret=$(
    v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
      -H 'Content-Type: application/json' \
      -H "Authorization: token $UCR_TOKEN" \
      -d "$p_req"
  )
  prior_count=$(jq -r length <<< $ret)
  total_count=$(( total_count + prior_count ))
  cursor=$(jq -r 'last | .id' <<< $ret)
  # Now 'stream' results
  jq -c -M '.[]' <<< $ret

  # Loop advancing cursor until an empty reply
  while [[ prior_count -gt 0 && total_count -lt stop_after ]]; do
    local req=$(jq -c --arg cursor "$cursor" '. + {"cursor": $cursor}' <<< $p_req)
    local ret=$(
      v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
        -H 'Content-Type: application/json' \
        -H "Authorization: token $UCR_TOKEN" \
        -d "$req"
    )
    prior_count=$(jq -r length <<< $ret)
    total_count=$(( total_count + prior_count ))
    cursor=$(jq -r 'last | .id' <<< $ret)
    # Now 'stream' results
    jq -c -M '.[]' <<< $ret
  done
}

function ucr_content_delete {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local req=$(jq -n -c '{ "body" : $ARGS.positional }' --args -- "$@")

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/deleteMulti \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_download {
  # doesn't actually download, just returns a URL to download from.
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local cid=${1:?Need content id to download}
  local opt_req=$(options_to_json \
    expires_in "^\d+$" \
  )
  [[ -z "$opt_req" ]] && exit 4
  local req=$(jq -c --arg cid "$cid" '. + {"id": $cid|@uri }' <<< $opt_req)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/download \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_content_upload {
  # Doesn't actually upload, just returns a cURL to upload to.
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid content | jq -r .id)
  local cid=${1:?Need content id to upload}
  local opt_req=$(options_to_json \
    expires_in "^\d+$" \
    type "^.+$" \
  )
  [[ -z "$opt_req" ]] && exit 4

  # A GET req with url encoded file name and query options for the rest.
  local req=$(jq -n -c --arg cid "$cid" '{"id": $cid|@uri }')
  local psu=$(v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/upload \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
  )

  # Convert to new curl params
  local params=($(jq '(.inputs|to_entries|[.[]|"-F", "\"\(.key)=\(.value)\""]) + (["-F", "\"\(.field)=@\(.id)\"", .url]) |.[]' -r <<< $psu))
  echo curl -X POST "${params[@]}"
}

function ucr_ws_info {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid websocket | jq -r .id)
  local skid=${1:?Need websocket id}
  local req=$(jq -c -n --arg skid "$skid" '{"socket_id": $skid}')

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/info \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "$req"
}

function ucr_ws_list {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid websocket | jq -r .id)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/list \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" 
}

function ucr_device_list {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  get_token
  local service_uuid=$(ucr_service_uuid device2 | jq -r .id)
  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/listIdentities \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN"
}

function ucr_device_info {
  ucr_service_details device2
}

function ucr_device_state {
  want_envs UCR_HOST "^[\.A-Za-z0-9:-]+$" UCR_SID "^[a-zA-Z0-9]+$"
  local did=${1:?Need device id}
  get_token
  local service_uuid=$(ucr_service_uuid device2 | jq -r .id)

  v_curl -s ${(e)ucr_base_url}/solution/${UCR_SID}/serviceconfig/${service_uuid}/call/getIdentityState \
    -H 'Content-Type: application/json' \
    -H "Authorization: token $UCR_TOKEN" \
    -d "{\"identity\": \"${did}\" }"
}

# This sets via the cloud side API.
# function ucr_device_state_set { }

function ucr_device_write {
  # This writes via the external HTTP API.
  # Only one resource at a time for now. Could expand to allow multiple, but not needed today.
  # ucr device write <did> <resource> <value>
  local did=${1:?Need device id}
  local res=${2:?Need a resource to write}
  local val=${3:?Need a value}
  get_token
  local details=$(ucr_service_details device2)
  local d_host=$(jq -r .parameters.fqdn <<< $details)
  local vm=$(jq -r .solution_id <<< $details)

  # server actually only supports a subset of form-urlencoded, so manually pack it
  val=$(jq -r '@uri' <<< $val)
  v_curl -s https://${d_host}/onep:v1/stack/alias \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=utf-8' \
    -H "X-Exosite-CIK: ${UCR_CIK}" \
    -d "${res}=${val}"
}

function ucr_device_activate {
  # This activates via the external HTTP API.
  local did=${1:?Need device id}
  get_token
  local details=$(ucr_service_details device2)
  local d_host=$(jq -r .parameters.fqdn <<< $details)

  # server actually only supports a subset of form-urlencoded, so manually pack it
  # did=$(jq -r '@uri' <<< $did)
  v_curl -s https://${d_host}/provision/activate \
    -d "id=${did}" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=utf-8'
}

############################################################################################################

function dtog_function_not_found {
  for i in "$@"; do
    if [[ ${#i} < 33 ]]; then
      echo "$i" | sed -E 's/^(........)(....)(....)(....)(............)/\1-\2-\3-\4-\5/' | tr A-F a-f
    else
      echo "$i" | tr -d - | tr A-F a-f
    fi
  done
}

############################################################################################################

function jmq_q {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  # --fields=*all to get everything
  local jql=($@)
  local fields=(key summary)
  if [[ -n ${ucr_opts[fields]} ]]; then
    fields=(${(s:,:)ucr_opts[fields]})
  fi
  local req=$(jq -n -c --arg jql "${(j: :)jql}" '{"jql": $jql, "fields": $ARGS.positional }' --args -- ${fields})
  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req"
}

function jmq_pr {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  key=${key##*/}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  if [[ $key =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    key="key=$key"
  fi
  local req=$(jq -n -c --arg jql "$key" '{"jql": $jql, "fields": ["key","summary"] }')

  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | .fields.summary + " (" + .key + ")"' 2>/dev/null
}

function jmq_branch {
  # Get the Key from the branch name
  local ref=${$(git symbolic-ref --short HEAD 2>/dev/null || echo ""):t}
  # Does this look like a Jira issue key? If so, use it. Otherwise return empty.
  if [[ $ref =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    echo $ref
  fi
}

function jmq_next {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  local summary=$(v_curl -s --netrc https://${JMQ_HOST}/rest/api/2/issue/${key}\?fields=summary | \
    jq -r .fields.summary )

  # Get what transitions can be made.
  local transitions=$(v_curl -s https://${JMQ_HOST}/rest/api/2/issue/${key}/transitions --netrc)

  # Display menu list and ask which to take. (If only one, then just take that without asking)
  local trn=$(jq -r '.transitions[] | [.id, .name] | @tsv' <<< $transitions | fzf \
    --select-1 --no-multi --nth=2.. --with-nth=2.. --height 30% \
    --prompt="Follow which transition? " \
    --header="Summary: ${summary}")
  if [[ -z "$trn" ]]; then
    exit
  fi
  local transition_id=$(awk '{print $1}' <<< $trn )
  # Take it
  v_curl -s https://${JMQ_HOST}/rest/api/2/issue/${key}/transitions \
    --netrc \
    -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\": ${transition_id} }}"
}

# Move tickets to named state
# jmq move FOO-0000 In Progress
function jmq_move {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
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
  local transitions=$(v_curl -s https://${JMQ_HOST}/rest/api/2/issue/${key}/transitions --netrc)

  local inp_id=$(jq --arg nme "$state" '.transitions[]|select(.name==$nme)|.id' <<< $transitions)
  if [[ -z "$inp_id" ]]; then
    echo "Cannot directly transition to $state" 
    exit
  fi

  v_curl -s https://${JMQ_HOST}/rest/api/2/issue/${key}/transitions \
    --netrc \
    -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\": ${inp_id} }}"
}

function jmq_as_status {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local stat=${1:?Missing Issue Status}
  local jql=(
    "assignee = currentUser()"
    "status = \"$stat\" ORDER BY Rank"
  )
  if [[ -z "${ucr_opts[all]}" ]]; then
    jql=(
      "project in (${JMQ_PROJECTS})"
      $jql
    )
  fi
  local req=$(jq -n -c --arg jql "${(j: AND :)jql}" '{"jql": $jql, "fields": ["key","summary"] }')

  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | [.key, .fields.summary] | @tsv'
}

function jmq_todo {
  jmq_as_status "On Deck"
}

function jmq_doing {
  jmq_as_status "In Progress"
}

function jmq_info {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  if [[ $key =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    key="key=$key"
  fi
  local fields=(
    key
    summary
    description
    assignee
    reporter
    priority
    issuetype
    status
    resolution
    votes
    watches
    customfield_10820 # Tester
    )
  local req=$(jq -n -c --arg jql "$key" '{"jql": $jql, "fields": $ARGS.positional }' --args -- ${fields})

  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | 
      "        Key: \(.key)
    Summary: \(.fields.summary)
   Reporter: \(.fields.reporter.displayName)
   Assignee: \(.fields.assignee.displayName)
     Tester: \(.fields.customfield_10820.displayName?)
       Type: \(.fields.issuetype.name) (\(.fields.priority.name))
     Status: \(.fields.status.name) (Resolution: \(.fields.resolution.name))
    Watches: \(.fields.watches.watchCount)  Votes: \(.fields.votes.votes)
Description: \(.fields.description)"'
}

function jmq_status {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local statuses=("On Deck" "In Progress" "Validation")
  local jql=(
    "project in (${JMQ_PROJECTS})"
    "status in (\"${(j:",":)statuses}\")"
    "assignee = currentUser() ORDER BY Rank"
  )
  local req=$(jq -n -c --arg jql "${(j: AND :)jql}" '{"jql": $jql, "fields": ["key","summary","status"] }')

  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq --argjson sts "[\"${(j:",":)statuses}\"]" -r '.issues |
  group_by(.fields.status.name) |
  map({"key": .[0].fields.status.name, "value": map([("- "+.key), .fields.summary] | @tsv) | join("\n")}) |
  map(select([.key] | inside($sts))) |
  map([(.key+":"), .value] | join("\n")) |
  flatten | 
  join("\n\n")'
}

function jmq_open {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  open https://${JMQ_HOST}/browse/${(U)key}
}

function jmq_mdl {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  print "[${(U)key}](https://${JMQ_HOST}/browse/${(U)key})"

}

# list files/attachments on a ticket
function jmq_files {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  if [[ $key =~ "^[a-zA-Z]+-[0-9]+$" ]]; then
    key="key=$key"
  fi
  local fields=(
    key
    summary
    attachment
    )
  local req=$(jq -n -c --arg jql "$key" '{"jql": $jql, "fields": $ARGS.positional }' --args -- ${fields})

  v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req" | jq -r '.issues[] | .fields.attachment[] | [.filename, .mimeType, .content]|@tsv'

  # XXX: do not like this output. (things are too long.)
}

function jmq_attach {
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$"
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi
  shift
  if [[ $# = 0 ]]; then
    echo "Missing files to upload"
    exit 2
  fi

  for f in "$@"; do
    if [[ -d "$f" ]]; then
      local dst=$(mktemp -t ${f##*/}.XXXXXX.zip)
      zip -r -q ${dst} ${f}
      f=${dst}
    fi
    v_curl -s https://${JMQ_HOST}/rest/api/2/issue/${key}/attachments \
    	-H 'X-Atlassian-Token: nocheck' \
      --netrc \
      -F "file=@${f}"
  done

}

function jmq_labels {
  # lables <tickets…>
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local keys=($@)
  if [[ $# = 0 ]]; then
    keys=($(jmq_branch))
  fi
  # in place, replace any numbers with the project prefix
  for (( i=1; i <= ${#keys}; i++ )); do
    if [[ ${keys[$i]} =~ "^[0-9]+$" ]];then
      keys[$i]=${JMQ_PROJECTS%%,*}-${keys[$i]}
    fi
  done
  local jql="key in (${(j:,:)keys})"
  local req=$(jq -n -c --arg jql "$jql" '{"jql": $jql, "fields": ["key", "labels"] }') 
  local res=$(v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req"
    )
    if [[ $# = 1 ]]; then
      # if one key, then just print labels.
      jq -r '.issues[0].fields.labels[]' <<< $res
    else
      # if many, then print yaml like keys and labels
      jq -r '.issues[] | {(.key): .fields.labels} | to_entries | .[] | .key + ": " + (.value | join(", "))' <<< $res
    fi
}

function jmq_label_add {
  # label add <label> <tickets…>
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local label=${1:-Missing a label}
  shift
  local keys=($@)
  if [[ $# = 0 ]]; then
    keys=($(jmq_branch))
  fi
  # in place, replace any numbers with the project prefix
  for (( i=1; i <= ${#keys}; i++ )); do
    if [[ ${keys[$i]} =~ "^[0-9]+$" ]];then
      keys[$i]=${JMQ_PROJECTS%%,*}-${keys[$i]}
    fi
  done
  
  local req=$(jq -n -c --arg label "$label" '{"update":{"labels":[{"add":$label}]}}')

  for key in $keys; do
    v_curl -s -X PUT https://${JMQ_HOST}/rest/api/2/issue/${key} \
      -H 'Content-Type: application/json' \
      --netrc \
      -d "$req"
  done
}

function jmq_label_del {
  # label add <label> <tickets…>
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local label=${1:-Missing a label}
  shift
  local keys=($@)
  if [[ $# = 0 ]]; then
    keys=($(jmq_branch))
  fi
  # in place, replace any numbers with the project prefix
  for (( i=1; i <= ${#keys}; i++ )); do
    if [[ ${keys[$i]} =~ "^[0-9]+$" ]];then
      keys[$i]=${JMQ_PROJECTS%%,*}-${keys[$i]}
    fi
  done
  
  local req=$(jq -n -c --arg label "$label" '{"update":{"labels":[{"remove":$label}]}}')

  for key in $keys; do
    v_curl -s -X PUT https://${JMQ_HOST}/rest/api/2/issue/${key} \
      -H 'Content-Type: application/json' \
      --netrc \
      -d "$req"
  done
}

function jmq_links {
  # links <tickets>
  # lists the links and types for one or more tickets
  want_envs JMQ_HOST "^[\.A-Za-z0-9-]+$" JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
  local keys=($@)
  if [[ $# = 0 ]]; then
    keys=($(jmq_branch))
  fi
  # in place, replace any numbers with the project prefix
  for (( i=1; i <= ${#keys}; i++ )); do
    if [[ ${keys[$i]} =~ "^[0-9]+$" ]];then
      keys[$i]=${JMQ_PROJECTS%%,*}-${keys[$i]}
    fi
  done
  # Setup to be future configurable
  local line_opts_json='{"color":"red"}'

  local jql="key in (${(j:,:)keys})"
  local req=$(jq -n -c --arg jql "$jql" '{"jql": $jql, "fields": ["key", "issuelinks", "fixVersions", "labels"] }') 
  local res=$(v_curl -s https://${JMQ_HOST}/rest/api/2/search \
    -H 'Content-Type: application/json' \
    --netrc \
    -d "$req"
    )
  local map=$( jq -r '[ .issues[] | .key as $issueKey |
      .fields.issuelinks[] | 
      if has("inwardIssue") then
        [.type.name, .inwardIssue.key, $issueKey]
      else
        [.type.name, $issueKey, .outwardIssue.key]
      end
      ] | unique' <<< $res)

  if [[ -n "${ucr_opts[dot]}" ]]; then
    # as a graph thru dot
    echo "digraph {"
    # Subgraphs for releases
    jq -r '[ .issues[] | .key as $issueKey |
        .fields.fixVersions[] | 
        {"key":$issueKey, "value": .name}
      ] | reduce .[] as {$key,$value} ({}; .[$value] += [$key]) |
      to_entries | 
      map("subgraph \"cluster_" + .key + "\" {\n label=\"" + .key + "\";\n" + 
        (.value | map(" \""+.+"\";") | join("\n")) + "\n}"
        ) | join("\n")' <<< $res

    # Subgraphs for labels (filter for specific labels?)
    jq -r '[.issues[] | {"key":.key, "value":.fields.labels[]}] | reduce .[] as {$key,$value} ({}; .[$value] += [$key]) |
      to_entries | map("subgraph \"cluster_" + .key + "\" {\n label=\"" + .key + "\";\n style=dashed;\n" + 
        (.value | map(" \""+.+"\";") | join("\n")) + "\n}"
        ) | join("\n")' <<< $res
  
    # Links
    jq -r --argjson lineopts "$line_opts_json" '.[] | 
      "\"\(.[1])\" -> \"\(.[2])\" [" +
      (($lineopts) | to_entries | map("\(.key)=\(.value)") | join(", ")) +
      "]"' <<< $map 
    echo "}"
  else
    # as a table thru xsv
    jq -r '.[] | @csv' <<< $map | xsv table
  fi
}

function jmq_merge {
  # merge <ticket> [<branch>]
  local key=${${1:-$(jmq_branch)}:?Missing Issue Key}
  local into=${2:-stable}
  if [[ $key =~ "^[0-9]+$" ]];then
    want_envs JMQ_PROJECTS "^[A-Z]+(,[A-Z]+)*$"
    key=${JMQ_PROJECTS%%,*}-$key
  fi

  local branch=$(git branch --format '%(refname:short)' --list "*${key}")
  local prn=$(gh pr list --limit 1 --head $branch --json number --jq '.[].number')

  local remember=""
  local needs_stash=""

  needs_stash="$(git status --untracked-files=no --porcelain)"
  [[ -n "$needs_stash" ]] && git stash
  remember=$(git symbolic-ref --quiet HEAD 2>/dev/null)

  git checkout $into

  git merge --no-ff -m "$(jmq_pr $key) (#$prn)" $branch

  [[ -n "$remember" ]] && git checkout "${remember#refs/heads/}"
  [[ -n "$needs_stash" ]] && git stash pop
}

############################################################################################################

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

function murdoc_namer {
  # If exists AND younger than 2 days, then cache_file is not empty. (use the cache file)
  # Otherwise, update cache
  if [[ ! -f ~/.murdoc_names_cache ]]; then
    murdoc_names | tr -d / > ~/.murdoc_names_cache
  fi
  cache_file=~/.murdoc_names_cache(N,md-2)
  if [[ -z "$cache_file" ]]; then
    murdoc_names | tr -d / > ~/.murdoc_names_cache
  fi
  fzf -1 --no-multi --query "${1:-m}" < ~/.murdoc_names_cache
}

function murdoc_env {
  want_envs SSHTO ".*"
  local key=$(murdoc_namer ${1:?Missing Container Name})
  ${=SSHTO} "sudo docker inspect $key" | jq -r '.[0].Config.Env[]'
}

function murdoc_image_id {
  want_envs SSHTO ".*"
  local key=$(murdoc_namer ${1:?Missing Container Name})
  local name=$(${=SSHTO} "sudo docker inspect $key" | jq -r '.[0].Config.Image')
  ${=SSHTO} "sudo docker inspect $name" | jq -r '.[0].RepoDigests[]'
}

function murdoc_labels {
  want_envs SSHTO ".*"
  local key=$(murdoc_namer ${1:?Missing Container Name})
  ${=SSHTO} "sudo docker inspect $key" | jq -r '.[0].Config.Labels | to_entries | .[] | .key + "=" + .value'
}

function murdoc_commit {
  want_envs SSHTO ".*"
  local key=$(murdoc_namer ${1:?Missing Container Name})
  ${=SSHTO} "sudo docker inspect $key" | \
    jq -r '.[0].Config.Labels | to_entries | map(select(.key | test("commit"; "i"))) | .[] | [.key, .value]|@csv' | \
    xsv table
}

# Get envs for service, reshape into envs for mongo, load them and call mongo.
function murdoc_mongo {
  local prefix=MONGO_
  if [[ -n "${ucr_opts[log]}" ]]; then
    prefix=LOG_MONGODB_
  fi
  if [[ -n "${ucr_opts[prefix]}" ]]; then
    prefix=${ucr_opts[prefix]}
  fi

  ens=($(murdoc_env $1 | grep ^${prefix} |sed -e "s/^${prefix}//" ))

  typeset -A mongo_keys
  for r in $ens; do
    if [[ "$r" =~ "([a-zA-Z0-9_]+)=(.*)" ]]; then
      mongo_keys[${match[1]}]=${match[2]}
    fi
  done

  #only URL for now…
  mongo "${mongo_keys[URL]}"
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

############################################################################################################

# Get all of the sections from the worldbuilder file
function worldbuilder_sections {
  want_envs WORLDBUILDER_FILE "^.+$"

  while read -r line; do
    if [[ "$line" =~ "^\[([^]]*)\]"  ]]; then 
      echo ${match[1]}
    fi
  done < "$WORLDBUILDER_FILE"
}

# Fuzzy match a section from the worldbuilder file
function worldbuilder_namer {
  worldbuilder_sections | fzf -1 --no-multi --query "${1:-m}"
}

function worldbuilder_example_branch {
  # write out an example ini
  cat <<EOE
[name-of-thing]
commit=branch_to_checkout
dir=relative/directory/path/to/thing
image=container/name:thing
type=docker|zip

EOE
}

# Creates a new worldbuilder file based on the current one, updating the commit hash for each section.
# The new commits are pulled from a release tag on github.
function worldbuilder_pull_next_release {
  # Needs a tag/release; pulls the txt assets from github; lifts the commit hashes for each repo
  # and writes out an ini file based on the currently loaded one.
  want_envs WORLDBUILDER_FILE "^.+$"
  local tmpDir=$(mktemp -d)
  # echo "Pulling to $tmpDir" >&2
  local tag=${1:?Need a tag to pull}
  local repo=${2:-exosite/murano}

  # get the release assets
  gh release download -R "$repo" "$tag" -D "$tmpDir" -p '*.txt' --clobber

  # get the commit hashes
  # Since that's all we're after, we can use an associative array to store them.
  typeset -A commits
  local section
  while read -r line; do
    if [[ "$line" =~ "^([^:]*):"  ]]; then
      section=${match[1]}
    fi
    if [[ "$line" =~ "^commit=(.+)$"  ]]; then
      commits[${section}]=${match[1]}
    fi
  done < "$tmpDir"/murano-*.txt

  # Now read the ini file and write out a new one with the commits
  section=""
  while read -r line; do
    if [[ "$line" =~ "^\[([^]]*)\]"  ]]; then 
      section=${match[1]}
      echo "$line"
    elif [[ "$line" =~ "^commit=(.*)$" && -n "$commits[(Ie)$section]" ]]; then
      # if commit line and we have a commit, write it out
      echo "commit=${commits[${section}]}"
    else
      echo "$line"
    fi
  done < "$WORLDBUILDER_FILE"

  rm -rf "$tmpDir"
}

# Builds an image from a section in the worldbuilder file.
# Doing its best to be idempotent.
function worldbuilder_build {
  want_envs WORLDBUILDER_FILE "^.+$"
  local whom=$(worldbuilder_namer ${1:?Need something to fetch})
  load_from_ini "$WORLDBUILDER_FILE" "$whom"
  [[ ! -v "type" ]] && typeset -g -x type=docker
  [[ ! -v "platform" ]] && typeset -g -x platform=linux/arm64

  want_envs dir "^.+$" image "^.+$" type "^.+$" commit "^.*$"

  local base=$PWD
  local imagesDir=_images_${${WORLDBUILDER_FILE#wb_}:r}

  (
    # set -x
    cd ${dir}

    ## BUILD
    local remember=""
    local needs_stash=""
    if [[ -n "$commit" ]]; then
      needs_stash="$(git status --untracked-files=no --porcelain)"
      [[ -n "$needs_stash" ]] && git stash

      remember=$(git symbolic-ref --quiet HEAD 2>/dev/null)
      git checkout "${commit}"
    fi

		if [[ "$type" == "docker" ]]; then
      # Someday, rewrite _all_ the dockerfiles to use --ssh
      if grep -s murano-service-ssh-key Dockerfile >/dev/null; then
        cp ~/.ssh/murano_builder murano-service-ssh-key
      fi

     docker buildx build \
      --label com.exosite.build.git_commit="$(git rev-parse HEAD)" \
      --load \
      --tag "${image}" \
      --platform="${platform}" \
      .

      test -e murano-service-ssh-key && rm murano-service-ssh-key

      # save image
      docker save -o ${base}/${imagesDir}/${${image/%:*}:t}.tar "${image}"

    elif [[ "$type" == "zip" ]]; then
      # zip up the directory or update an existing zip file
      local imgFile=${base}/${imagesDir}/${${image/%:*}:t}.zip
      zip -r -FS ${imgFile} . -x "*.git*" 2>&1 | wc -l
        # pv -lep -s $(find . -name "*.git*" -prune -o -type fd | wc -l) > /dev/null
    else
      echo "Unknown type: $type" >&2
      exit 1
    fi

    [[ -n "$remember" ]] && git checkout "${remember#refs/heads/}"
    [[ -n "$needs_stash" ]] && git stash pop
  )
}

function worldbuilder_inject {
  want_envs WORLDBUILDER_HOST "^[A-Za-z]+$"
  local whom=$(worldbuilder_namer ${1:?Need something to fetch})
  local imagesDir=_images_${${WORLDBUILDER_FILE#wb_}:r}
  load_from_ini "$WORLDBUILDER_FILE" "$whom"
  if [[ ! -v "type" ]]; then
    type=docker
  fi
  want_envs image "^.+$" type "^.+$"

  if [[ "$type" == "docker" ]]; then
    set -e
    ssh ${WORLDBUILDER_HOST} -- mkdir -p /tmp/images
    scp ${imagesDir}/${${image/%:*}:t}.tar ${WORLDBUILDER_HOST}:/tmp/images/${${image/%:*}:t}.tar
    ssh ${WORLDBUILDER_HOST} -- docker load -i /tmp/images/${${image/%:*}:t}.tar
    ssh ${WORLDBUILDER_HOST} -- rm /tmp/images/${${image/%:*}:t}.tar
  elif [[ "$type" == "zip" ]]; then
    set -e
    ssh ${WORLDBUILDER_HOST} -- mkdir -p /tmp/images
    scp ${imagesDir}/${${image/%:*}:t}.zip ${WORLDBUILDER_HOST}:/tmp/images/${${image/%:*}:t}.zip
    ssh ${WORLDBUILDER_HOST} -- unzip -q -o /tmp/images/${${image/%:*}:t}.zip -d ${dest:-/tmp/images/barf}
    ssh ${WORLDBUILDER_HOST} -- rm /tmp/images/${${image/%:*}:t}.zip
  else
    echo "Unknown type: $type" >&2
    exit 1
  fi
}

function worldbuilder_all_build {
  worldbuilder_foreach worldbuilder_build
}

function worldbuilder_all_inject {
  worldbuilder_foreach worldbuilder_inject
}

function worldbuilder_foreach {
  local start=$(date +%s)
  local cmd=${1:?Need a command to run}
  if [[ -n "${ucr_opts[time]}" ]]; then
    date +%Y-%m-%dT%H:%M:%S%z
  fi

  for sec in $(worldbuilder_sections); do
    $cmd $sec
  done

  if [[ -n "${ucr_opts[time]}" ]]; then
    date +%Y-%m-%dT%H:%M:%S%z
    local stop=$(date +%s)
    echo "Took: $((stop - start))"
  fi
}

##############################################################################
# This needs to be last.
task_runner "$*"
