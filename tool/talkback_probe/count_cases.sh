#!/usr/bin/env bash
# Order 623: counts how many times TalkBack spoke the text of each case that
# packages/ludo_client/probe/talkback_announce_main.dart played, and prints a
# table. The case list is read from the probe's own log lines, so the cases are
# defined in one place only:
#   <time> ... flutter : LUDO_PROBE_CASE_START|<letter>|<description>|<text>
# A case with two lines (order 627) carries both texts, separated by a bar:
#   <time> ... flutter : LUDO_PROBE_CASE_START|<letter>|<description>|<text 1>|<text 2>
# A spoken line is one TalkBack wrote through SpeechControllerImpl:
#   <time> ... talkback: SpeechControllerImpl: Speaking fragment text="<text>", utteranceId=..., event=...
# A text's count is the number of spoken lines that contain it, in the whole
# window. Each case also has a window of its own, from its start line to the
# next case's start line (the last one to LUDO_PROBE_DONE, or the end of the
# log), and every spoken line inside it is listed in order, whether or not it
# carries one of the case's texts. The counts are the measurement, not a gate: this script exits 0 for any
# count, including none. It exits 2 only when the log holds no case line at all,
# which means the probe never ran.
#
# Usage: count_cases.sh <logcat file from the probe launch on> <spoken lines file>
# Writes the table to stdout. Prints nothing secret; reads two files.

LOGCAT="${1:?usage: count_cases.sh <logcat file> <spoken lines file>}"
SPOKEN="${2:?usage: count_cases.sh <logcat file> <spoken lines file>}"

[ -f "$LOGCAT" ] || { echo "count_cases: not a file: $LOGCAT" >&2; exit 1; }
[ -f "$SPOKEN" ] || { echo "count_cases: not a file: $SPOKEN" >&2; exit 1; }

CASES="$(grep -F 'LUDO_PROBE_CASE_START|' "$LOGCAT" | sed 's/.*LUDO_PROBE_CASE_START|//' | tr -d '\r')"
if [ -z "$CASES" ]; then
  echo "count_cases: no LUDO_PROBE_CASE_START line in $LOGCAT, so the probe never ran" >&2
  exit 2
fi

if grep -qF 'LUDO_PROBE_DONE' "$LOGCAT"; then
  echo "probe script: finished (LUDO_PROBE_DONE seen)"
else
  echo "probe script: DID NOT FINISH (no LUDO_PROBE_DONE line), later cases may be missing"
fi
echo "spoken lines in the window: $(wc -l < "$SPOKEN")"
echo
# Fields are separated, not padded: printf pads by bytes, which would misalign
# the Arabic text.
echo "case | text | times spoken | what the case does"
echo "---- | ---- | ------------ | ------------------"

# Every expected text of every case, one per line: the pattern list for the
# lines that carry no case text. Fields are split on the bar; the first two are
# the letter and the description, the rest are the texts.
TEXTS_TMP="$(mktemp)"
trap 'rm -f "$TEXTS_TMP"' EXIT
printf '%s\n' "$CASES" | awk -F'|' '{ for (i = 3; i <= NF; i++) if ($i != "") print $i }' > "$TEXTS_TMP"

DETAIL=""
while IFS='|' read -r -a FIELDS; do
  letter="${FIELDS[0]}"
  description="${FIELDS[1]}"
  [ -n "$letter" ] || continue
  for text in "${FIELDS[@]:2}"; do
    [ -n "$text" ] || continue
    count="$(grep -cF -- "$text" "$SPOKEN")"
    echo "$letter | $text | $count | $description"
    DETAIL="${DETAIL}
case $letter, text \"$text\", spoken $count time(s):
"
    if [ "$count" -gt 0 ]; then
      # Time of day, then everything from "Speaking fragment" on: the text, the
      # utterance id and the accessibility event that caused it.
      DETAIL="${DETAIL}$(grep -F -- "$text" "$SPOKEN" | sed 's/^[0-9-]* \([0-9:.]*\) .*\(Speaking fragment\)/  \1 \2/')
"
    else
      DETAIL="${DETAIL}  (none)
"
    fi
  done
done <<< "$CASES"

echo
echo "raw spoken lines per text, in order:"
printf '%s\n' "$DETAIL"

# Case windows. A case runs from its own start line to the next case's start
# line; the last one runs to LUDO_PROBE_DONE, or to the end of the log when the
# script did not finish. The key is "MM-DD HH:MM:SS.mmm", which sorts as text.
STARTS_TMP="$(mktemp)"
trap 'rm -f "$TEXTS_TMP" "$STARTS_TMP"' EXIT
tr -d '\r' < "$LOGCAT" | awk '/LUDO_PROBE_CASE_START\|/ { print $1 " " $2 }' > "$STARTS_TMP"
END_KEY="$(tr -d '\r' < "$LOGCAT" | awk '/LUDO_PROBE_DONE/ { print $1 " " $2; exit }')"
[ -n "$END_KEY" ] || END_KEY="99-99 99:99:99.999"

echo "everything TalkBack sent to speech in each case's window, in order:"
INDEX=0
while IFS='|' read -r -a FIELDS; do
  letter="${FIELDS[0]}"
  [ -n "$letter" ] || continue
  INDEX=$((INDEX + 1))
  start_key="$(sed -n "${INDEX}p" "$STARTS_TMP")"
  next_key="$(sed -n "$((INDEX + 1))p" "$STARTS_TMP")"
  [ -n "$next_key" ] || next_key="$END_KEY"
  texts="$(printf '%s|' "${FIELDS[@]:2}")"
  echo
  echo "case $letter, window $start_key to $next_key, expecting: ${texts%|}"
  WINDOW="$(awk -v start="$start_key" -v stop="$next_key" -v texts="${texts%|}" '
    BEGIN { n = split(texts, want, "|") }
    {
      key = $1 " " $2
      if (key < start || key >= stop) next
      line = $0
      rest = line
      sub(/.*Speaking fragment text=/, "", rest)
      said = rest
      sub(/, utteranceId=.*/, "", said)
      sub(/^.*, utteranceId=/, "utteranceId=", rest)
      tag = ""
      for (i = 1; i <= n; i++) if (index(said, want[i]) > 0) tag = tag " [text " i "]"
      if (tag == "") tag = " [not a case text]"
      printf "  %s %s%s %s\n", $2, said, tag, rest
    }' "$SPOKEN")"
  if [ -n "$WINDOW" ]; then
    printf '%s\n' "$WINDOW"
  else
    echo "  (nothing spoken in this window)"
  fi
done <<< "$CASES"
echo

OTHER="$(grep -cvFf "$TEXTS_TMP" "$SPOKEN")"
echo "spoken lines that carry no case text: $OTHER"
if [ "$OTHER" -gt 0 ]; then
  grep -vFf "$TEXTS_TMP" "$SPOKEN" | sed 's/^[0-9-]* \([0-9:.]*\) .*\(Speaking fragment\)/  \1 \2/'
fi
exit 0
