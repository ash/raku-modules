# A shell in which GUI::Wings can find GTK on NixOS, where no library sits on
# the loader's default search path and `libgtk-3.so.0` is therefore not found
# without being pointed at.
#
#   nix-shell nix/shell.nix --run 'raku -I lib examples/counter.raku'
#
# GTK alone is enough, although the backend also names `libgobject-2.0.so.0`
# and `libc.so.6`: by the time it asks for those they are already in the
# process, pulled in as GTK's own NEEDED libraries through the store RPATH
# that nix baked into `libgtk-3.so.0`, and a dlopen by soname matches what is
# already loaded.
#
# Reported by @habere-et-dispertire in issue #1.

{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShellNoCC {
  packages = [ pkgs.gtk3 ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.gtk3 ];
}
