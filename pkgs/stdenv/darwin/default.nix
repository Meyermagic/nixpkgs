{ lib
, localSystem, crossSystem, config, overlays

# Allow passing in bootstrap files directly so we can test the stdenv bootstrap process when changing the bootstrap tools
, bootstrapFiles ? let
  fetch = { file, sha256, executable ? true }: import <nix/fetchurl.nix> {
    url = "http://tarballs.nixos.org/stdenv-darwin/x86_64/c4effbe806be9a0a3727fdbbc9a5e28149347532/${file}";
    inherit (localSystem) system;
    inherit sha256 executable;
  }; in {
    sh      = fetch { file = "sh";    sha256 = "1b9r3dksj907bpxp589yhc4217cas73vni8sng4r57f04ydjcinr"; };
    bzip2   = fetch { file = "bzip2"; sha256 = "1wm28jgap4cbr8hf4ambg6h9flr2b4mcbh7fw20i0l51v6n8igky"; };
    mkdir   = fetch { file = "mkdir"; sha256 = "0jc32mzx2whhx2xh70grvvgz4jj26118p9yxmhjqcysagc0k7y66"; };
    cpio    = fetch { file = "cpio";  sha256 = "0x5dcczkzn0g8yb4pah449jmgy3nmpzrqy4s480grcx05b6v6hkp"; };
    tarball = fetch { file = "bootstrap-tools.cpio.bz2"; sha256 = "0ifdc8bwxdhmpbhx2vd3lwjg71gqm6pi5mfm0fkcsbqavl8hd8hz"; executable = false; };
  }
}:

assert crossSystem == null;

let
  inherit (localSystem) system platform;

  libSystemProfile = ''
    (import "${./standard-sandbox.sb}")
  '';
