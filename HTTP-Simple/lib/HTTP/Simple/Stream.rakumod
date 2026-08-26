use JSON::Fast;
use HTTP::Simple::X;
use HTTP::Simple::Message;
use HTTP::Simple::Response;
use HTTP::Simple::SSE;

unit class HTTP::Simple::Stream does HTTP::Simple::Message;

#| A response whose head has arrived and whose body has not. The status and the
#| headers are here to be read now; the body is a `Supply` of the bytes as they
#| come off the wire, dechunked, in order.
#|
#| Reading the head first is the whole point. A server answering a streaming
#| request with an error sends a short ordinary body, not a stream, so a client
#| that starts parsing events before it has looked at the status is parsing the
#| wrong thing.
#|
#| `body` is meant for one consumer. It is a preserving supply, so nothing
#| emitted between the head arriving and your `tap` is lost, but a second tap
#| divides the bytes with the first rather than repeating them.

has Int    $.status is required;
has Str    $.reason = '';
has        %.headers;           #= keys lower-cased; a repeated header is a List
has Str    $.url = '';          #= the final URL, after any redirects
has        @.history;           #= the responses that redirected here, in order
has Supply $.body is required;  #= Blob chunks, dechunked
has        &.closer;            #= hangs up, when the caller has heard enough

#| Stop reading and hang up. The body supply finishes normally — an early close
#| is a decision, not a truncation, and it should not look like one downstream.
method close(--> Nil) { .() with &!closer }

#| The body split on newlines and decoded, with the terminator removed. Safe
#| across chunk boundaries: a line break is one byte that never occurs inside a
#| UTF-8 sequence, so the split happens on bytes and only whole lines decode.
method lines(--> Supply) {
    supply {
        my $buf = Buf.new;
        whenever $!body -> $chunk {
            $buf.append($chunk);
            loop {
                my $nl = blob-find($buf, 10);
                last without $nl;
                emit self.decode(strip-cr($buf.subbuf(0, $nl)));
                $buf = Buf.new($buf.subbuf($nl + 1));
            }
            LAST {
                emit self.decode(strip-cr($buf)) if $buf.elems;
            }
        }
    }
}

#| The body parsed as `text/event-stream`. One emit per event, at its blank
#| line; comments (`: keep-alive`) and unknown fields are dropped.
method sse(--> Supply) {
    supply {
        my Str $event = '';
        my Str $data  = '';
        my Str $id    = '';
        my Int $retry;
        whenever self.lines -> $raw {
            # The BOM is only ever on the first line; stripping it from each one
            # costs nothing and saves counting them.
            my $line = $raw.subst(/ ^ \x[FEFF] /, '');
            if $line eq '' {
                if $data.chars {
                    $data .= chop if $data.ends-with("\n");
                    emit HTTP::Simple::SSE.new(
                        event => ($event || 'message'), :$data, :$id, :$retry);
                }
                $event = '';
                $data  = '';
            }
            elsif !$line.starts-with(':') {
                my $c = $line.index(':');
                my $field = $c.defined ?? $line.substr(0, $c)     !! $line;
                my $value = $c.defined ?? $line.substr($c + 1)    !! '';
                $value .= subst(/ ^ ' ' /, '');     # one optional space, per the spec
                given $field {
                    when 'event' { $event = $value }
                    when 'data'  { $data ~= $value ~ "\n" }
                    when 'id'    { $id = $value unless $value.contains("\0") }
                    when 'retry' { $retry = $value.Int if $value ~~ / ^ \d+ $ / }
                }
            }
        }
    }
}

#| Read the body to the end and hand back the bytes. Blocks; a transport failure
#| part-way through throws, because a truncated body is not a short one.
method blob(--> Blob) {
    my $out = Buf.new;
    react whenever $!body -> $chunk { $out.append($chunk) }
    Blob.new($out)
}

method text(--> Str) { self.decode(self.blob) }
method json()        { from-json(self.text) }

#| Collect the rest of the stream into an ordinary Response. What you want for
#| an error: the status said 429, so the body is a small JSON object and there
#| is nothing to stream.
method response(--> HTTP::Simple::Response) {
    HTTP::Simple::Response.new(
        status  => $!status, reason  => $!reason,
        headers => %!headers, body   => self.blob,
        url     => $!url,     history => @!history,
    )
}

method gist(--> Str) { "HTTP::Simple::Stream({$!status} {$!reason}, streaming)" }

#| Where a byte first occurs in a Blob, or Int (undefined).
sub blob-find(Blob $b, Int $byte, Int $from = 0 --> Int) {
    loop (my $i = $from; $i < $b.elems; $i++) {
        return $i if $b[$i] == $byte;
    }
    Int
}

sub strip-cr(Blob $b --> Blob) {
    $b.elems && $b[$b.elems - 1] == 13 ?? $b.subbuf(0, $b.elems - 1) !! $b
}
