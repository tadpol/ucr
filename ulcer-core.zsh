#!/usr/bin/env zsh
# set -e

# compute this from script name
# Plan is to enable having multiple versions of this with different names
# argv0=${${0:t}:r}


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

config_location=$HOME/.${argv0}rc
[[ -f "$HOME/.config/${argv0}/config" ]] && config_location=$HOME/.config/${argv0}/config

# First load user defaults (under any existing ENVs)
load_from_ini "$config_location" default false

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
  for arg in "$@"; do
    # echo ":check: $arg" >&2
    if [[ "$double_dash" = "true" ]]; then
      leftovers[${#leftovers}+1]=$arg
    elif [[ "$arg" =~ "^--$" ]]; then
      double_dash=true
    elif [[ "$arg" =~ "^--sec=(.*)$" ]]; then
      # Handle --sec as it appears; this allows the keys it sets to be overridden by following args
      ucr_opts[sec]=${match[1]}
      local cfg=${ucr_opts[cfg]:-$config_location}
      load_from_ini "$cfg" "${ucr_opts[sec]}"
    elif [[ "$arg" =~ "^--help$" ]]; then
    	# Force calling the help function.
      # For any task, the following two are equivalent:
      # - prefix task --help
      # - prefix help task
      leftovers=(help "${leftovers[@]}")
    elif [[ "$arg" =~ "^--" ]]; then
      # long option
      local opt=${arg#--}
      if [[ "$opt" =~ "^([^=]+)=(.*)" ]]; then
        ucr_opts[${match[1]}]=${match[2]}
        # ??? change multiple longs to append/group instead of overwrite?
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

  # echo ":do " ${ucr_cmdline[1]} "${ucr_cmdline[2,-1]}" "!" >&2
  ${ucr_cmdline[1]} "${ucr_cmdline[2,-1]}"
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
      echo "ENV[$key] (${(P)key}) invalid by: ${tests[$key]}" >&2
      exit 3
    fi
  done
}

# Checks that if an option was specified, it validates
# Then outputs a JSON object of the options and values.
#
# Values can be coerced into a type by appending `::<type>` to the key name.
# types would just be the JSON ones, so string, number, boolean, array, object
# default type is 'auto' which makes number like strings into numbers and the rest is strings.
#
#  ? maybe if --help, then dump all of the options and exit? this idea doesn't fit the usage of this function.
function options_to_json {
  typeset -A maybe_opts=($*)
  local build_req=()
  local key
  local key_type
  for key_m in ${(k)maybe_opts}; do
    # if key has `::type` suffix, break that off and update key
    if [[ $key_m =~ "::" ]]; then
      key_type=${key_m##*::}
      key=${key_m%%::*}
    else
      key_type=auto
      key=$key_m
    fi
    if [[ -n "${ucr_opts[$key]}" ]]; then
      if [[ ${ucr_opts[$key]} =~ ${maybe_opts[$key_m]} ]]; then
      	case $key_type in
      	  number)
      	    build_req+="\"${key}\":${ucr_opts[$key]}"
      	    ;;
      	  boolean)
            # want to convert 1,yes,true,ok,y,t all to `true` and anything else to `false`
            local trues=(1 yes true ok y t)
            if [[ ${trues[(ie)${ucr_opts[$key]}]} -le ${#trues} ]]; then
              build_req+="\"${key}\":true"
            else
              build_req+="\"${key}\":false"
            fi
      	    ;;
      	  string)
      	    build_req+="\"${key}\":\"${ucr_opts[$key]}\""
            ;;
          array|object|json)
            build_req+="\"${key}\":$(jq -c <<< ${ucr_opts[$key]})"
            ;;
      	  *)
            # should be auto; 
            # if it looks like a number, use a number.
            if [[ ${ucr_opts[$key]} =~ "^[0-9]+$" ]]; then
              build_req+="\"${key}\":${ucr_opts[$key]}"
            else
              build_req+="\"${key}\":\"${ucr_opts[$key]}\""
            fi
      	    ;;
        esac
      else
        echo "Option: '$key' is not valid according to ${maybe_opts[$key_m]}" >&2
        exit 3
      fi
    fi
  done
  echo "{ ${(j:, :)build_req} }"
}

# Above is functions and such to be the core.
##############################################################################

# Add a wrapper to curl that will print out the curls.
function v_curl {
  # only use `op ` if we are using an ENV variable
  local use_op=false
  for (( i = 1; i < $#argv; i++ )); do
    if [[ "${argv[i]}" == --variable && "${argv[i+1]}" == %* ]]; then
      use_op=true
      break
    fi
  done

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
  # Just skipping causes issues in some places where output is piped. (you have been warned)
  if [[ -z "$ucr_opts[dry]" ]]; then
    if [[ "$use_op" = "true" ]]; then
      op run -- curl "$@"
    else
      curl "$@"
    fi
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
function ${(L)argv0}_help_tasks {
  echo "${(L)argv0} tasks"
  echo "  List all of the tasks that have been defined."
}
function ${(L)argv0}_tasks {
  for fn in ${(@ok)functions[(I)${(L)argv0}_*]}; do
    [[ $fn != *"_help_"* ]] && echo ${${fn#${(L)argv0}_}//_/ }
  done
}

function ${(L)argv0}_help_state {
  echo "${(L)argv0} state"
  echo "  Display the current state of the environment."
  echo "  This includes all ENV variables, options, and arguments as they have been parsed and loaded"
  echo "  from config files and command line"
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
if [[ $ZSH_EVAL_CONTEXT == 'toplevel' ]]; then
  # Display a message explaining that you should not call this script and 
  # instead use one of the wrapping task sets
  echo "This is a library file, not a script to run directly." >&2
  echo "You should source this file in your script and then define functions to run." >&2
  echo "Instead try one of these:" >&2
  echo "  ucr tasks" >&2
  echo "  jmq tasks" >&2
  echo "  exo tasks" >&2
  echo "  murdoc tasks" >&2
  echo "  worldbuilder tasks" >&2
  exit 1
fi
