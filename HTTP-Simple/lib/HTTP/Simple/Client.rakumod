use URI;
use JSON::Fast;
use HTTP::Simple::X;
use HTTP::Simple::Response;

unit class HTTP::Simple::Client;

has Str  $.base-uri = '';
has      %.headers;                     #= sent on every request, unless overridden
has Real $.timeout = 30;                #= total, seconds
has Real $.connect-timeout = 10;
has Int  $.retries = 0;                 #= opt-in; idempotent methods only
has Bool $.cookies = True;
has Bool $.follow = True;
has Int  $.max-redirects = 10;
has Bool $.proxy = True;                #= honour HTTP_PROXY / HTTPS_PROXY / NO_PROXY
has Str  $.user-agent = 'HTTP::Simple/0.0.1 Raku';

has %!jar;                              #= host => { name => value }
has $!ssl;                              #= IO::Socket::Async::SSL, if installed

constant @B64 = |('A'..'Z'), |('a'..'z'), |('0'..'9'), '+', '/';
constant %DEFAULT-PORT = http => 80, https => 443;
constant @IDEMPOTENT = <GET HEAD PUT DELETE OPTIONS>;
constant CRLF  = (13, 10);
constant CRLF2 = (13, 10, 13, 10);
constant LF2   = (10, 10);

method get(|c)     { self.request('GET',     |c) }
method post(|c)    { self.request('POST',    |c) }
method put(|c)     { self.request('PUT',     |c) }
method patch(|c)   { self.request('PATCH',   |c) }
method delete(|c)  { self.request('DELETE',  |c) }
method head(|c)    { self.request('HEAD',    |c) }
method options(|c) { self.request('OPTIONS', |c) }

method get-json(|c) { self.get(|c).raise-for-status.json }

