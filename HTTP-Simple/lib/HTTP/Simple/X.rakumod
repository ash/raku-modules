#| The two exception types, in their own file so that both the response and the
#| client can throw them without depending on each other.
#|
#| There is deliberately no `unit module` line here: the exceptions are meant to
#| be `X::HTTP::Simple::Transport`, not `HTTP::Simple::X::X::HTTP::Simple::…`.

#| A transport failure — DNS, connect, TLS, timeout. An HTTP *status* is never
#| one of these: a 404 is an answer, so it comes back as a response with `.ok`
#| False instead.
class X::HTTP::Simple::Transport is Exception is export {
    has Str $.url    = '';
    has Str $.detail = '';
    method message(--> Str) { "Could not fetch $!url: $!detail" }
}

#| Thrown by `.raise-for-status`, and by passing `:fatal` to a call.
class X::HTTP::Simple::Status is Exception is export {
    has $.response is required;
    method status()   { $!response.status }
    method message(--> Str) {
        "HTTP {$!response.status} {$!response.reason} for {$!response.url}"
    }
}
