unit module App::Rakus;

#| A static HTTP/1.1 file server on nothing but `IO::Socket::INET`.
#|
#| The routing is a pure function of (method, target, root) — `handle` returns
#| the whole response and touches no socket — so the behaviour that matters can
#| be tested without a network at all. `run` is the socket loop around it.

constant %REASON =
    200 => 'OK',           301 => 'Moved Permanently', 400 => 'Bad Request',
    403 => 'Forbidden',    404 => 'Not Found',         405 => 'Method Not Allowed';

constant HTML = 'text/html; charset=utf-8';

constant %MIME =
    html => HTML,                             htm  => HTML,
    css  => 'text/css; charset=utf-8',        js   => 'application/javascript; charset=utf-8',
    mjs  => 'application/javascript; charset=utf-8',
    json => 'application/json; charset=utf-8', xml => 'application/xml; charset=utf-8',
    txt  => 'text/plain; charset=utf-8',      md   => 'text/markdown; charset=utf-8',
    csv  => 'text/csv; charset=utf-8',
    svg  => 'image/svg+xml',                  png  => 'image/png',
    jpg  => 'image/jpeg',                     jpeg => 'image/jpeg',
    gif  => 'image/gif',                      webp => 'image/webp',
    ico  => 'image/x-icon',                   pdf  => 'application/pdf',
    wasm => 'application/wasm',               zip  => 'application/zip',
    woff2 => 'font/woff2';

#| The Content-Type for a path, by extension. Anything unrecognised is served as
#| `application/octet-stream` rather than guessed at.
sub mime-for(Str $path --> Str) is export {
    my $ext = ($path ~~ / '.' (\w+) $/) ?? (~$0).lc !! '';
    %MIME{$ext} // 'application/octet-stream';
}

sub esc(Str $s --> Str) {
    $s.subst('&', '&amp;', :g).subst('<', '&lt;', :g)
      .subst('>', '&gt;', :g).subst('"', '&quot;', :g)
}

sub url-decode(Str $s is copy --> Str) {
    $s ~~ s:g/ '%' (<[0..9A..Fa..f]> ** 2) /{ chr(:16(~$0)) }/;
    $s
}

sub human-size(Int $n --> Str) {
    return "$n B" if $n < 1024;
    return sprintf('%.1f KB', $n / 1024) if $n < 1024 * 1024;
    sprintf('%.1f MB', $n / (1024 * 1024))
}