#| The cookies held for a host, as a plain hash. Empty when the jar is off.
method cookies-for(Str $host --> Hash) { (%!jar{$host} // {}).Hash }

# ---------------------------------------------------------------- the request

#| One logical request: retries, redirects and cookies included. Returns a
#| Response whatever the status; only a transport failure throws.
method request(Str $method is copy, Str $target, *%opt --> HTTP::Simple::Response) {
    $method .= uc;
    my $url     = self!absolute($target);
    my $timeout = %opt<timeout> // $!timeout;
    my $follow  = %opt<follow>  // $!follow;
    my $retries = %opt<retries> // $!retries;
    my @history;

    loop (my $hop = 0; $hop <= $!max-redirects; $hop++) {
        my $resp = self!with-retries($method, $url, %opt, $timeout, $retries);
        $resp = HTTP::Simple::Response.new(
            status  => $resp.status, reason => $resp.reason,
            headers => $resp.headers, body  => $resp.body,
            url     => $url,          history => @history.List,
        );

        my $location = $resp.header('location');
        unless $follow && $resp.is-redirect && $location {
            $resp.raise-for-status if %opt<fatal>;
            return $resp;
        }

        @history.push($resp);
        $url = self!redirect-target($url, $location);
        # 303 always, and 301/302 by long-standing practice, turn a body-carrying
        # method into a GET. 307 and 308 exist precisely so as not to.
        if $resp.status == 303
        || (($resp.status == 301 || $resp.status == 302) && $method ne 'GET' && $method ne 'HEAD') {
            $method = 'GET';
            %opt<json>:delete;
            %opt<form>:delete;
            %opt<body>:delete;
        }
    }
    X::HTTP::Simple::Transport.new(
        :$url, detail => "more than {$!max-redirects} redirects").throw;
}

#| Retry transport failures only, and only for methods that can be repeated
#| safely. A status is never retried — the server answered.
method !with-retries(Str $method, Str $url, %opt, Real $timeout, Int $retries) {
    my $allowed = $retries > 0 && @IDEMPOTENT.first($method).defined ?? $retries !! 0;
    my $wait = 0.5;
    loop (my $try = 0; ; $try++) {
        my $resp = try self!one-request($method, $url, %opt, $timeout);
        return $resp unless $!;
        my $err = $!;
        $err.rethrow if $try >= $allowed;
        sleep $wait;
        $wait *= 2;
    }
}

method !one-request(Str $method, Str $url, %opt, Real $timeout --> HTTP::Simple::Response) {
    my $u      = URI.new($url);
    my $scheme = $u.scheme.lc || 'http';
    my $host   = ~$u.host;
    X::HTTP::Simple::Transport.new(:$url, detail => 'no host in the URL').throw
        unless $host;
    my $default = %DEFAULT-PORT{$scheme} // 80;
    my $port    = $u._port.defined ?? $u._port.Int !! $default;

    my $path  = (~$u.path) || '/';
    my $query = ~$u.query;
    with %opt<query> {
        my $extra = $_.hash.kv.map(-> $k, $v { esc($k) ~ '=' ~ esc($v) }).sort.join('&');
        $query = $query ?? "$query&$extra" !! $extra;
    }
    my $origin-form = $query ?? "$path?$query" !! $path;

    my ($body, $ctype) = self!body-for(%opt);

    # A proxy takes the connection; for plain HTTP it also takes the absolute URL
    # in the request line.
    my ($conn-host, $conn-port) = $host, $port;
    my $request-target = $origin-form;
    with self!proxy-for($scheme, $host) -> $p {
        if $scheme eq 'https' {
            X::HTTP::Simple::Transport.new(:$url,
                detail => 'https through a proxy needs CONNECT, which 0.0.1 does not do').throw;
        }
        $conn-host = $p<host>;
        $conn-port = $p<port>;
        $request-target = "$scheme://" ~ ($port == $default ?? $host !! "$host:$port") ~ $origin-form;
    }

    my %h;
    %h{.key.lc} = .value.Str for %!headers.pairs;
    %h{.key.lc} = .value.Str for (%opt<headers> // {}).hash.pairs;
    %h<host>            = $port == $default ?? $host !! "$host:$port";
    %h<user-agent>    //= $!user-agent;
    %h<accept-encoding> = 'identity';   # 0.0.1 does not decompress — see the README
    %h<connection>      = 'close';
    %h<content-type>    = $ctype if $ctype && !(%h<content-type>:exists);
    with %opt<bearer> { %h<authorization> = "Bearer $_" }
    with %opt<auth>   { %h<authorization> = 'Basic ' ~ b64(.list.join(':').encode('utf8')) }
    if $!cookies && (%!jar{$host}:exists) {
        my %c = %!jar{$host};
        %h<cookie> = %c.keys.sort.map({ "$_=%c{$_}" }).join('; ') if %c;
    }

    my $body-bytes = $body ~~ Blob ?? $body !! $body.encode('utf8');
    %h<content-length> = $body-bytes.elems.Str
        if $body-bytes.elems || $method eq 'POST' | 'PUT' | 'PATCH';

    my $head = "$method $request-target HTTP/1.1\r\n"
             ~ %h.keys.sort.map({ "$_: %h{$_}\r\n" }).join
             ~ "\r\n";
    my $wire = Buf.new(|$head.encode('utf8').list, |$body-bytes.list);

    my $raw  = self!exchange($scheme, $conn-host, $conn-port, $wire, $timeout, $url);
    my $resp = self!parse($raw, $url, $method);
    self!remember-cookies($host, $resp) if $!cookies;
    $resp
}

# ------------------------------------------------------------------ transport

#| Send the request and read until the server closes. `Connection: close` makes
#| that exactly one response, which is why 0.0.1 does not reuse connections.
method !exchange(Str $scheme, Str $host, Int $port, Blob $wire, Real $timeout, Str $url --> Blob) {
    my $factory = $scheme eq 'https' ?? self!ssl-class !! IO::Socket::Async;

    my $connecting = $factory.connect($host, $port);
    await Promise.anyof($connecting, Promise.in($!connect-timeout));
    unless $connecting.status ~~ Kept {
        X::HTTP::Simple::Transport.new(:$url,
            detail => "could not connect to $host:$port within {$!connect-timeout} s").throw;
    }
    my $conn = $connecting.result;

    my $buf  = Buf.new;
    my $done = Promise.new;
    my $vow  = $done.vow;
    $conn.Supply(:bin).tap(
        -> $chunk { $buf.append($chunk) },
        done => { $vow.keep(True) if $done.status ~~ Planned },
        quit => { $vow.keep(True) if $done.status ~~ Planned },
    );
    await $conn.write($wire);
    await Promise.anyof($done, Promise.in($timeout));
    my $finished = $done.status ~~ Kept;
    $conn.close;
    unless $finished {
        X::HTTP::Simple::Transport.new(:$url, detail => "timed out after $timeout s").throw;
    }
    $buf
}

#| IO::Socket::Async::SSL is a separate distribution, so it is loaded on demand:
#| the module installs and serves plain HTTP without it.
method !ssl-class() {
    return $!ssl if $!ssl.^name ne 'Any';
    my $c = try { require ::('IO::Socket::Async::SSL'); ::('IO::Socket::Async::SSL') };
    if $c.^name eq 'Any' || $c ~~ Failure {
        X::HTTP::Simple::Transport.new(url => '',
            detail => 'https needs IO::Socket::Async::SSL, which is not installed').throw;
    }
    $!ssl = $c;
    $c
}

# --------------------------------------------------------------------- parsing

method !parse(Blob $raw, Str $url, Str $method --> HTTP::Simple::Response) {
    # Byte offsets throughout: in a Raku string "\r\n" is a single grapheme, so
    # character positions would not line up with the wire at all.
    my $sep = blob-index($raw, CRLF2);
    my $gap = 4;
    without $sep {
        $sep = blob-index($raw, LF2);
        $gap = 2;
    }
    X::HTTP::Simple::Transport.new(:$url,
        detail => $raw.elems ?? 'response headers never ended' !! 'empty response').throw
        without $sep;

    my @lines       = $raw.subbuf(0, $sep).decode('latin-1').lines;
    my $status-line = @lines.shift // '';
    my @sl          = $status-line.split(' ');
    my $status      = (@sl[1] // '0').Int;
    my $reason      = @sl.elems > 2 ?? @sl[2 .. *].join(' ') !! '';

    my %headers;
    for @lines -> $line {
        my $c = $line.index(':');
        next without $c;
        my $k = $line.substr(0, $c).trim.lc;
        my $v = $line.substr($c + 1).trim;
        if %headers{$k}:exists {
            my @all = %headers{$k} ~~ Positional ?? |%headers{$k} !! %headers{$k};
            @all.push($v);
            %headers{$k} = @all.List;
        }
        else {
            %headers{$k} = $v;
        }
    }

    my $body = $method eq 'HEAD'
        ?? Blob.new
        !! Blob.new($raw.subbuf($sep + $gap));
    if (%headers<transfer-encoding> // '').Str.lc.contains('chunked') {
        $body = self!dechunk($body);
    }

    HTTP::Simple::Response.new(:$status, :$reason, :%headers, :$body, :$url);
}

#| Undo `Transfer-Encoding: chunked`. Byte offsets again, for the same reason.
method !dechunk(Blob $in --> Blob) {
    my $out = Buf.new;
    my $pos = 0;
    loop {
        my $nl = blob-index($in, CRLF, $pos);
        last without $nl;
        my $size-line = $in.subbuf($pos, $nl - $pos).decode('latin-1').split(';')[0].trim;
        last unless $size-line;
        my $size = try { :16($size-line) };
        last without $size;
        last if $size == 0;
        my $start = $nl + 2;
        $out.append($in.subbuf($start, $size));
        $pos = $start + $size + 2;      # step over the chunk's trailing CRLF
    }
    $out
}

# ---------------------------------------------------------------------- bits

#| Resolve a possibly-relative target against `base-uri`.
method !absolute(Str $target --> Str) {
    return $target if $target ~~ / ^ \w+ '://' /;
    return $target unless $!base-uri;
    my $base = $!base-uri.subst(/ '/' + $ /, '');
    $target.starts-with('/') ?? $base ~ $target !! "$base/$target"
}

method !redirect-target(Str $from, Str $location --> Str) {
    return $location if $location ~~ / ^ \w+ '://' /;
    my $u    = URI.new($from);
    my $root = $u.scheme ~ '://' ~ $u.host;
    $root ~= ':' ~ $u._port if $u._port.defined;
    return $root ~ $location if $location.starts-with('/');
    my $dir = (~$u.path) || '/';
    $dir .= subst(/ <-[/]>* $ /, '');
    $root ~ $dir ~ $location
}

method !body-for(%opt --> List) {
    with %opt<json> { return (to-json($_), 'application/json') }
    with %opt<form> {
        return ($_.hash.kv.map(-> $k, $v { esc($k) ~ '=' ~ esc($v) }).sort.join('&'),
                'application/x-www-form-urlencoded');
    }
    with %opt<body> { return ($_, (%opt<content-type> // 'application/octet-stream')) }
    ('', '')
}

#| The proxy for this request, or Nil — NO_PROXY wins over both others.
method !proxy-for(Str $scheme, Str $host) {
    return Nil unless $!proxy;
    my $no = %*ENV<NO_PROXY> // %*ENV<no_proxy> // '';
    for $no.split(',')».trim.grep(*.chars) -> $pat {
        return Nil if $pat eq '*';
        my $p = $pat.subst(/^ '.' /, '');
        return Nil if $host eq $p || $host.ends-with(".$p");
    }
    my $url = $scheme eq 'https'
        ?? (%*ENV<HTTPS_PROXY> // %*ENV<https_proxy> // '')
        !! (%*ENV<HTTP_PROXY>  // %*ENV<http_proxy>  // '');
    return Nil unless $url;
    $url = "http://$url" unless $url ~~ / ^ \w+ '://' /;
    my $u = URI.new($url);
    { host => ~$u.host, port => ($u._port.defined ?? $u._port.Int !! 80) }
}

method !remember-cookies(Str $host, HTTP::Simple::Response $resp) {
    for $resp.headers-all('set-cookie') -> $line {
        my $pair = $line.Str.split(';')[0].trim;
        my $eq   = $pair.index('=');
        next without $eq;
        %!jar{$host}{$pair.substr(0, $eq).trim} = $pair.substr($eq + 1).trim;
    }
}

#| Where a byte sequence first occurs in a Blob, or Int (undefined). Needed
#| because a Raku string glues CR LF into one grapheme, which puts every
#| character offset out of step with the wire.
sub blob-index(Blob $b, @needle, Int $from = 0 --> Int) {
    my $n   = @needle.elems;
    my $end = $b.elems - $n;
    loop (my $i = $from; $i <= $end; $i++) {
        my $hit = True;
        for ^$n -> $j {
            if $b[$i + $j] != @needle[$j] { $hit = False; last }
        }
        return $i if $hit;
    }
    Int
}

#| Percent-encode one query or form value.
sub esc(Str() $s --> Str) {
    $s.subst(/ <-[A..Za..z0..9._~\-]> /,
             { .Str.encode('utf8').list.map({ sprintf '%%%02X', $_ }).join },
             :g)
}

sub b64(Blob $b --> Str) {
    my @by  = $b.list;
    my $out = '';
    loop (my $i = 0; $i < @by.elems; $i += 3) {
        my $n = (@by[$i] +< 16) +| ((@by[$i + 1] // 0) +< 8) +| (@by[$i + 2] // 0);
        $out ~= @B64[($n +> 18) +& 63] ~ @B64[($n +> 12) +& 63];
        $out ~= $i + 1 < @by.elems ?? @B64[($n +> 6) +& 63] !! '=';
        $out ~= $i + 2 < @by.elems ?? @B64[$n +& 63]        !! '=';
    }
    $out
}
