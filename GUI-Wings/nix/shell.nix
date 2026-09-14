# A shell in which GUI::Wings can find GTK on NixOS, where no library sits on
# the loader's default search path. Without it the first GTK call is
#
#   Cannot locate native library 'libgtk-3.so.0': libgtk-3.so.0: cannot open
#   shared object file: No such file or directory
#
# and `nix-shell -p gtk3` does not settle it either — that leaves
# LD_LIBRARY_PATH unset.
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
