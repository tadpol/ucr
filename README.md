# Ucr (Ulcer?)

Ucr started as a tool for merging RESTful APIs with the command line.  It does this as thinly as it possibly can.  Which means it is more of a scripting pattern than anything else. It has grown beyond just RESTful things, and is mostly a foundation for tools.

The main need for this is to handle large amount of boilerplate and repeating parts of calling the API, reducing it down to a short commandline invocation with just the variable parts specified.  The other main use is for the APIs where there are multiple calls required in order to get the desired result.

It is written in ZSH, as a few functions that handle a majority of parsing options, arguments, environments, and mapping to function calls.  Prior versions of UCR were written in Swift, Go, and Ruby.  However in the drive to reduce it to really just what was needed, it eventually was stripped down to its current form.

Ucr was an acronym for something, but I've long forgotten what it was.  I call it `ulcer`, which is referencing the pain induced by prior tools trying to achieve similar goals.

## Installation

Ulcer is now split into core and task files.  Everything gets installed into your PATH.

A `bin/` folder in your home directory is a good place. (and add that to your PATH if not already)

To install all of the tools here into `$HOME/bin/`:

```zsh
for e in *(*N); do
  install -C -m 0755 -S $e $HOME/bin/
done
```

Or you want to always run the version here:

```zsh
for e in *(*N); do
  ln -s $PWD/$e $HOME/bin/$e
done
```

### Dependencies

As ucr is just a schell script, the heavy lifting is done by other programs.  Following is brief list of programs used; not all tasks use all of the programs listed.

#### Used by all

- [ZSH](http://zsh.sourceforge.net)
- [curl](https://curl.se)
- [jq](https://stedolan.github.io/jq/)
- [fzf](https://github.com/junegunn/fzf#table-of-contents)
- grep
- sed
- awk

#### ucr

- [op](https://developer.1password.com/docs/cli)
- `security` but usage is untested/broken.

ucr tries to find login info using either `op`, `security` (on macos), or a builtin `.netrc` parser.

#### Jmq

- [gh](https://cli.github.com/)
- git
- [mlr](https://github.com/johnkerl/miller)
- open
- zip

Jmq exclusively uses the `--netrc` option to `curl` to manage login info.

#### Exo

- [yq](https://mikefarah.gitbook.io/yq)

#### Murdoc

- docker
- [mlr](https://github.com/johnkerl/miller)
- mongosh | mongo
- psql
- redis-cli
- ssh
- ssh-keygen
- ssh-keyscan

#### Worldbuilder

- docker
- [gh](https://cli.github.com/)
- git
- scp
- ssh
- zip

## Usage

There is unfortunately no built in help.

`$scriptname <options>|<args>|<keys>`

options: short or long

Short options can be either `-a -b -c` or `-abc`, and repeated `-vvvv`.

Long options can be boolean true `--term` or false `--no-term`.  Long options can be given any value `--term=value`.  If a long option is repeated, the last one is the value used.

Keys are an argument with a `=`, such as `sid=qwerty`.  These are converted into environment variables.  The key name is converted to uppercase and prefixed with the script name. (So `sid=qwerty` gets exported as `${(U)scriptname}_SID=qwerty`)

After all options and keys have been removed from the argument list, the remaining args are used to search for a function.  This is done by prefixing the script name and adding `_` between args.  If a function is not found, the last argument is dropped and searched again. If nothing is found after trying all subpatterns, then the function `${scriptname}_function_not_found` is called.

`$scriptname tasks` is useful to see what tasks have been defined.

`$scriptname state` is useful to see how arguments have been parsed.

### Config files

If there is a `.env` file in the current directory, all of the key=values in it will get loaded into the ENV.

A sectioned config file can be put at `$HOME/.config/${scriptname}/config`. (The old location of `$HOME/.${scriptname}rc` will be checked if there is no file in .config) This follows a simple INI format.  Everything before the first section will always get loaded.  Following sections can be loaded with the `--sec=<section>` option.  All of these are loaded into the ENV.

Keys on the command line before `--sec=` will get overwritten, where keys after it will override what is in the config.  `--sec=` can be used multiple times to load multiple sections if you really want.

## Contributing

Bug reports and pull requests are welcome on GitHub at [tadpol/ucr](https://github.com/tadpol/ucr). This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/tadpol/ucr/blob/master/CODE_OF_CONDUCT.md).

## License

The script is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Ucr project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/tadpol/ucr/blob/master/CODE_OF_CONDUCT.md).