in rec {
  commonPreHook = ''
    export NIX_ENFORCE_PURITY="''${NIX_ENFORCE_PURITY-1}"
    export NIX_ENFORCE_NO_NATIVE="''${NIX_ENFORCE_NO_NATIVE-1}"
    export NIX_IGNORE_LD_THROUGH_GCC=1
    stripAllFlags=" " # the Darwin "strip" command doesn't know "-s"
    export MACOSX_DEPLOYMENT_TARGET=10.10
    export SDKROOT=
    export CMAKE_OSX_ARCHITECTURES=x86_64
    # Workaround for https://openradar.appspot.com/22671534 on 10.11.
    export gl_cv_func_getcwd_abort_bug=no
  '';

  # The one dependency of /bin/sh :(
  binShClosure = ''
    (allow file-read* (literal "/usr/lib/libncurses.5.4.dylib"))
  '';

  bootstrapTools = derivation rec {
    inherit system;

    name    = "bootstrap-tools";
    builder = bootstrapFiles.sh; # Not a filename! Attribute 'sh' on bootstrapFiles
    args    = [ ./unpack-bootstrap-tools.sh ];

    inherit (bootstrapFiles) mkdir bzip2 cpio tarball;

    __sandboxProfile = binShClosure + libSystemProfile;
  };

  stageFun = step: last: {shell             ? "${bootstrapTools}/bin/sh",
                          overrides         ? (self: super: {}),
                          extraPreHook      ? "",
                          extraBuildInputs,
                          allowedRequisites ? null}:
    let
      thisStdenv = import ../generic {
        inherit config shell extraBuildInputs allowedRequisites;

        name = "stdenv-darwin-boot-${toString step}";

        buildPlatform = localSystem;
        hostPlatform = localSystem;
        targetPlatform = localSystem;

        cc = if isNull last then "/dev/null" else import ../../build-support/cc-wrapper {
          inherit shell;
          inherit (last) stdenv;
          inherit (last.pkgs.darwin) dyld;

          nativeTools  = true;
          nativePrefix = bootstrapTools;
          nativeLibc   = false;
          libc         = last.pkgs.darwin.Libsystem;
          isClang      = true;
          cc           = { name = "clang-9.9.9"; outPath = bootstrapTools; };
        };

        preHook = stage0.stdenv.lib.optionalString (shell == "${bootstrapTools}/bin/sh") ''
          # Don't patch #!/interpreter because it leads to retained
          # dependencies on the bootstrapTools in the final stdenv.
          dontPatchShebangs=1
        '' + ''
          ${commonPreHook}
          ${extraPreHook}
        '';
        initialPath  = [ bootstrapTools ];

        fetchurlBoot = import ../../build-support/fetchurl {
          stdenv = stage0.stdenv;
          curl   = bootstrapTools;
        };

        # The stdenvs themselves don't use mkDerivation, so I need to specify this here
        stdenvSandboxProfile = binShClosure + libSystemProfile;
        extraSandboxProfile  = binShClosure + libSystemProfile;

        extraAttrs = { inherit platform; parent = last; };
        overrides  = self: super: (overrides self super) // { fetchurl = thisStdenv.fetchurlBoot; };
      };

    in {
      inherit config overlays;
      stdenv = thisStdenv;
    };

  stage0 = stageFun 0 null {
    overrides = self: super: with stage0; rec {
      darwin = super.darwin // {
        Libsystem = stdenv.mkDerivation {
          name = "bootstrap-Libsystem";
          buildCommand = ''
            mkdir -p $out
            ln -s ${bootstrapTools}/lib $out/lib
            ln -s ${bootstrapTools}/include-Libsystem $out/include
          '';
        };
        dyld = bootstrapTools;
      };

      libcxx = stdenv.mkDerivation {
        name = "bootstrap-libcxx";
        phases = [ "installPhase" "fixupPhase" ];
        installPhase = ''
          mkdir -p $out/lib $out/include
          ln -s ${bootstrapTools}/lib/libc++.dylib $out/lib/libc++.dylib
          ln -s ${bootstrapTools}/include/c++      $out/include/c++
        '';
        linkCxxAbi = false;
        setupHook = ../../development/compilers/llvm/3.9/libc++/setup-hook.sh;
      };

      libcxxabi = stdenv.mkDerivation {
        name = "bootstrap-libcxxabi";
        buildCommand = ''
          mkdir -p $out/lib
          ln -s ${bootstrapTools}/lib/libc++abi.dylib $out/lib/libc++abi.dylib
        '';
      };

    };

    extraBuildInputs = [];
  };

  persistent0 = _: _: _: {};

  stage1 = prevStage: with prevStage; stageFun 1 prevStage {
    extraPreHook = "export NIX_CFLAGS_COMPILE+=\" -F${bootstrapTools}/Library/Frameworks\"";
    extraBuildInputs = [ pkgs.libcxx ];

    allowedRequisites =
      [ bootstrapTools ] ++ (with pkgs; [ libcxx libcxxabi ]) ++ [ pkgs.darwin.Libsystem ];

    overrides = persistent0 prevStage;
  };

  persistent1 = prevStage: self: super: with prevStage; {
    inherit
      zlib patchutils m4 scons flex perl bison unifdef unzip openssl python
      libxml2 gettext sharutils gmp libarchive ncurses pkg-config libedit groff
      openssh sqlite sed serf openldap db cyrus-sasl expat apr-util subversion xz
      findfreetype libssh curl cmake autoconf automake libtool ed cpio coreutils;

    darwin = super.darwin // {
      inherit (darwin)
        dyld Libsystem xnu configd ICU libdispatch libclosure launchd;
    };
  };

  stage2 = prevStage: with prevStage; stageFun 2 prevStage {
    extraPreHook = ''
      export PATH_LOCALE=${pkgs.darwin.locale}/share/locale
    '';

    extraBuildInputs = with pkgs; [ xz darwin.CF libcxx ];

    allowedRequisites =
      [ bootstrapTools ] ++
      (with pkgs; [ xz.bin xz.out libcxx libcxxabi ]) ++
      (with pkgs.darwin; [ dyld Libsystem CF ICU locale ]);

    overrides = persistent1 prevStage;
  };

  persistent2 = prevStage: self: super: with prevStage; {
    inherit
      patchutils m4 scons flex perl bison unifdef unzip openssl python
      gettext sharutils libarchive pkg-config groff bash subversion
      openssh sqlite sed serf openldap db cyrus-sasl expat apr-util
      findfreetype libssh curl cmake autoconf automake libtool cpio
      libcxx libcxxabi;

    darwin = super.darwin // {
      inherit (darwin)
        dyld Libsystem xnu configd libdispatch libclosure launchd libiconv locale;
    };
  };

  stage3 = prevStage: with prevStage; stageFun 3 prevStage {
    shell = "${pkgs.bash}/bin/bash";

    # We have a valid shell here (this one has no bootstrap-tools runtime deps) so stageFun
    # enables patchShebangs above. Unfortunately, patchShebangs ignores our $SHELL setting
    # and instead goes by $PATH, which happens to contain bootstrapTools. So it goes and
    # patches our shebangs back to point at bootstrapTools. This makes sure bash comes first.
    extraBuildInputs = with pkgs; [ xz darwin.CF libcxx pkgs.bash ];

    extraPreHook = ''
      export PATH=${pkgs.bash}/bin:$PATH
      export PATH_LOCALE=${pkgs.darwin.locale}/share/locale
    '';

    allowedRequisites =
      [ bootstrapTools ] ++
      (with pkgs; [ xz.bin xz.out bash libcxx libcxxabi ]) ++
      (with pkgs.darwin; [ dyld ICU Libsystem locale ]);

    overrides = persistent2 prevStage;
  };

  persistent3 = prevStage: self: super: with prevStage; {
    inherit
      gnumake gzip gnused bzip2 gawk ed xz patch bash
      libcxxabi libcxx ncurses libffi zlib gmp pcre gnugrep
      coreutils findutils diffutils patchutils;

     llvmPackages = let llvmOverride = llvmPackages.llvm.override { inherit libcxxabi; };
     in super.llvmPackages // {
       llvm = llvmOverride;
       clang-unwrapped = llvmPackages.clang-unwrapped.override { llvm = llvmOverride; };
     };

    darwin = super.darwin // {
      inherit (darwin) dyld Libsystem libiconv locale;
    };
  };

  stage4 = prevStage: with prevStage; stageFun 4 prevStage {
    shell = "${pkgs.bash}/bin/bash";
    extraBuildInputs = with pkgs; [ xz darwin.CF libcxx pkgs.bash ];
    extraPreHook = ''
      export PATH_LOCALE=${pkgs.darwin.locale}/share/locale
    '';
    overrides = persistent3 prevStage;
  };

  persistent4 = prevStage: self: super: with prevStage; {
    inherit
      gnumake gzip gnused bzip2 gawk ed xz patch bash
      libcxxabi libcxx ncurses libffi zlib llvm gmp pcre gnugrep
      coreutils findutils diffutils patchutils;

    llvmPackages = super.llvmPackages // {
      inherit (llvmPackages) llvm clang-unwrapped;
    };

    darwin = super.darwin // {
      inherit (darwin) dyld ICU Libsystem cctools libiconv;
    };
  } // lib.optionalAttrs (super.targetPlatform == localSystem) {
    # Need to get rid of these when cross-compiling.
    inherit binutils binutils-raw;
  };

  stdenvDarwin = prevStage: let pkgs = prevStage; in import ../generic rec {
    inherit config;
    inherit (pkgs.stdenv) fetchurlBoot;

    name = "stdenv-darwin";

    buildPlatform = localSystem;
    hostPlatform = localSystem;
    targetPlatform = localSystem;

    preHook = commonPreHook + ''
      export PATH_LOCALE=${pkgs.darwin.locale}/share/locale
    '';

    stdenvSandboxProfile = binShClosure + libSystemProfile;
    extraSandboxProfile  = binShClosure + libSystemProfile;

    initialPath = import ../common-path.nix { inherit pkgs; };
    shell       = "${pkgs.bash}/bin/bash";

    cc = import ../../build-support/cc-wrapper {
      inherit (pkgs) stdenv;
      inherit shell;
      nativeTools = false;
      nativeLibc  = false;
      inherit (pkgs) coreutils binutils gnugrep;
      inherit (pkgs.darwin) dyld;
      cc   = pkgs.llvmPackages.clang-unwrapped;
      libc = pkgs.darwin.Libsystem;
    };

    extraBuildInputs = with pkgs; [ darwin.CF libcxx ];

    extraAttrs = {
      inherit platform bootstrapTools;
      libc         = pkgs.darwin.Libsystem;
      shellPackage = pkgs.bash;
    };

    allowedRequisites = (with pkgs; [
      xz.out xz.bin libcxx libcxxabi gmp.out gnumake findutils bzip2.out
      bzip2.bin llvmPackages.llvm llvmPackages.llvm.lib zlib.out zlib.dev libffi.out coreutils ed diffutils gnutar
      gzip ncurses.out ncurses.dev ncurses.man gnused bash gawk
      gnugrep llvmPackages.clang-unwrapped patch pcre.out binutils-raw.out
      binutils-raw.dev binutils gettext
    ]) ++ (with pkgs.darwin; [
      dyld Libsystem CF cctools ICU libiconv locale
    ]);

    overrides = self: super:
      let persistent = persistent4 prevStage self super; in persistent // {
        clang = cc;
        llvmPackages = persistent.llvmPackages // { clang = cc; };
        inherit cc;
      };
  };

  stagesDarwin = [
    ({}: stage0)
    stage1
    stage2
    stage3
    stage4
    (prevStage: {
      inherit config overlays;
      stdenv = stdenvDarwin prevStage;
    })
  ];
}
