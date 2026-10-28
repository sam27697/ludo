// docs/PROTOCOL.md section 25. The quick messages: twelve preset ids sent
// as ids, never as text, and the per-seat cadence that keeps them a rule of
// the table rather than a way to flood it.
//
// The server knows only the ids. The words in each language belong to the
// client, so nothing here stores or forwards anything a player typed.

/// The twelve ids of section 25 rule 1, in the sheet's order. Ids are
/// permanent: one is never renamed or reused for a different line.
const Set<String> emoteIds = <String>{
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
};

/// Section 25 rule 3: the least time between two admitted emotes from one
/// seat.
const Duration emoteMinGap = Duration(milliseconds: 3000);

/// Section 25 rule 3: the window the per-seat count is taken over.
const Duration emoteWindow = Duration(milliseconds: 60000);

/// Section 25 rule 3: how many emotes one seat may have admitted inside
/// [emoteWindow].
const int emoteWindowLimit = 10;

/// Admits or refuses one emote against [admitted], the moments this seat's
/// earlier emotes were admitted, oldest first. Records [now] and returns
/// true only when at least [emoteMinGap] has passed since the last one and
/// fewer than [emoteWindowLimit] fall inside the [emoteWindow] before
/// [now]. A refused call leaves [admitted] as it was apart from dropping
/// entries too old to matter, so a rejected emote counts toward neither
/// bound and never pushes the next admit further out.
bool admitEmote(List<DateTime> admitted, DateTime now) {
  admitted.removeWhere((DateTime t) => now.difference(t) >= emoteWindow);
  if (admitted.isNotEmpty && now.difference(admitted.last) < emoteMinGap) {
    return false;
  }
  if (admitted.length >= emoteWindowLimit) {
    return false;
  }
  admitted.add(now);
  return true;
}
