#!/usr/bin/env rakupp
# What TLS binding does this machine actually get?
#
# HTTP::Simple reaches https through IO::Socket::Async::SSL, which reaches
# libssl through the OpenSSL distribution — and it is that last hop that decides
# WHICH libssl gets opened and WHICH spelling of the peer-certificate call is
# asked for. When https fails with a missing symbol or a missing library, this
# says which of those two answers went wrong.
#
#   rakupp tls-diagnose.raku        (or: raku tls-diagnose.raku)
#
# Send the whole output. Nothing here is secret — library paths and OpenSSL
# version strings, no keys and no certificates.

use NativeCall;
use NativeCall :ALL;   # guess_library_name; :ALL alone does not carry `is native`

say "engine   : $*EXECUTABLE";
say "compiler : {$*RAKU.compiler.name} {$*RAKU.compiler.version}";
say "kernel   : {$*KERNEL.name} {$*KERNEL.release} {$*KERNEL.hardware}";
say '';

# The OpenSSL dist bakes a path into its resources/libraries.json when it is
# INSTALLED, and $*VM.platform-library-name decorates it at run time. A store
# shared with another toolchain therefore hands out that toolchain's path — an
# x86_64 Homebrew prefix to an arm64 engine, say.
my $ssl-lib = (try EVAL 'use OpenSSL::NativeLib; ssl-lib()') // '';
my $gen-lib = (try EVAL 'use OpenSSL::NativeLib; gen-lib()') // '';
say "ssl-lib  : ", $ssl-lib || 'OpenSSL dist not installed / not loadable';
say "gen-lib  : ", $gen-lib || 'OpenSSL dist not installed / not loadable';
say '';

# Both engines want the library named at COMPILE time, so it is reached through
# a provider sub — the same way OpenSSL::NativeLib itself does it. One sub per
# library: the name is resolved once per native sub and then cached.
sub L-ssl() { $ssl-lib }
sub L-gen() { $gen-lib }

my sub ssl-vnum()      returns ulong is native(&L-ssl) is symbol('OpenSSL_version_num') {*}
my sub ssl-vstr(int32) returns Str   is native(&L-ssl) is symbol('OpenSSL_version')     {*}
my sub gen-vnum()      returns ulong is native(&L-gen) is symbol('OpenSSL_version_num') {*}
my sub gen-vstr(int32) returns Str   is native(&L-gen) is symbol('OpenSSL_version')     {*}

# A name WITH a directory is handed to dlopen as written, so guess_library_name
# only decorates a bare one. If the file below is missing or unloadable and a
# version still prints, the engine fell back to another copy of the library.
sub report($what, $lib, &vnum, &vstr) {
    return unless $lib;
    say "$what — $lib";
    say "  dlopen name : ", (try guess_library_name($lib)) // '(nothing)';
    say "  file exists : ", $lib.IO.e ?? 'yes' !! 'NO';
    say "  version_num : ", (try vnum().base(16)) // "MISSING — {$!.message.lines[0]}";
    say "  version     : ", (try vstr(0)) // '(unavailable)';
    say '';
}
report('ssl-lib', $ssl-lib, &ssl-vnum, &ssl-vstr);
report('gen-lib', $gen-lib, &gen-vnum, &gen-vstr) unless $gen-lib eq $ssl-lib;

# The dist chooses between the first two spellings by version number; they are
# one function under two names. The third is NOT interchangeable with them — it
# hands back a borrowed reference — so nothing may substitute it for either.
my sub g1(Pointer) returns Pointer is native(&L-ssl) is symbol('SSL_get1_peer_certificate') {*}
my sub gp(Pointer) returns Pointer is native(&L-ssl) is symbol('SSL_get_peer_certificate')  {*}
my sub g0(Pointer) returns Pointer is native(&L-ssl) is symbol('SSL_get0_peer_certificate') {*}
if $ssl-lib {
    say 'peer-certificate symbols in ssl-lib';
    say "  SSL_get1_peer_certificate : ", (try { g1(Pointer); 'binds' }) // "NO — {$!.message.lines[0]}";
    say "  SSL_get_peer_certificate  : ", (try { gp(Pointer); 'binds' }) // "NO — {$!.message.lines[0]}";
    say "  SSL_get0_peer_certificate : ", (try { g0(Pointer); 'binds' }) // "NO — {$!.message.lines[0]}";
    say '  (rakupp answers both of the first two on purpose: they are one';
    say '   function, so it substitutes whichever spelling the library has.';
    say '   Rakudo binds only the name that is really exported.)';
    say '';
}

my $tls = try EVAL 'use IO::Socket::Async::SSL; IO::Socket::Async::SSL.^name';
say "IO::Socket::Async::SSL : ",
    $tls ?? 'loads' !! "WILL NOT LOAD — {$!.message.lines[0]}";

my $r = try EVAL 'use HTTP::Simple; http-get("https://example.com").status';
say "https://example.com    : ", $r ?? "$r" !! "FAILED — {$!.message.lines[0]}";
