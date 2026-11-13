#!/bin/zsh
set -eu

label=app.rammeter.mac.login
directory="$HOME/Library/LaunchAgents"
plist="$directory/$label.plist"
domain="gui/$(/usr/bin/id -u)"
service="$domain/$label"

usage() {
  print -u2 'Usage: zsh login-launch.sh enable /absolute/path/to/Ram\ Meter.app'
  print -u2 '       zsh login-launch.sh disable | status'
  exit 64
}

case ${1:-} in
  enable)
    [[ $# == 2 && "$2" == /*.app && -d "$2" ]] || usage
    app=${2:A}
    info="$app/Contents/Info.plist"
    [[ -f "$info" && -x "$app/Contents/MacOS/WorkloadMeter" ]] || usage
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
    [[ "$identifier" == app.rammeter.mac || "$identifier" == local.griffin.workload-meter ]] || usage
    /bin/launchctl print "$domain" >/dev/null
    /bin/mkdir -p "$directory"
    temporary=$(/usr/bin/mktemp "$directory/.$label.XXXXXXXX")
    trap '/bin/rm -f -- "$temporary"' EXIT
    /usr/bin/plutil -create xml1 "$temporary"
    /usr/bin/plutil -insert Label -string "$label" "$temporary"
    /usr/bin/plutil -insert ProgramArguments -json '["/usr/bin/open","-a"]' "$temporary"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$app" "$temporary"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$temporary"
    /usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$temporary"
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
      /bin/launchctl bootout "$service"
    fi
    /bin/mv -f -- "$temporary" "$plist"
    /bin/launchctl enable "$service"
    /bin/launchctl bootstrap "$domain" "$plist"
    print 'Ram Meter is set to open at login.'
    ;;
  disable)
    [[ $# == 1 ]] || usage
    /bin/launchctl print "$domain" >/dev/null
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
      /bin/launchctl bootout "$service"
    fi
    /bin/rm -f -- "$plist"
    print 'Ram Meter login launch is off.'
    ;;
  status)
    [[ $# == 1 ]] || usage
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
      print 'Ram Meter login launch is registered.'
    elif [[ -f "$plist" ]]; then
      print -u2 'Ram Meter login configuration exists but is not loaded.'
      exit 1
    else
      print 'Ram Meter login launch is off.'
    fi
    ;;
  *) usage ;;
esac
