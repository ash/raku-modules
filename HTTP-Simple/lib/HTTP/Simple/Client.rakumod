use URI;
use JSON::Fast;
use HTTP::Simple::X;
use HTTP::Simple::Response;
use HTTP::Simple::Stream;

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
has Str  $.user-agent = 'HTTP::Simple/0.1.0 Raku';
has Str  $.ca-file;                     #= trust anchors, instead of the system store
has Str  $.ca-path;
has Bool $.insecure = False;            #= accept any certificate — for testing only

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

#| The same request, with the body left on the wire: returns as soon as the
#| response *head* has arrived, so the status and headers can be read before a
#| byte of the body is. That ordering is the point of the method. A server
#| answering a streaming request with an error sends a short ordinary body
#| rather than a stream, and a client that starts parsing events before looking
#| at the status is parsing the wrong thing.
#|
#| Redirects are followed, because the head that decides is in hand before any
#| body is read. Retries are not offered: a request whose response is being
#| consumed as it arrives cannot be replayed once the caller has seen part of it,
#| and retrying only the head would be a promise this cannot keep for the rest.
method stream(Str $method is copy, Str $target, *%opt --> HTTP::Simple::Stream) {
    $method .= uc;
    my $url    = self!absolute($target);
    # `timeout` bounds the head, not the last byte: a stream that is meant to
    # stay open for minutes has not failed by being slow. What would be a failure
    # is silence, so the body is bounded by a gap between chunks instead.
    my $head-timeout = %opt<timeout>      // $!timeout;
    my $idle         = %opt<idle-timeout> // $head-timeout;
    my $follow       = %opt<follow>       // $!follow;
    my @history;

    loop (my $hop = 0; $hop <= $!max-redirects; $hop++) {
        my $s = self!stream-once($method, $url, %opt, $head-timeout, $idle, @history.List);

        my $location = $s.header('location');
        unless $follow && $s.is-redirect && $location {
            $s.raise-for-status if %opt<fatal>;
            return $s;
        }

        $s.close;                       # the redirect's own body is of no interest
        @history.push(HTTP::Simple::Response.new(
            status => $s.status, reason => $s.reason,
            headers => $s.headers, url => $url));
        $url = self!redirect-target($url, $location);
        if $s.status == 303
        || (($s.status == 301 || $s.status == 302) && $method ne 'GET' && $method ne 'HEAD') {
            $method = 'GET';
            %opt<json>:delete;
            %opt<form>:delete;
            %opt<body>:delete;
        }
    }
    X::HTTP::Simple::Transport.new(
        :$url, detail => "more than {$!max-redirects} redirects").throw;
}

method !one-request(Str $method, Str $url, %opt, Real $timeout --> HTTP::Simple::Response) {
    my %p    = self!prepare($method, $url, %opt);
    my $raw  = self!exchange(%p<scheme>, %p<conn-host>, %p<conn-port>, %p<wire>,
                             $timeout, $url, $method, %p<tls>);
    my $resp = self!parse($raw, $url, $method);
    self!remember-cookies(%p<host>, $resp) if $!cookies;
    $resp
}

#| Everything one request needs on the wire, worked out once: where to connect,
#| the bytes to send, and the TLS options. Shared by the buffered and streaming
#| paths so the two cannot drift apart over headers, auth or proxying.
method !prepare(Str $method, Str $url, %opt --> Hash) {
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

    # Certificate trust is per-client, overridable per request. Without any of
    # these the system trust store applies, which is what a caller wants.
    my %tls;
    with %opt<ca-file> // $!ca-file { %tls<ca-file> = .Str }
    with %opt<ca-path> // $!ca-path { %tls<ca-path> = .Str }
    %tls<insecure> = True if %opt<insecure> // $!insecure;

    %( :$scheme, :$host, :$conn-host, :$conn-port, :$wire, :%tls )
}

# ------------------------------------------------------------------ transport

