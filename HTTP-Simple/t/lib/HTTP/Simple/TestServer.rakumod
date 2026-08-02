unit class HTTP::Simple::TestServer;

#| A throwaway HTTP/1.1 server for the test suite: no network, no fixtures, and
#| every request it saw is kept so a test can assert on what was actually sent.
#|
#| The handler is given a hash — `method`, `target`, `headers`, `body` — and
#| returns the raw response text, CRLFs and all. `reply` builds one for you.

has Int   $.port;
has       &.handler is required;
has       @.requests;
has       $!tap;

method start(--> HTTP::Simple::TestServer) {
    for 31_500 .. 31_600 -> $candidate {
        my $failed = Promise.new;
        my $vow    = $failed.vow;
        my $tap = IO::Socket::Async.listen('127.0.0.1', $candidate).tap(
            -> $conn { self!serve($conn) },
            quit => { $vow.keep(True) if $failed.status ~~ Planned },
        );
        await Promise.anyof($failed, Promise.in(0.2));
        if $failed.status ~~ Kept {
            $tap.close;
            next;
        }
        $!tap  = $tap;
        $!port = $candidate;
        return self;
    }
    die 'no free port in 31500..31600 for the test server';
}

method stop() { .close with $!tap; $!tap = Nil }

method base(--> Str) { "http://127.0.0.1:{$!port}" }

method url(Str $path --> Str) { self.base ~ $path }

method !serve($conn) {
    my $buf = Buf.new;
    my $handled = False;
    $conn.Supply(:bin).tap(-> $chunk {
        $buf.append($chunk);
        unless $handled {
            # Byte offsets: "\r\n" is one grapheme in a Raku string, so character
            # positions do not line up with the wire.
            my $sep = blob-index($buf, (13, 10, 13, 10));
            with $sep {
                my @lines = $buf.subbuf(0, $sep).decode('latin-1').lines;
                my @start = (@lines.shift // '').split(' ');
                my %headers;
                for @lines -> $line {
                    my $c = $line.index(':');
                    %headers{$line.substr(0, $c).trim.lc} = $line.substr($c + 1).trim
                        with $c;
                }
                my $want = (%headers<content-length> // 0).Int;
                my $body = $buf.subbuf($sep + 4);
                if $body.elems >= $want {
                    $handled = True;
                    my %req = method  => (@start[0] // ''),
                              target  => (@start[1] // ''),
                              headers => %headers,
                              body    => $body.subbuf(0, $want).decode('utf8');
                    @!requests.push(%req);
                    # A handler that returns Nil answers nothing and holds the
                    # connection open — that is how a timeout gets tested.
                    my $out = &!handler(%req);
                    if $out.defined {
                        await $conn.write($out ~~ Blob ?? $out !! $out.Str.encode('utf8'));
                        $conn.close;
                    }
                }
            }
        }
    });
}

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

#| Build a raw HTTP/1.1 response. Content-Length is filled in unless the caller
#| already supplied one (a chunked test, say). A Str body is sent as UTF-8; pass
#| a Blob when the test needs particular bytes on the wire.
sub reply(Int $status = 200, $body = '', :%headers, Str :$reason --> Blob) is export {
    my $why = $reason // %(200 => 'OK', 201 => 'Created', 204 => 'No Content',
                           301 => 'Moved Permanently', 302 => 'Found',
                           303 => 'See Other', 307 => 'Temporary Redirect',
                           400 => 'Bad Request', 404 => 'Not Found',
                           500 => 'Internal Server Error'){$status} // 'Unknown';
    my $bytes   = $body ~~ Blob ?? $body !! $body.Str.encode('utf8');
    my %h       = %headers;
    my $has-len = %h.keys.first({ .lc eq 'content-length' }).defined;
    my $chunked = (%h.pairs.first({ .key.lc eq 'transfer-encoding' })
                   andthen .value.Str.lc.contains('chunked'));
    %h<Content-Length> = $bytes.elems.Str unless $has-len || $chunked;
    my $head = "HTTP/1.1 $status $why\r\n"
        ~ %h.kv.map(-> $k, $v {
              ($v ~~ Positional ?? $v.List !! ($v,)).map({ "$k: $_\r\n" }).join
          }).join
        ~ "Connection: close\r\n\r\n";
    Buf.new(|$head.encode('utf8').list, |$bytes.list)
}
