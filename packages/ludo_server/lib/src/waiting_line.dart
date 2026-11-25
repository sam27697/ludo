// docs/PROTOCOL.md section 33 items 3 and 4: the one waiting line of the
// server. Tickets, their order, detaching a ticket whose socket closed, its
// re-attach and its expiry. Nothing here knows a room or a socket: a ticket's
// owner is whatever the wire layer attached, and the registry decides where a
// ticket is seated.

import 'dart:convert' show base64Url;
import 'dart:math';

import 'clock.dart';

/// Section 33 item 4: a detached ticket is held this long on the server
/// clock, then dropped.
const Duration ticketDetachedLifetime = Duration(milliseconds: 30000);

/// Bytes of CSPRNG output behind a ticket id: 16 bytes are 22 characters of
/// unpadded base64url.
const int _ticketBytes = 16;

/// One place in the line. [install] and [ip] are held only while the ticket
/// is, to bar and seat it; they are never logged and never sent.
class Ticket {
  Ticket._({
    required this.id,
    required this.name,
    required this.install,
    required this.ip,
    required this.owner,
  });

  /// 22 characters of base64url, section 33 item 3.
  final String id;

  /// The trimmed display name the seat will carry.
  String name;

  /// The `install` the ticket was made with; a re-attach must match it.
  final String install;

  /// The IP of the socket the ticket is attached to, or was last attached to.
  String ip;

  /// Whatever the wire layer attached to identify the socket. Null while the
  /// ticket is detached.
  Object? owner;

  /// When the socket closed, on the server clock. Null while attached.
  DateTime? detachedAt;

  /// The `position` this ticket's socket was last told, null before the
  /// first `queued`. A fresh `queued` is owed whenever the position differs.
  int? toldPosition;

  bool get attached => owner != null;
}

/// First come, first served. A detached ticket keeps its place; it is never
/// seated and never counted, and those behind it are served past it.
class WaitingLine {
  WaitingLine({required Clock clock, required Random random})
      : _clock = clock,
        _random = random;

  final Clock _clock;
  final Random _random;
  final List<Ticket> _tickets = <Ticket>[];

  /// The line in order, head first.
  List<Ticket> get tickets => List<Ticket>.unmodifiable(_tickets);

  bool get isEmpty => _tickets.isEmpty;

  /// The tickets whose socket is attached, in line order.
  List<Ticket> get attachedTickets => <Ticket>[
        for (final Ticket t in _tickets)
          if (t.attached) t
      ];

  /// A new ticket at the tail for [owner].
  Ticket enqueue({
    required String name,
    required String install,
    required String ip,
    required Object owner,
  }) {
    final Ticket ticket = Ticket._(
      id: _drawId(),
      name: name,
      install: install,
      ip: ip,
      owner: owner,
    );
    _tickets.add(ticket);
    return ticket;
  }

  /// The ticket [owner] holds, or null.
  Ticket? ticketOf(Object owner) {
    for (final Ticket t in _tickets) {
      if (identical(t.owner, owner)) {
        return t;
      }
    }
    return null;
  }

  /// Section 33 item 4, "A dropped socket": gives ticket [id] to [owner] in
  /// its old place when it is still held, not past its 30 000 ms detached,
  /// and was made with the same [install]. Null otherwise, and then nothing
  /// is changed. A ticket still attached to another socket moves to [owner];
  /// that socket no longer holds it.
  Ticket? reattach({
    required String id,
    required String install,
    required String name,
    required String ip,
    required Object owner,
  }) {
    for (final Ticket t in _tickets) {
      if (t.id != id) {
        continue;
      }
      if (t.install != install || _expired(t, _clock.now)) {
        return null;
      }
      t.owner = owner;
      t.detachedAt = null;
      t.name = name;
      t.ip = ip;
      return t;
    }
    return null;
  }

  /// Takes [ticket] out of the line. False when it was not in it.
  bool remove(Ticket ticket) => _tickets.remove(ticket);

  /// Marks the ticket [owner] holds as detached from now on. Returns it, or
  /// null when [owner] held none.
  Ticket? detach(Object owner) {
    final Ticket? ticket = ticketOf(owner);
    if (ticket == null) {
      return null;
    }
    ticket.owner = null;
    ticket.detachedAt = _clock.now;
    return ticket;
  }

  /// Drops every ticket detached for [ticketDetachedLifetime] or more and
  /// returns how many went.
  int expire() {
    final DateTime now = _clock.now;
    final int before = _tickets.length;
    _tickets.removeWhere((Ticket t) => _expired(t, now));
    return before - _tickets.length;
  }

  /// 1 for the head of the line. Detached tickets keep their place and are
  /// counted. 0 when [ticket] is not in the line.
  int positionOf(Ticket ticket) => _tickets.indexOf(ticket) + 1;

  /// Every attached ticket whose position is not the one its socket was last
  /// told, each now marked as told. Line order.
  List<Ticket> takePositionChanges() {
    final List<Ticket> changed = <Ticket>[];
    for (int i = 0; i < _tickets.length; i++) {
      final Ticket t = _tickets[i];
      if (!t.attached || t.toldPosition == i + 1) {
        continue;
      }
      t.toldPosition = i + 1;
      changed.add(t);
    }
    return changed;
  }

  bool _expired(Ticket t, DateTime now) {
    final DateTime? since = t.detachedAt;
    return since != null && now.difference(since) >= ticketDetachedLifetime;
  }

  String _drawId() {
    while (true) {
      final List<int> bytes =
          List<int>.generate(_ticketBytes, (int _) => _random.nextInt(256));
      final String encoded = base64Url.encode(bytes).replaceAll('=', '');
      if (!_tickets.any((Ticket t) => t.id == encoded)) {
        return encoded;
      }
    }
  }
}
