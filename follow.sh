#!/bin/sh
# Keeps this pane attached to the Herdr terminal named in the target file.
# The plugin writes a new terminal id and sends ctrl+b q; the attach ends and the loop picks up the new one.
#   follow.sh TARGET_FILE [HERDR_BIN]

file="$1"
herdr="${2:-herdr}"
on="$file.on" # the terminal this pane is attached to right now, empty while waiting

: > "$on"
waiting=""
failures=0
while :; do
	target=$(cat "$file" 2>/dev/null)
	if [ -z "$target" ] || [ "$target" = "$waiting" ]; then
		sleep 0.3
		continue
	fi
	waiting=""
	terminal="$target"
	case "$target" in
	term_*) ;;
	*) # A pane id (w1:p2): look up its terminal.
		terminal=$("$herdr" pane get "$target" 2>/dev/null | sed -n 's/.*"terminal_id":"\([^"]*\)".*/\1/p')
		;;
	esac
	printf '%s' "$target" > "$on"
	if [ -n "$terminal" ]; then
		"$herdr" terminal attach "$terminal"
		status=$?
	else
		status=1
	fi
	: > "$on"
	[ "$(cat "$file" 2>/dev/null)" = "$target" ] || { failures=0; continue; }
	if [ "$status" -ne 0 ] && [ "$failures" -lt 5 ]; then
		# A pane that isn't laid out yet has no size and Herdr refuses it; try again shortly.
		failures=$((failures + 1))
		sleep 1
		continue
	fi
	# Same target: the user detached, or attaching keeps failing. Wait for a new one.
	failures=0
	waiting="$target"
	printf '\033[2J\033[H'
	if [ "$status" -ne 0 ]; then
		printf 'herdr terminal attach %s failed (exit %s).\n' "$target" "$status"
	fi
	printf 'Detached. Pick a pane in the Herdr sidebar, or close this block.\n'
done
