use JSON::Fast;
use HTTP::Simple::X;

unit class HTTP::Simple::Response;

#| One HTTP response. The body is kept as the bytes that came over the wire;
#| `.text` decodes them and `.json` parses that, so nothing is guessed until you
#| ask for it.
has Int  $.status is required;
has Str  $.reason = '';
has      %.headers;          #= keys lower-cased; a repeated header is a List
has Blob $.body = Blob.new;
has Str  $.url = '';         #= the final URL, after any redirects
has      @.history;          #= the responses that redirected here, in order

method ok(--> Bool)          { 200 <= $!status < 300 }
method is-redirect(--> Bool) { 300 <= $!status < 400 }
method is-error(--> Bool)    { $!status >= 400 }
method Bool(--> Bool)        { self.ok }

#| The header's value, or the last one if the server repeated it. Missing is ''.
method header(Str $name --> Str) {
    my $v = %!headers{$name.lc};
    return '' without $v;
    $v ~~ Positional ?? ($v[*-1] // '').Str !! $v.Str
}

#| Every value of a possibly-repeated header — Set-Cookie is the usual reason.
method headers-all(Str $name --> List) {
    my $v = %!headers{$name.lc};
    return () without $v;
    $v ~~ Positional ?? $v.List !! ($v.Str,)
}

method content-type(--> Str) { self.header('content-type').split(';')[0].trim.lc }

#| The charset the server declared, defaulting to UTF-8 as HTTP does for text.
method charset(--> Str) {
    with self.header('content-type').match(/ 'charset=' $<cs> = [ <-[;\s]>+ ] /) {
        return (~$_<cs>).subst('"', '', :g).lc;
    }
    'utf-8'
}

#| The body decoded to text. An encoding the engine cannot handle falls back to
#| latin-1, which never fails and never loses a byte.
method text(--> Str) {
    return '' unless $!body.elems;
    my $cs  = self.charset;
    my $enc = $cs eq 'utf-8' || $cs eq 'utf8'                ?? 'utf8'
           !! $cs eq 'ascii' || $cs eq 'us-ascii'            ?? 'ascii'
           !! $cs eq 'latin-1' || $cs eq 'iso-8859-1'        ?? 'latin-1'
           !!                                                   'utf8';
    my $out = try $!body.decode($enc);
    $out // (try $!body.decode('latin-1')) // ''
}

method json() { from-json(self.text) }

#| Throw unless the status is a success. The counterpart to `:fatal`.
method raise-for-status(--> HTTP::Simple::Response) {
    return self if self.ok;
    X::HTTP::Simple::Status.new(response => self).throw;
}

method gist(--> Str) { "HTTP::Simple::Response({$!status} {$!reason}, {$!body.elems} bytes)" }
method Str(--> Str)  { self.text }
