# peerpatrol package, callable via pkgs.callPackage
# (referenced by this flake's packages.<system>.default and nixosModules.default,
# which defaults services.peerpatrol.package to it).
{
  stdenv,
  zig,
  lib,
}:

stdenv.mkDerivation {
  name = "peerpatrol";
  # Zig pinned by nixpkgs; static linux binary (musl, baseline cpu).
  nativeBuildInputs = [ zig ];

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        n = baseNameOf (toString path);
      in
      !(n == ".zig-cache" || n == ".scratch" || n == ".git" || n == ".opencode" || n == "zig-out" || n == "node_modules");
  };

  # zig needs a writable cache dir; $HOME does not exist in derivations.
  XDG_CACHE_HOME = "$TMPDIR";

  # `-Dtarget` per build platform; baseline cpu keeps the binary portable.
  archTarget =
    {
      x86_64-linux = "x86_64-linux-musl";
      aarch64-linux = "aarch64-linux-musl";
    }
    .${stdenv.hostPlatform.system} or (throw "peerpatrol does not build for ${stdenv.hostPlatform.system}");

  installPhase = ''
    mkdir -p $out/bin
    zig build -Doptimize=ReleaseSafe -Dtarget=$archTarget --prefix $out install
  '';

  meta = {
    description = "Hash-scheduled peer monitoring agent; alarms via a shared Telegram chat";
    license = lib.licenses.mit;
    mainProgram = "peerpatrol";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
