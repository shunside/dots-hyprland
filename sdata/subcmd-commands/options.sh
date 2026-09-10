# Handle args for subcmd: commands
# shellcheck shell=bash

showhelp(){
echo -e "Syntax: $0 commands

List every setup command, grouped by purpose. Read-only.
"
}

para=$(getopt \
  -o h \
  -l help \
  -n "$0" -- "$@")
[ $? != 0 ] && echo "$0: Error when getopt, please recheck parameters." && exit 1

eval set -- "$para"
while true ; do
  case "$1" in
    -h|--help) showhelp;exit;;
    --) shift;break ;;
    *) echo -e "$0: Wrong parameters.";exit 1;;
  esac
done
