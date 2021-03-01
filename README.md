# Ucr

Ucr is a tool for merging RESTful APIs with the command line.  It does this as thinly as it possibly can.  Which means it is more of a scripting pattern than anything else.

The main need for this is to handle large amount of boilerplate and repeating parts of calling the API, reducing it down to a short commandline invocation with just the variable parts specified.  The other main use is for the APIs where there are multiple calls required in order to get the desired result.

It is written in ZSH, as a few functions that handle a majority of parsing options, arguments, environments, and mapping to function calls.  Prior versions of UCR were written in Swift, Go, and Ruby.  However in the drive to reduce it to really just what was needed, it eventually was stripped down to its current form.  The core is pure ZSH; the primary work is done with [curl][] and [jq][].

Ucr was an acronym for something, but I've long forgotten what it was.  I call it `ulcer`, which is referencing the pain induced by prior tools trying to achieve similar goals.

## Installation

Copy `ucr.zsh` into your PATH somewhere, renaming it to `ucr`.  Also set it as executable if it is not already.

The core only needs [ZSH][] and no other dependencies.

The included tasks make heavy use of [curl][] and [jq][].  There is light useage of [fzf][].

The password lookup function will try to use `security` if there is not a password in the `.netrc` file. (`security` is a MacOS only tool.)

You can also link or rename the script and it will only find the tasks with that name as the prefix.  With the current release, you can use the name `jmq` and have some jira related tasks.

## Usage

`ucr <options>|<args>|<keys>`

options: short or long

Short options can be either `-a -b -c` or `-abc`, and repeated `-vvvv`.

Long options can be boolean true `--term` or false `--no-term`.  Long options can be given any value `--term=value`.  If a long option is repeated, the last one is the value used.

Keys are an argument with a `=`, such as `sid=qwerty`.  These are converted into environment variables.  The key name is converted to uppercase and prefixed with the script name. (So `sid=qwerty` gets exported as `UCR_SID=qwerty`)

After all options and keys have been removed from the argument list, the remaining args are used to search for a function.  This is done by prefixing the script name and adding `_` between args.  If a function is not found, the last argument is drop and searched again. If nothing is found after trying all subpatterns, then the function `ucr_function_not_found` is called.

## Development

## Contributing

Bug reports and pull requests are welcome on GitHub at [tadpol/ucr](https://github.com/tadpol/ucr). This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/tadpol/ucr/blob/master/CODE_OF_CONDUCT.md).

## License

The script is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Ucr project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/tadpol/ucr/blob/master/CODE_OF_CONDUCT.md).

[curl]: https://curl.se
[jq]: https://stedolan.github.io/jq/
[fzf]: https://github.com/junegunn/fzf#table-of-contents
