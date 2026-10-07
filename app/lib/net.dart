// Reaching the computer's tunnel right after it restarts. Each restart gives the tunnel a brand-new
// *.trycloudflare.com name, and phones briefly cache "no such host" for names they looked up too early — for
// minutes. When the normal lookup fails for a tunnel name, this asks Cloudflare's DNS over HTTPS (1.1.1.1)
// instead and connects to that address; TLS still checks the certificate for the real name, so nothing about
// the connection's security changes. Every other host connects exactly as usual.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TunnelDns extends HttpOverrides {
  static void install() => HttpOverrides.global = TunnelDns();

  static final Map<String, (InternetAddress, DateTime)> _cache = {};

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final secure = uri.scheme == 'https';
      final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
      // Through a proxy, or not a tunnel name: the usual connection.
      if (proxyHost != null || !uri.host.endsWith('.trycloudflare.com')) {
        return secure ? SecureSocket.startConnect(proxyHost ?? uri.host, proxyPort ?? port, context: context) : Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? port);
      }
      final address = await _resolve(uri.host);
      if (address == null) {
        return secure ? SecureSocket.startConnect(uri.host, port, context: context) : Socket.startConnect(uri.host, port);
      }
      final socket = Socket.connect(address, port, timeout: const Duration(seconds: 10))
          .then<Socket>((raw) => secure ? SecureSocket.secure(raw, host: uri.host, context: context) : raw);
      return ConnectionTask.fromSocket(socket, () {});
    };
    return client;
  }

  /// The system's answer if it has one, else Cloudflare's over HTTPS (cached for 10 minutes).
  static Future<InternetAddress?> _resolve(String host) async {
    final hit = _cache[host];
    if (hit != null && DateTime.now().difference(hit.$2).inMinutes < 10) return hit.$1;
    try {
      final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
      if (found.isNotEmpty) return found.first;
    } catch (_) {}
    try {
      // A plain client (1.1.1.1 is an IP, so this factory isn't involved).
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.getUrl(Uri.parse('https://1.1.1.1/dns-query?name=$host&type=A'));
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      c.close();
      for (final a in List<Map<String, dynamic>>.from(body['Answer'] ?? const [])) {
        if (a['type'] == 1) {
          final ip = InternetAddress(a['data'] as String);
          _cache[host] = (ip, DateTime.now());
          return ip;
        }
      }
    } catch (_) {}
    return null;
  }
}
