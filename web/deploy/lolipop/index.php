<?php
// Archeion front controller (Lolipop node-as-CGI). Every dynamic request lands here (.htaccess
// routes non-static URLs to this file). We invoke the vendored node 22 binary on the bundled
// app, passing the request via ARCHEION_* env + the POST body via stdin, and relay node's
// response. Static assets (style.css, figures) are served by Apache before reaching here.

$dir  = __DIR__;
$node = $dir . '/bin/node';
$cgi  = $dir . '/dist/cgi.js';
$db   = $dir . '/data/archeion.db';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path   = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$query  = $_SERVER['QUERY_STRING'] ?? '';
$bodyIn = ($method === 'POST') ? file_get_contents('php://input') : '';

$env = [
    'ARCHEION_METHOD' => $method,
    'ARCHEION_PATH'   => $path,
    'ARCHEION_QUERY'  => $query,
    'ARCHEION_ORIGIN' => $_SERVER['HTTP_ORIGIN'] ?? '',
    'ARCHEION_HOST'   => $_SERVER['HTTP_HOST'] ?? '',
    'ARCHEION_XRW'    => $_SERVER['HTTP_X_REQUESTED_WITH'] ?? '',
    'ARCHEION_COOKIE' => $_SERVER['HTTP_COOKIE'] ?? '',  // app login session (layer 2, above Basic auth)
    'ARCHEION_DB'     => $db,
    // node 22 caches compiled bytecode of the 264KB bundle here → faster cold start per request.
    // Under data/ so it's writable and the .htaccess RedirectMatch keeps it off the web.
    'NODE_COMPILE_CACHE' => $dir . '/data/.node-compile-cache',
    'OPENSSL_CONF'    => '/dev/null', // avoid /etc/ssl/openssl.cnf permission error
    'PATH'            => '/usr/local/bin:/usr/bin:/bin',
];

$cmd  = [$node, '--no-warnings', '--experimental-sqlite', $cgi];
$desc = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
$proc = proc_open($cmd, $desc, $pipes, $dir, $env);
if (!is_resource($proc)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'node spawn failed';
    exit;
}
fwrite($pipes[0], $bodyIn);
fclose($pipes[0]);
$out = stream_get_contents($pipes[1]);
fclose($pipes[1]);
$err = stream_get_contents($pipes[2]);
fclose($pipes[2]);
$code = proc_close($proc);

$nl = strpos($out, "\n");
if ($nl === false) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "node produced no response (exit $code)\n" . $err;
    exit;
}
$meta = json_decode(substr($out, 0, $nl), true) ?: ['status' => 500, 'type' => 'text/plain'];
$body = substr($out, $nl + 1);

http_response_code($meta['status'] ?? 200);
header('Content-Type: ' . ($meta['type'] ?? 'text/html; charset=utf-8'));
if (!empty($meta['headers'])) {
    foreach ($meta['headers'] as $k => $v) {
        header("$k: $v");
    }
}
// Security headers (the daemon sets these in server.js; set them here for the CGI path too).
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: SAMEORIGIN'); // composer refs pane iframes Archeion (same-origin)
header('Referrer-Policy: same-origin');
// Dynamic pages must never be cached: after a write the POST 303-redirects to the record GET,
// and a cached/bfcache copy would show the pre-write page ("tag added but not reflected").
header('Cache-Control: no-store, max-age=0');
header("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; form-action 'self'; base-uri 'none'");
echo $body;
