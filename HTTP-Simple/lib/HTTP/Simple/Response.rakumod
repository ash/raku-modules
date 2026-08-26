use JSON::Fast;
use HTTP::Simple::X;
use HTTP::Simple::Message;

unit class HTTP::Simple::Response does HTTP::Simple::Message;

#| One HTTP response. The body is kept as the bytes that came over the wire;
#| `.text` decodes them and `.json` parses that, so nothing is guessed until you
#| ask for it.
#|
#| The status and header accessors — `.ok`, `.header`, `.charset` and the rest —
#| come from `HTTP::Simple::Message`, which `HTTP::Simple::Stream` also does.
has Int  $.status is required;
has Str  $.reason = '';
has      %.headers;          #= keys lower-cased; a repeated header is a List
has Blob $.body = Blob.new;
has Str  $.url = '';         #= the final URL, after any redirects
has      @.history;          #= the responses that redirected here, in order

#| The body decoded using the Content-Type charset.
method text(--> Str) { self.decode($!body) }

method json() { from-json(self.text) }

method gist(--> Str) { "HTTP::Simple::Response({$!status} {$!reason}, {$!body.elems} bytes)" }
method Str(--> Str)  { self.text }
