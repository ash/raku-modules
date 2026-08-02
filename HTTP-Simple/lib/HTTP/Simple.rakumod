use HTTP::Simple::X;
use HTTP::Simple::Response;
use HTTP::Simple::Client;

unit module HTTP::Simple;

#| `get`, `put` and `head` are Raku CORE subs, so the one-shot layer is
#| prefixed. The client's *methods* keep the natural names — a class has its own
#| namespace.

#| A throwaway client per call, with the jar off: nothing leaks from one
#| one-shot call into the next. Reach for `HTTP::Simple::Client` when you want
#| state to persist.
sub client(%opt --> HTTP::Simple::Client) {
    HTTP::Simple::Client.new(
        |(timeout         => $_ with %opt<timeout>),
        |(connect-timeout => $_ with %opt<connect-timeout>),
        |(retries         => $_ with %opt<retries>),
        |(follow          => $_ with %opt<follow>),
        cookies => False,
    )
}

sub http-request(Str $method, Str $url, *%opt --> HTTP::Simple::Response) is export {
    client(%opt).request($method, $url, |%opt)
}

sub http-get(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('GET', $url, |%opt)
}

sub http-post(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('POST', $url, |%opt)
}

sub http-put(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('PUT', $url, |%opt)
}

sub http-patch(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('PATCH', $url, |%opt)
}

sub http-delete(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('DELETE', $url, |%opt)
}

sub http-head(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('HEAD', $url, |%opt)
}

sub http-options(Str $url, *%opt --> HTTP::Simple::Response) is export {
    http-request('OPTIONS', $url, |%opt)
}

#| GET and decode in one step. A non-2xx throws, because there is no sensible
#| JSON to hand back from one.
sub http-get-json(Str $url, *%opt) is export {
    http-request('GET', $url, |%opt).raise-for-status.json
}
