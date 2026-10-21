`libffi.a` here was compiled from Nixpkgs master on 2024-12-06 on an x86_64-darwin machine, and
is vendored because Nixpkgs cannot cross-compile an x86_64-darwin `libffi.a` from an
aarch64-darwin builder. `nix/macos-modules.nix` force-loads it when targeting x86_64-darwin and
uses `pkgsStatic.libffi` otherwise.

Copied from cpp-notebook-language-server, which vendors the same file for the same reason.
