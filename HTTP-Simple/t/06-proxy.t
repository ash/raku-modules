use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use HTTP::Simple;
use HTTP::Simple::TestServer;

plan 12;

# The test server stands in for the proxy, and forwards nothing. It does not need
# to: everything that distinguishes a proxied request from a direct one is in the
# bytes the client sends, and the server keeps every request it saw.
my $server = HTTP::Simple::TestServer.new(handler => -> %req {
    reply 200, %req<target>
}).start;

LEAVE $server.stop;

my $proxy = "127.0.0.1:{$server.port}";
my $dead  = '127.0.0.1:1';      # nothing listens there, and nothing should try

# A proxy variable inherited from whatever shell is running the suite would
# reroute every case below, so the file starts from a known-empty environment
# and puts back what it found.
my @vars  = <HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy>;
my %outer = @vars.map({ $_ => %*ENV{$_} }).Hash;
%*ENV{$_}:delete for @vars;
LEAVE {
    for %outer.kv -> $k, $v {
        if $v.defined { %*ENV{$k} = $v } else { %*ENV{$k}:delete }
    }
}

sub with-env(%vars, &body) {
    my %saved = %vars.keys.map({ $_ => %*ENV{$_} }).Hash;
    %*ENV{.key} = .value for %vars.pairs;
    LEAVE {
        for %saved.kv -> $k, $v {
            if $v.defined { %*ENV{$k} = $v } else { %*ENV{$k}:delete }
        }
    }
    body()
}

# --- through a proxy
#
# `example.invalid` can never resolve — .invalid is reserved precisely so that it
# cannot — so a request arriving at the server at all proves the client connected
# to the proxy rather than to the host named in the URL.

with-env({ HTTP_PROXY => $proxy }, {
    my $r = http-get 'http://example.invalid/thing';
    is $r.status, 200, 'a proxied request reaches the proxy';
    is $server.requests[*-1]<target>, 'http://example.invalid/thing',
       'and its request line carries the absolute URL, not the path';
    is $server.requests[*-1]<headers><host>, 'example.invalid',
       'while Host still names the target, not the proxy';
});

with-env({ HTTP_PROXY => $proxy }, {
    http-get 'http://example.invalid:8080/thing', query => { a => 1 };
    is $server.requests[*-1]<target>, 'http://example.invalid:8080/thing?a=1',
       'a non-default port and the query survive into the absolute URL';
});

with-env({ http_proxy => $proxy }, {
    http-get 'http://example.invalid/lower';
    is $server.requests[*-1]<target>, 'http://example.invalid/lower',
       'the lower-case spelling is honoured too';
});

# --- and without one

http-get $server.url('/thing');
is $server.requests[*-1]<target>, '/thing',
   'with no proxy set the request line is the path alone';

# --- NO_PROXY, which wins over both of the others
#
# The proxy in these two is a dead address, so an exemption that failed to fire
# could not reach the server by accident.

with-env({ HTTP_PROXY => $dead, NO_PROXY => '127.0.0.1' }, {
    is http-get($server.url('/thing')).status, 200,
       'a host named in NO_PROXY goes direct';
});

with-env({ HTTP_PROXY => $dead, NO_PROXY => '*' }, {
    is http-get($server.url('/thing')).status, 200,
       'NO_PROXY=* exempts everything';
});

with-env({ HTTP_PROXY => $proxy, NO_PROXY => '.invalid' }, {
    my $before = $server.requests.elems;
    throws-like { http-get 'http://example.invalid/thing', connect-timeout => 1 },
        X::HTTP::Simple::Transport,
        'a leading dot in NO_PROXY exempts the whole domain';
    is $server.requests.elems, $before, 'so nothing at all reached the proxy';
});

# --- the client can decline to read the environment

with-env({ HTTP_PROXY => $dead }, {
    my $http = HTTP::Simple::Client.new(proxy => False);
    is $http.get($server.url('/thing')).status, 200,
       'proxy => False ignores the environment entirely';
});

# --- https through a proxy needs CONNECT, which 0.0.1 does not do

with-env({ HTTPS_PROXY => $proxy }, {
    throws-like { http-get 'https://example.invalid/thing' },
        X::HTTP::Simple::Transport,
        'https through a proxy is refused, not half-attempted',
        message => /CONNECT/;
});
