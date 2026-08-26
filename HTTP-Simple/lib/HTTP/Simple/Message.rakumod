use HTTP::Simple::X;

#| What a response head is, whether the body has already arrived or is still on
#| the wire. `HTTP::Simple::Response` and `HTTP::Simple::Stream` both do this
#| role, so status and header handling is written once and the two agree by
#| construction rather than by inspection.
#|
#| Every method here goes through the public accessors instead of attributes:
#| the two classes declare their own storage, and a role cannot reach into a
#| class's private state.

unit role HTTP::Simple::Message;

method ok(--> Bool)          { 200 <= self.status < 300 }
method is-redirect(--> Bool) { 300 <= self.status < 400 }
method is-error(--> Bool)    { self.status >= 400 }
method Bool(--> Bool)        { self.ok }

#| The header's value, or the last one if the server repeated it. Missing is ''.
method header(Str $name --> Str) {
    my $v = self.headers{$name.lc};
    return '' without $v;
    $v ~~ Positional ?? ($v[*-1] // '').Str !! $v.Str
}

#| Every value of a possibly-repeated header — Set-Cookie is the usual reason.
method headers-all(Str $name --> List) {
    my $v = self.headers{$name.lc};
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

#| Decode bytes using the declared charset. An encoding the engine cannot handle
#| falls back to latin-1, which never fails and never loses a byte.
method decode(Blob $bytes --> Str) {
    return '' unless $bytes.elems;
    my $cs  = self.charset;
    my $enc = $cs eq 'utf-8'   || $cs eq 'utf8'        ?? 'utf8'
           !! $cs eq 'ascii'   || $cs eq 'us-ascii'    ?? 'ascii'
           !! $cs eq 'latin-1' || $cs eq 'iso-8859-1'  ?? 'latin-1'
           !!                                             'utf8';
    my $out = try $bytes.decode($enc);
    $out // (try $bytes.decode('latin-1')) // ''
}

#| Throw unless the status is a success. The counterpart to `:fatal`.
method raise-for-status() {
    return self if self.ok;
    X::HTTP::Simple::Status.new(response => self).throw;
}