#| Send the request and read the response. The message frames itself —
#| Content-Length, or the terminal chunk — and only a response with no framing
#| at all is read until the server closes. Waiting for the close in every case
#| costs a round trip, and makes every request depend on the peer hanging up
#| promptly, which is not something a client gets to assume.
method !exchange(Str $scheme, Str $host, Int $port, Blob $wire, Real $timeout, Str $url,
                 Str $method, %tls = {} --> Blob) {
    my $conn = self!connect($scheme, $host, $port, $url, %tls);

    my $buf  = Buf.new;
    my $done = Promise.new;
    my $vow  = $done.vow;
    my %framing;                        # what !complete has worked out so far
    $conn.Supply(:bin).tap(
        -> $chunk {
            $buf.append($chunk);
            $vow.keep(True) if $done.status ~~ Planned
                            && self!complete($buf, $method, %framing);
        },
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

#| Open the connection, or throw saying why it could not be opened.
method !connect(Str $scheme, Str $host, Int $port, Str $url, %tls = {}) {
    my $https = $scheme eq 'https';
    my $ssl   = $https ?? self!ssl-class !! Nil;    # throws if the TLS dist is absent
    my $connecting = try $https ?? $ssl.connect($host, $port, |%tls)
                                !! IO::Socket::Async.connect($host, $port);
    # A name that does not resolve is thrown by `.connect` itself instead of
    # breaking the promise it would have returned, so it escapes past the check
    # below — as a bare X::AdHoc, for a failure this module documents as a
    # transport error like any other.
    without $connecting {
        X::HTTP::Simple::Transport.new(:$url,
            detail => "could not connect to $host:$port: {$!.?message // $!}").throw;
    }
    await Promise.anyof($connecting, Promise.in($!connect-timeout));
    # A refused connection and a rejected certificate both land here; saying
    # which one it was matters far more than saying "timed out" for both.
    if $connecting.status ~~ Broken {
        my $why = $connecting.cause.?message // ~$connecting.cause;
        X::HTTP::Simple::Transport.new(:$url,
            detail => "could not connect to $host:$port: $why").throw;
    }
    unless $connecting.status ~~ Kept {
        X::HTTP::Simple::Transport.new(:$url,
            detail => "could not connect to $host:$port within {$!connect-timeout} s").throw;
    }
    $connecting.result
}

#| One streaming exchange. Reads until the head is complete, hands that back,
#| and keeps pushing the body into a supply as it arrives.
#|
#| Two clocks, because a stream has two failure modes. `$timeout` bounds the
#| wait for the head — a server that never answers. `$idle` bounds the gap
#| between body chunks — a connection that went quiet without hanging up. A
#| total timeout on the body would be wrong: staying open is what a stream is
#| for.
method !stream-once(Str $method, Str $url, %opt, Real $timeout, Real $idle, @history
                    --> HTTP::Simple::Stream) {
    my %p    = self!prepare($method, $url, %opt);
    my $conn = self!connect(%p<scheme>, %p<conn-host>, %p<conn-port>, $url, %p<tls>);

    my $head     = Promise.new;
    my $head-vow = $head.vow;

    # The head goes back to the caller before they can possibly have tapped, so
    # body bytes arriving in that window have to be held rather than dropped.
    # `Supplier::Preserving` is exactly that idea and is not used here: Raku++
    # hands a late tap nothing at all, so the buffering is done in the open,
    # where both engines can only agree. The lock is what orders the handover —
    # a producer takes it before deciding buffer-or-emit, and the tap takes it to
    # drain and flip the switch, so nothing slips between the two.
    my $lock     = Lock.new;
    my $live     = Supplier.new;
    my @backlog;                # chunks held for a tap that has not happened yet
    my $ending;                 # [$err] once the body is over, if that beat the tap
    my $tapped   = False;

    my &push-chunk = -> Blob $b {
        $lock.protect: {
            if $tapped {
                $live.emit($b);
            }
            else {
                @backlog.push($b);
            }
        }
    };

    my &push-end = -> $err? {
        $lock.protect: {
            if $tapped {
                with $err {
                    $live.quit($_);
                }
                else {
                    $live.done;
                }
            }
            else {
                $ending = [$err];
            }
        }
    };

    my $body = supply {
        # Subscribe first, drain second: a producer cannot go live until the
        # drain has released the lock, so the held chunks keep their place in
        # front of the ones still arriving.
        whenever $live.Supply -> $b { emit $b }
        my $end;
        $lock.protect: {
            emit $_ for @backlog;
            @backlog = ();
            $tapped  = True;
            $end     = $ending;
        };
        with $end {
            .[0] ?? .[0].throw !! done;
        }
    }

    my $pending  = Buf.new;     # bytes read but not yet framed — the head, then a part-chunk
    my %st;                     # what frames the body, once the head says
    my $got      = 0;           # body bytes emitted, against a Content-Length
    my $seen     = now;         # when the last byte arrived, for the idle clock
    my $ended    = False;
    my $idle-tap;

    my (&finish, &feed);

    #| Idempotent, and it is called from four places: the body ran out, the peer
    #| hung up, the idle clock fired, or the caller closed early.
    &finish = -> $err? {
        unless $ended {
            $ended = True;
            .close with $idle-tap;
            $conn.close;
            with $err {
                &push-end($_);
            }
            else {
                &push-end();
            }
        }
    };

    &feed = -> Blob $bytes {
        unless $ended {
            if %st<none> {
                &finish();                          # 204, 304, HEAD: there is no body
            }
            elsif %st<chunked> {
                $pending.append($bytes);
                my $out = chunk-drain($pending, %st);
                &push-chunk(Blob.new($out)) if $out.elems;
                &finish() if %st<ended>;
            }
            else {
                my $take = $bytes;
                with %st<want> {
                    my $left = $_ - $got;
                    $take = $bytes.subbuf(0, $left) if $bytes.elems > $left;
                }
                $got += $take.elems;
                &push-chunk(Blob.new($take)) if $take.elems;
                &finish() if %st<want>.defined && $got >= %st<want>;
            }
        }
    };

    $idle-tap = Supply.interval(1).tap({
        if !$ended && $head.status ~~ Kept && now - $seen > $idle {
            &finish(X::HTTP::Simple::Transport.new(:$url,
                detail => "no data for $idle s"));
        }
    });

    $conn.Supply(:bin).tap(
        -> $chunk {
            $seen = now;
            if $head.status ~~ Planned {
                $pending.append($chunk);
                my ($sep, $gap) = head-end($pending);
                with $sep {
                    my %h = parse-head($pending, $sep);
                    %st = framing-for($method, %h<status>, %h<headers>);
                    my $rest = Blob.new($pending.subbuf($sep + $gap));
                    $pending = Buf.new;
                    $head-vow.keep(%h);
                    &feed($rest);       # always, so a zero-length body finishes at once
                }
            }
            else {
                &feed($chunk);
            }
        },
        done => {
            if $head.status ~~ Planned {
                $head-vow.break(X::HTTP::Simple::Transport.new(:$url,
                    detail => 'the connection closed before the response head'));
            }
            else {
                # A body with no framing of its own ends at the close, and that
                # is the normal end. A framed one that stops short was cut off,
                # and saying so beats handing back a plausible half.
                my $short = %st<chunked> ?? !%st<ended>
                                         !! (%st<want>.defined && $got < %st<want>);
                &finish($short ?? X::HTTP::Simple::Transport.new(:$url,
                    detail => 'the connection closed mid-body') !! Nil);
            }
        },
        quit => -> $e {
            my $err = $e ~~ X::HTTP::Simple::Transport
                ?? $e
                !! X::HTTP::Simple::Transport.new(:$url, detail => ~($e.?message // $e));
            if $head.status ~~ Planned {
                $head-vow.break($err);
            }
            else {
                &finish($err);
            }
        },
    );

    await $conn.write(%p<wire>);
    await Promise.anyof($head, Promise.in($timeout));

    if $head.status ~~ Broken {
        &finish();
        my $why = $head.cause;
        $why ~~ Exception
            ?? $why.rethrow
            !! X::HTTP::Simple::Transport.new(:$url, detail => ~$why).throw;
    }
    unless $head.status ~~ Kept {
        &finish();
        X::HTTP::Simple::Transport.new(:$url,
            detail => "timed out after $timeout s waiting for the response head").throw;
    }

    my %h = $head.result;
    my $stream = HTTP::Simple::Stream.new(
        status  => %h<status>, reason => %h<reason>,
        headers => %h<headers>, :$url, history => @history.List,
        :$body, closer => -> { &finish() },
    );
    self!remember-cookies(%p<host>, $stream) if $!cookies;
    $stream
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

#| Has a complete response arrived? What it works out about the framing is kept
#| in %st, so every chunk after the first costs a length comparison (or a walk
#| resumed at the last chunk boundary) rather than a rescan of everything.
method !complete(Blob $buf, Str $method, %st --> Bool) {
    without %st<head> {
        my ($sep, $gap) = head-end($buf);
        return False without $sep;
        my %head = parse-head($buf, $sep);
        %st{.key} = .value
            for framing-for($method, %head<status>, %head<headers>).pairs;
        %st<head> = $sep + $gap;
        %st<from> = %st<head>;
    }
    return True if %st<none>;
    if %st<chunked> {
        my ($ended, $resume) = chunk-walk($buf, %st<from>);
        %st<from> = $resume;
        return $ended;
    }
    with %st<want> { return $buf.elems - %st<head> >= $_ }
    False   # nothing frames this response but the close, so wait for it
}

method !parse(Blob $raw, Str $url, Str $method --> HTTP::Simple::Response) {
    # Byte offsets throughout: in a Raku string "\r\n" is a single grapheme, so
    # character positions would not line up with the wire at all.
    my ($sep, $gap) = head-end($raw);
    X::HTTP::Simple::Transport.new(:$url,
        detail => $raw.elems ?? 'response headers never ended' !! 'empty response').throw
        without $sep;

    my %head    = parse-head($raw, $sep);
    my $status  = %head<status>;
    my $reason  = %head<reason>;
    my %headers = %head<headers>;

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

#| Takes anything that does HTTP::Simple::Message, so a stream fills the jar
#| from its head exactly as a buffered response does from its whole self.
method !remember-cookies(Str $host, $resp) {
    for $resp.headers-all('set-cookie') -> $line {
        my $pair = $line.Str.split(';')[0].trim;
        my $eq   = $pair.index('=');
        next without $eq;
        %!jar{$host}{$pair.substr(0, $eq).trim} = $pair.substr($eq + 1).trim;
    }
}

#| End of the header block: (offset of the blank line, its width in bytes), or
#| the empty list while the headers are still arriving. A bare LF is accepted
#| because servers in the wild send it.
sub head-end(Blob $b --> List) {
    my $sep = blob-index($b, CRLF2);
    return ($sep, 4) with $sep;
    $sep = blob-index($b, LF2);
    return ($sep, 2) with $sep;
    ()
}

#| The status line and headers of a response head, given where its blank line
#| starts. Keys are lower-cased and a repeated header becomes a List, which is
#| what the Response and the Stream both promise.
#|
#| A hash rather than a three-element list on purpose: `my ($s, $r, %h) = ...`
#| looks like it destructures and does not — a trailing `%` in a list assignment
#| slurps what is left, so the headers arrive as an odd hash initializer.
sub parse-head(Blob $b, Int $sep --> Hash) {
    my @lines  = $b.subbuf(0, $sep).decode('latin-1').lines;
    my @sl     = (@lines.shift // '').split(' ');
    my $status = (@sl[1] // '0').Int;
    my $reason = @sl.elems > 2 ?? @sl[2 .. *].join(' ') !! '';

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
    %( :$status, :$reason, :%headers )
}

#| What frames this response body: nothing at all, the chunked encoding, or a
#| length. The one place that decides, for the buffered and the streaming path
#| alike.
sub framing-for(Str $method, Int $status, %h --> Hash) {
    my %st;
    # RFC 9110 §6.4.1: these carry no body, whatever the headers claim.
    %st<none>    = $method eq 'HEAD' || $status == 204 | 304 || 100 <= $status < 200;
    %st<chunked> = (last-value(%h<transfer-encoding>) // '').Str.lc.contains('chunked');
    %st<want>    = Int;
    with last-value(%h<content-length>) { %st<want> = (try { .Str.Int }) // Int }
    %st
}

#| A header repeated on the wire arrives as a List; for the framing headers only
#| the last one can be meant.
sub last-value($v) { $v ~~ Positional ?? $v[*-1] !! $v }

#| Take whatever whole chunks have arrived off the front of $buf, leaving the
#| partial one behind for the next call, and set %st<ended> at the terminal
#| chunk. The consuming is the point: a stream that runs for minutes must not
#| keep every byte it has ever decoded.
sub chunk-drain(Buf $buf is rw, %st --> Blob) {
    my $out = Buf.new;
    my $pos = 0;
    loop {
        my $nl = blob-index($buf, CRLF, $pos);
        last without $nl;
        my $size-line = $buf.subbuf($pos, $nl - $pos).decode('latin-1').split(';')[0].trim;
        last unless $size-line;
        my $size = try { :16($size-line) };
        last without $size;
        if $size == 0 {
            # Trailers may follow the terminal chunk; nothing here reads them,
            # and the body is over either way.
            %st<ended> = True;
            $pos = $nl + 2;
            last;
        }
        my $start = $nl + 2;
        last if $buf.elems < $start + $size + 2;    # payload, or its CRLF, still coming
        $out.append($buf.subbuf($start, $size));
        $pos = $start + $size + 2;
    }
    $buf = Buf.new($buf.subbuf($pos)) if $pos;
    $out
}

#| Walk chunk headers from $from: (is the body complete?, where to resume). The
#| resume offset is the last chunk boundary reached, so re-checking after each
#| new chunk of bytes does not re-walk the ones already counted.
sub chunk-walk(Blob $b, Int $from is copy --> List) {
    loop {
        my $nl = blob-index($b, CRLF, $from);
        return (False, $from) without $nl;
        my $size-line = $b.subbuf($from, $nl - $from).decode('latin-1').split(';')[0].trim;
        my $size = try { :16($size-line) };
        return (False, $from) without $size;
        # After the terminal chunk come optional trailers and then a blank line.
        return (blob-index($b, CRLF2, $nl).defined, $from) if $size == 0;
        my $start = $nl + 2;
        return (False, $from) if $b.elems < $start + $size + 2;
        $from = $start + $size + 2;
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
