#!/usr/bin/env bash
# Order 623: counts how many times TalkBack spoke the text of each case that
# packages/ludo_client/probe/talkback_announce_main.dart played, and prints a
# table. The case list is read from the probe's own log lines, so the cases are
# defined in one place only:
#   <time> ... flutter : LUDO_PROBE_CASE_START|<letter>|<description>|<text>
# A spoken line is one TalkBack wrote through SpeechControllerImpl:
#   <time> ... talkback: SpeechControllerImpl: Speaking fragment text="<text>", utteranceId=..., event=...
# A case's count is the number of spoken lines whose text contains the case's
# text. The counts are the measurement, not a gate: this script exits 0 for any
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

DETAIL=""
MATCHED_TMP="$(mktemp)"
trap 'rm -f "$MATCHED_TMP"' EXIT
: > "$MATCHED_TMP"

while IFS='|' read -r letter description text; do
  [ -n "$letter" ] || continue
  count="$(grep -cF -- "$text" "$SPOKEN")"
  echo "$letter | $text | $count | $description"
  grep -F -- "$text" "$SPOKEN" >> "$MATCHED_TMP"
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
done <<< "$CASES"

echo
echo "raw spoken lines per case, in order:"
printf '%s\n' "$DETAIL"

OTHER="$(grep -cvFf <(printf '%s\n' "$CASES" | awk -F'|' '{ print $3 }') "$SPOKEN")"
echo "spoken lines that carry no case text: $OTHER"
if [ "$OTHER" -gt 0 ]; then
  grep -vFf <(printf '%s\n' "$CASES" | awk -F'|' '{ print $3 }') "$SPOKEN" | sed 's/^[0-9-]* \([0-9:.]*\) .*\(Speaking fragment\)/  \1 \2/'
fi
exit 0
