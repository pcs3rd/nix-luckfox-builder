# Bitfocus Companion Satellite — peripheral client for Companion v3+
#
# companion-satellite runs on a device with USB peripherals (Stream Deck, etc.)
# attached and connects back to a main Companion server on the network.
# This is the correct use-case for the Luckfox: small satellite with hardware
# attached, pointing at a full Companion install elsewhere.
#
# Source: https://github.com/bitfocus/companion-satellite
# Docs:   https://bitfocus.io/companion
#
# ── Build strategy ──────────────────────────────────────────────────────────
#
# The official releases are glibc-linked x86_64/arm64 AppImages/executables.
# Because our rootfs uses musl libc (armv7l-unknown-linux-musleabihf) those
# binaries WILL NOT RUN without a glibc compatibility shim.
#
# We build from source instead:
#   1. Fetch companion-satellite source from GitHub.
#   2. Run `npm ci` with the BUILD-host Node.js to install JS dependencies.
#   3. Copy the built source + node_modules to $out/opt/companion-satellite/.
#   4. Install a TARGET Node.js binary (musl-armv7l) to $out/bin/.
#   5. Write a launcher script at $out/bin/companion-satellite.
#
# ── Updating ────────────────────────────────────────────────────────────────
# To bump to a newer release:
#   1. Update SAT_REV to the new tag (e.g. "v3.2.0").
#   2. Update SAT_SHA256 — run:
#        nix-prefetch-github bitfocus companion-satellite --rev v3.2.0
#   3. Update NPM_DEPS_HASH — run a build, copy the hash from the error, retry.
#      Or use node2nix to generate a lock-file based build.

{ pkgs }:

let
  lib = pkgs.lib;

  SAT_REV    = "97e9a87070eb6d834f5b99e2f663dcf37955e1be";
  SAT_SHA256 = "sha256-PsERxsNPqg6iSlyHb59XhNw/HdTmciKOiFpHa7+ie9c=";   
  
  # Build-host Node.js (runs on the machine doing the compilation, e.g. your Mac)
  buildNode = pkgs.buildPackages.nodejs_20;

  # Target Node.js — cross-compiled for armv7l musl.
  # pkgs here is already crossed (crossSystem = armv7l-musl), so pkgs.nodejs
  # produces an armv7l binary.  We take the unwrapped real ELF via passthru
  # when available, otherwise just use the derivation's bin/node.
  targetNode = pkgs.nodejs_20;

in

pkgs.stdenv.mkDerivation {
  pname   = "companion-satellite";
  version = SAT_REV;

  src = pkgs.fetchFromGitHub {
    owner  = "bitfocus";
    repo   = "companion-satellite";
    rev    = SAT_REV;
    sha256 = SAT_SHA256;
  };

  nativeBuildInputs = [
    buildNode                        # npm for dependency installation
    pkgs.buildPackages.patchelf      # RPATH patching
  ];

  # npm writes to $HOME; give it a writable directory
  HOME = "$TMPDIR/npm-home";

  # Disable network in sandbox — all deps must come from the lock file.
  # If the build fails here, run with --option sandbox false once to fetch
  # node_modules, then update NPM_DEPS_HASH with the content hash.
  # (Alternatively, use node2nix to pin every npm dep in Nix properly.)
  buildPhase = ''
    export HOME="$TMPDIR/npm-home"
    mkdir -p "$HOME"

    echo "=== npm ci (offline) ==="
    # --prefer-offline prevents any network access; all deps must be in
    # package-lock.json and available in the npm cache snapshot.
    npm ci --ignore-scripts --prefer-offline
  '';

  installPhase = ''
    mkdir -p $out/opt/companion-satellite $out/bin $out/lib

    # ── Application source + node_modules ────────────────────────────────
    cp -r . $out/opt/companion-satellite/
    # Strip dev-only files to keep size down
    rm -rf $out/opt/companion-satellite/.git \
           $out/opt/companion-satellite/node_modules/.cache \
           $out/opt/companion-satellite/*.md \
           2>/dev/null || true

    # ── Target Node.js binary ─────────────────────────────────────────────
    # Find the real ELF (nixpkgs may wrap it in a shell shim on some systems)
    realNode=$(find ${targetNode}/bin -name '.node*-wrapped' 2>/dev/null | head -1)
    if [ -z "$realNode" ]; then
      realNode=$(readlink -f ${targetNode}/bin/node 2>/dev/null || echo "${targetNode}/bin/node")
    fi
    echo "=== target node ELF: $realNode ==="
    install -Dm755 "$realNode" $out/bin/node.bin

    # Patch ELF interpreter to use /lib/ld-musl-armhf.so.1 on target
    interp=$(patchelf --print-interpreter "$realNode" 2>/dev/null || true)
    echo "=== node interpreter: $interp ==="
    if [ -n "$interp" ] && [ -f "$interp" ]; then
      interpName=$(basename "$interp")
      install -Dm755 "$interp" "$out/lib/$interpName"
      patchelf --set-interpreter "/lib/$interpName" $out/bin/node.bin
      patchelf --set-rpath        "/lib"             $out/bin/node.bin
    fi

    # Bundle any shared libs node.bin needs
    copy_needed() {
      local elf="$1"
      local rpath
      rpath=$(patchelf --print-rpath "$elf" 2>/dev/null || true)
      patchelf --print-needed "$elf" 2>/dev/null | while read -r libname; do
        [ -f "$out/lib/$libname" ] && continue
        found=""
        for rdir in $(echo "$rpath" | tr ':' '\n'); do
          [ -z "$rdir" ] && continue
          candidate="$rdir/$libname"
          if [ -e "$candidate" ]; then
            found=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
            break
          fi
        done
        if [ -z "$found" ]; then
          found=$(find -L ${targetNode} \
            ${pkgs.zlib} \
            ${pkgs.openssl.out} \
            ${pkgs.stdenv.cc.cc.lib} \
            -name "$libname" -type f 2>/dev/null | head -1)
        fi
        if [ -n "$found" ] && [ -f "$found" ]; then
          install -Dm755 "$found" "$out/lib/$libname"
          patchelf --set-rpath "/lib" "$out/lib/$libname" 2>/dev/null || true
          copy_needed "$found"
        fi
      done
    }
    copy_needed "$realNode"

    # ── USB library (needed for Stream Deck etc.) ─────────────────────────
    # libusb is a runtime dep of the usb npm module.  Copy it if present.
    for libusbDir in ${pkgs.libusb1 or ""}/lib; do
      [ -d "$libusbDir" ] || continue
      for f in "$libusbDir"/libusb*.so*; do
        [ -e "$f" ] || continue
        install -Dm755 "$(readlink -f "$f")" "$out/lib/$(basename "$f")"
      done
    done

    # ── Launcher ─────────────────────────────────────────────────────────
    cat > $out/bin/companion-satellite << 'LAUNCHER'
#!/bin/sh
exec /bin/node.bin /opt/companion-satellite/dist/index.js "$@"
LAUNCHER
    chmod +x $out/bin/companion-satellite
  '';

  meta = {
    description = "Bitfocus Companion Satellite — peripheral client for Companion v3+";
    homepage    = "https://github.com/bitfocus/companion-satellite";
    license     = lib.licenses.mit;
  };
}
