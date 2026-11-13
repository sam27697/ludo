// The one place a server address is written down. Every screen that needs to
// open a socket goes through defaultRoomControllerFactory rather than
// building its own Uri, so moving the fleet is a one-line change here and
// nowhere else in lib/.

import 'net/room_controller.dart';
import 'net/ws_transport.dart';

/// The deployed game server. Production, which is live and current.
const String kDefaultServerUrl = 'wss://ludo.provefair.app';

int? _clientBuild;

/// The build number [defaultRoomControllerFactory] puts on every upgrade.
/// `main()` sets it once from `readAppBuild()` before `runApp`; it stays null
/// everywhere else (a widget test never calls `main()`), and null sends no
/// header. A value below 1 is stored as null for the same reason.
set clientBuild(int? value) {
  _clientBuild = (value != null && value >= 1) ? value : null;
}

/// The value last given to the [clientBuild] setter, or null.
int? get clientBuild => _clientBuild;

/// Builds the controller the app uses for real. Injected as a default so
/// a widget test can substitute a controller over a fake transport
/// without a socket.
typedef RoomControllerFactory = RoomController Function();

/// Opens against [kDefaultServerUrl] over a real [WsTransport]. This is the
/// only call site in lib/ that names both of those things together; every
/// screen that needs a controller for real takes this function, not the two
/// pieces it is built from, so there is exactly one place that wires a real
/// socket to a real address.
RoomController defaultRoomControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse(kDefaultServerUrl),
    connect: (Uri url) => connectWsTransport(url, clientBuild: _clientBuild),
    autoReconnectDelays: kAutoReconnectDelays,
  );
}
