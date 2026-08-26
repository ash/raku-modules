use JSON::Fast;

unit class HTTP::Simple::SSE;

#| One `text/event-stream` event, as dispatched by a blank line.
#|
#| `data` is the concatenation of every `data:` field in the block, joined with
#| newlines and with the trailing one removed — so a single-line event is just
#| its payload, and `.json` parses it.
#|
#| `id` and `retry` carry the last values the stream sent, not necessarily ones
#| that appeared in this block: both are stream-level state in the spec, and an
#| event that omits them inherits what came before.

has Str $.event = 'message';    #= the `event:` field, or 'message' when omitted
has Str $.data  = '';
has Str $.id    = '';
has Int $.retry;                #= the server's reconnection hint, in ms

method json() { from-json($!data) }

method gist(--> Str) { "HTTP::Simple::SSE($!event: {$!data.chars} chars)" }
method Str(--> Str)  { $!data }