# The CSS lives in a non-interpolating heredoc so its braces stay literal, and
# the pages are assembled by concatenation, which sidesteps qq's interpolation.
my $CSS = Q:to/CSS/;
    <style>
      body { font: 15px/1.5 system-ui, sans-serif; max-width: 48rem; margin: 2.5rem auto; padding: 0 1rem; color: #222; }
      h1 { font-size: 1.2rem; } a { color: #2563eb; text-decoration: none; } a:hover { text-decoration: underline; }
      ul { list-style: none; padding: 0; } li { padding: 0.15rem 0; }
      .sz { color: #999; font-size: 0.85em; margin-left: 0.5rem; }
      .muted { color: #888; font-size: 0.85rem; margin-top: 2rem; }
      code { background: #f2f2f4; padding: 0.1em 0.3em; border-radius: 4px; }
    </style>
    CSS

sub page(Str $title, Str $inner --> Str) {
    '<!doctype html><html><head><meta charset="utf-8">'
    ~ '<meta name="viewport" content="width=device-width, initial-scale=1">'
    ~ '<title>' ~ esc($title) ~ '</title>' ~ $CSS ~ "</head><body>\n"
    ~ $inner
    ~ "\n<p class=\"muted\">served by rakus</p>\n"
    ~ '</body></html>'
}

sub dir-listing(IO::Path $dir, Str $urlpath --> Str) {
    my @entries = dir($dir).map(*.IO).sort({ (!.d, .basename.lc) });
    my $rows = '';
    $rows ~= '<li><a href="../">📁 ../</a></li>' ~ "\n" unless $urlpath eq '/';
    for @entries -> $e {
        my $name = $e.basename;
        next if $name.starts-with('.');                 # dotfiles stay hidden
        my $disp = $name ~ ($e.d ?? '/' !! '');
        my $icon = $e.d ?? '📁' !! '📄';
        my $size = $e.d ?? '' !! ' <span class="sz">' ~ human-size($e.s) ~ '</span>';
        $rows ~= '<li><a href="' ~ esc($disp) ~ '">' ~ $icon ~ ' ' ~ esc($disp) ~ '</a>'
               ~ $size ~ '</li>' ~ "\n";
    }
    page('Index of ' ~ $urlpath,
         '<h1>Index of ' ~ esc($urlpath) ~ '</h1><ul>' ~ "\n" ~ $rows ~ '</ul>')
}

sub error-page(Int $status, Str $path --> Str) {
    page($status ~ ' ' ~ %REASON{$status},
         '<h1>' ~ $status ~ ' — ' ~ %REASON{$status} ~ '</h1>'
         ~ '<p><code>' ~ esc($path) ~ '</code></p><p><a href="/">home</a></p>')
}

#| The whole response for one request, as (status, content-type, body, extra
#| header or Nil). A HEAD gets the same answer as a GET, body included — the
#| caller drops the bytes but keeps the Content-Length, which is what HEAD means.
sub handle(Str $method, Str $target, Str $root --> List) is export {
    return 405, HTML, error-page(405, $method).encode, Nil
        unless $method eq 'GET' || $method eq 'HEAD';

    my $path = url-decode($target.split('?', 2)[0]);

    return 400, HTML, error-page(400, $path).encode, Nil
        unless $path.starts-with('/');
    # `..` is refused rather than resolved: a served root is a boundary, and the
    # cheapest way to keep it one is never to leave it.
    return 403, HTML, error-page(403, $path).encode, Nil
        if $path.split('/').any eq '..';

    my $fs = ($root ~ $path).IO;

    if $fs.d {
        # A directory URL has to end in '/' or every relative link inside it
        # resolves one level too high.
        return 301, HTML, ''.encode, ('Location' => "$path/")
            unless $path.ends-with('/');
        my $index = $fs.add('index.html');
        return 200, mime-for('index.html'), $index.slurp(:bin), Nil if $index.f;
        return 200, HTML, dir-listing($fs, $path).encode, Nil;
    }
    return 200, mime-for($fs.Str), $fs.slurp(:bin), Nil if $fs.f;
    404, HTML, error-page(404, $path).encode, Nil
}

#| The response head for one answer. Content-Length is the body's true byte
#| count even for a HEAD, whose body is not sent.
sub head-for(Int $status, Str $ctype, Int $bytes, $extra --> Str) is export {
    "HTTP/1.1 $status {%REASON{$status} // 'OK'}\r\n"
    ~ "Content-Type: $ctype\r\n"
    ~ "Content-Length: $bytes\r\n"
    ~ ($extra ?? "{$extra.key}: {$extra.value}\r\n" !! '')
    ~ "Server: rakus\r\nConnection: close\r\n\r\n"
}

#| Read until the header terminator. GET and HEAD carry no body, so that is the
#| whole request; the cap is there so a client cannot make us buffer for ever.
sub read-request($conn --> Str) {
    my $data = '';
    while !$data.contains("\r\n\r\n") {
        my $chunk = $conn.recv;
        last unless $chunk.defined && $chunk ne '';
        $data ~= $chunk;
        last if $data.chars > 65536;
    }
    $data
}

#| Answer one connection and close it.
sub serve-one($conn, Str $root, Bool :$log = True) is export {
    my $raw = read-request($conn);
    if $raw {
        my ($method, $target) = ($raw.lines.head // '').split(' ');
        $method //= 'GET';
        $target //= '/';
        my ($status, $ctype, $body, $extra) = handle($method, $target, $root);
        try {
            $conn.print(head-for($status, $ctype, $body.bytes, $extra));
            $conn.write($body) unless $method eq 'HEAD' || $body.bytes == 0;
        }
        note sprintf('  %s %-4s %s', $status, $method, $target) if $log;
    }
    try $conn.close;
}

#| Bind a listening socket. Separate from the loop so a caller can choose the
#| port, learn it, and decide when to stop listening.
sub listen-on(Int $port, Str $host = '0.0.0.0' --> IO::Socket::INET) is export {
    IO::Socket::INET.new(:localhost($host), :localport($port), :listen)
}

#| Accept for ever, one thread per connection. Returns only if the listener is
#| closed underneath it.
sub accept-loop(IO::Socket::INET $listener, Str $root, Bool :$log = True) is export {
    loop {
        my $conn = try $listener.accept;
        last without $conn;
        start serve-one($conn, $root, :$log);
    }
}

#| The whole server: bind, announce, serve.
sub run(Int :$port = 8080, Str :$root = '.', Str :$host = '0.0.0.0',
        Bool :$log = True --> Int) is export {
    unless $root.IO.d {
        note "rakus: no such directory: $root";
        return 1;
    }
    # Absolute and without a trailing slash, so that joining a URL path onto it
    # never produces a doubled separator.
    my $abs = $root.IO.absolute.subst(/ '/' $ /, '');
    my $listener = listen-on($port, $host);
    note "rakus serving $abs on http://127.0.0.1:$port/  (Ctrl-C to stop)" if $log;
    accept-loop($listener, $abs, :$log);
    0
}
