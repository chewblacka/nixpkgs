{
  lib,
  stdenv,
  runCommand,
  fetchzip,
  fetchurl,
  fetchpatch,
  fetchFromGitHub,
  cmake,
  jbig2dec,
  libjpeg_turbo,
  libpng,
  makeWrapper,
  pkg-config,
  zlib,
  enableGSL ? true,
  gsl,
  enableGhostScript ? true,
  ghostscript,
  enableMuPDF ? true,
  mupdf,
  enableDJVU ? true,
  djvulibre,
  enableGOCR ? false, # Disabled by default due to crashes
  gocr,
  # Tesseract support is currently broken
  # See: https://github.com/NixOS/nixpkgs/issues/368349
  enableTesseract ? false,
  tesseract5,
  enableLeptonica ? true,
  leptonica,
  opencl-headers,
  fetchDebianPatch,
}:

# k2pdfopt is a pain to package. It requires modified versions of mupdf,
# leptonica, and tesseract.  Instead of shipping patches for these upstream
# packages, k2pdfopt includes just the modified source files for these
# packages.  The individual files from the {mupdf,leptonica,tesseract}_mod/
# directories are intended to replace the corresponding source files in the
# upstream packages, for a particular version of that upstream package.
#
# There are a few ways we could approach packaging these modified versions of
# mupdf, leptonica, and mupdf:
# 1) Override the upstream source with a new derivation that involves copying
# the modified source files from k2pdfopt and replacing the corresponding
# source files in the upstream packages. Since the files are intended for a
# particular version of the upstream package, this would not allow us to easily
# use updates to those packages in nixpkgs.
# 2) Manually produce patches which can be applied against the upstream
# project, and have the same effect as replacing those files.  This is what I
# believe k2pdfopt should do this for us anyway.  The benefit of creating and
# applying patches in this way is that minor updates (esp. security fixes) to
# upstream packages might still allow these patches to apply successfully.
# 3) Automatically produce these patches inside a nix derivation. This is the
# approach taken here, using the "mkPatch" provided below.  This has the
# benefit of easier review and should hopefully be simpler to update in the
# future.

let
  # Create a patch against src based on changes applied in patchCommands
  mkPatch =
    {
      name,
      src,
      patchCommands,
    }:
    runCommand "${name}-k2pdfopt.patch" { inherit src; } ''
      unpackPhase

      orig=$sourceRoot
      new=$sourceRoot-modded
      cp -r $orig/. $new/

      pushd $new >/dev/null
      ${patchCommands}
      popd >/dev/null

      diff -Naur $orig $new > $out || true
    '';

  pname = "k2pdfopt";
  version = "2.55";
  k2pdfopt_src = fetchzip {
    url = "http://www.willus.com/${pname}/src/${pname}_v${version}_src.zip";
    hash = "sha256-orQNDXQkkcCtlA8wndss6SiJk4+ImiFCG8XRLEg963k=";
  };
in
stdenv.mkDerivation rec {
  inherit pname version;
  src = k2pdfopt_src;

  patches = [
    ./0001-Fix-CMakeLists.patch
    (fetchDebianPatch {
      inherit pname;
      version = "${version}+ds";
      debianRevision = "3.1";
      patch = "0007-k2pdfoptlib-k2ocr.c-conditionally-enable-tesseract-r.patch";
      hash = "sha256-uJ9Gpyq64n/HKqo0hkQ2dnkSLCKNN4DedItPGzHfqR8=";
    })
    (fetchDebianPatch {
      inherit pname;
      version = "${version}+ds";
      debianRevision = "3.1";
      patch = "0009-willuslib-CMakeLists.txt-conditionally-add-source-fi.patch";
      hash = "sha256-cBSlcuhsw4YgAJtBJkKLW6u8tK5gFwWw7pZEJzVMJDE=";
    })
  ];

  postPatch = ''
    substituteInPlace willuslib/bmpdjvu.c \
      --replace "<djvu.h>" "<libdjvu/ddjvuapi.h>"
  '';

  nativeBuildInputs = [
    cmake
    pkg-config
    makeWrapper
  ];

  buildInputs =
    let
      # We use specific versions of these sources below to match the versions
      # used in the k2pdfopt source. Note that this does _not_ need to match the
      # version used elsewhere in nixpkgs, since it is only used to create the
      # patch that can then be applied to the version in nixpkgs.
      mupdf_patch = mkPatch {
        name = "mupdf";
        src = fetchurl {
          url = "https://mupdf.com/downloads/archive/mupdf-1.23.7-source.tar.gz";
          hash = "sha256-NaVJM/QA6JZnoImkJfHGXNadRiOU/tnAZ558Uu+6pWg=";
        };
        patchCommands = ''
          cp ${k2pdfopt_src}/mupdf_mod/{filter-basic,font,stext-device,string}.c ./source/fitz/
          cp ${k2pdfopt_src}/mupdf_mod/pdf-* ./source/pdf/
        '';
      };
      # mupdf_patch no longer applies cleanly against mupdf 1.25.0 or later, due to a conflicting
      # hunk (mupdf_conflict) introduced in commit bd8d337939f36f55b96cb6984f5c7bbf2f488ce0 of mupdf.
      # This merge conflict can be resolved as desired by reverting mupdf_conflict, applying mupdf_patch,
      # and finally reapplying mupdf_conflict, with an increased fuzz factor (see mupdf_modded below).
      # TODO: remove workaround with conflicting hunk when mupdf in k2pdfopt is updated to 1.25.0 or later
      mupdf_conflict =
        hash: revert:
        fetchpatch {
          name = "mupdf-conflicting-hunk" + (lib.optionalString revert "-reverted") + ".patch";
          url = "https://github.com/ArtifexSoftware/mupdf/commit/bd8d337939f36f55b96cb6984f5c7bbf2f488ce0.patch";
          inherit hash revert;
          includes = [ "source/fitz/stext-device.c" ];
          postFetch = ''
            filterdiff -#6 "$out" > "$tmpfile"
            mv "$tmpfile" "$out"
          '';
        };
      mupdf_modded = mupdf.overrideAttrs (
        {
          patches ? [ ],
          ...
        }:
        {
          # The fuzz factor is increased to automatically resolve the merge conflict.
          patchFlags = [
            "-p1"
            "-F3"
          ];
          # Reverting and reapplying the conflicting hunk is necessary, otherwise the result will be faulty.
          patches = patches ++ [
            # revert conflicting hunk
            (mupdf_conflict "sha256-24tl9YBuZBYhb12yY3T0lKsA7NswfK0QcMYhb2IpepA=" true)
            # apply modifications
            mupdf_patch
            # reapply conflicting hunk
            (mupdf_conflict "sha256-bnBV7LyX1w/BXxBFF1bkA8x+/0I9Am33o8GiAeEKHYQ=" false)
          ];
          # This function is missing in font.c, see font-win32.c
          postPatch = ''
            echo "void pdf_install_load_system_font_funcs(fz_context *ctx) {}" >> source/fitz/font.c
          '';
        }
      );

      leptonica_patch = mkPatch {
        name = "leptonica";
        src = fetchurl {
          url = "http://www.leptonica.org/source/leptonica-1.83.0.tar.gz";
          hash = "sha256-IGWR3VjPhO84CDba0TO1jJ0a+SSR9amCXDRqFiBEvP4=";
        };
        patchCommands = "cp -r ${k2pdfopt_src}/leptonica_mod/. ./src/";
      };
      leptonica_modded = leptonica.overrideAttrs (
        {
          patches ? [ ],
          ...
        }:
        {
          patches = patches ++ [ leptonica_patch ];
        }
      );

      tesseract_patch = mkPatch {
        name = "tesseract";
        src = fetchFromGitHub {
          owner = "tesseract-ocr";
          repo = "tesseract";
          rev = "5.3.3";
          hash = "sha256-/aGzwm2+0y8fheOnRi/OJXZy3o0xjY1cCq+B3GTzfos=";
        };
        patchCommands = ''
          cp ${k2pdfopt_src}/tesseract_mod/tesseract.* include/tesseract/
          cp ${k2pdfopt_src}/tesseract_mod/tesseract/baseapi.h include/tesseract/
          cp ${k2pdfopt_src}/tesseract_mod/{baseapi,config_auto,tesscapi,tesseract}.* src/api/
          cp ${k2pdfopt_src}/tesseract_mod/tesseract/baseapi.h src/api/
          cp ${k2pdfopt_src}/tesseract_mod/{tesscapi,tessedit,tesseract}.* src/ccmain/
          cp ${k2pdfopt_src}/tesseract_mod/tesseract/baseapi.h src/ccmain/
          cp ${k2pdfopt_src}/tesseract_mod/dotproduct{avx,fma,sse}.* src/arch/
          cp ${k2pdfopt_src}/tesseract_mod/{intsimdmatrixsse,simddetect}.* src/arch/
          cp ${k2pdfopt_src}/tesseract_mod/{errcode,genericvector,mainblk,params,serialis,tessdatamanager,tess_version,tprintf,unicharset}.* src/ccutil/
          cp ${k2pdfopt_src}/tesseract_mod/{input,lstmrecognizer}.* src/lstm/
          cp ${k2pdfopt_src}/tesseract_mod/openclwrapper.* src/opencl/
        '';
      };
      tesseract_modded = tesseract5.override {
        tesseractBase = tesseract5.tesseractBase.overrideAttrs (
          {
            patches ? [ ],
            buildInputs ? [ ],
            ...
          }:
          {
            pname = "tesseract-k2pdfopt";
            version = tesseract_patch.src.rev;
            src = tesseract_patch.src;
            # opencl-headers were removed from tesseract in Version 5.4
            buildInputs = buildInputs ++ [ opencl-headers ];
            patches = patches ++ [ tesseract_patch ];
            # Additional compilation fixes
            postPatch = ''
              echo libtesseract_la_SOURCES += src/api/tesscapi.cpp >> Makefile.am
              substituteInPlace src/api/tesseract.h \
                --replace "#include <leptonica.h>" "//#include <leptonica.h>"
              substituteInPlace include/tesseract/tesseract.h \
                --replace "#include <leptonica.h>" "//#include <leptonica.h>"
            '';
          }
        );
      };
    in
    [
      jbig2dec
      libjpeg_turbo
      libpng
      zlib
    ]
    ++ lib.optional enableGSL gsl
    ++ lib.optional enableGhostScript ghostscript
    ++ lib.optional enableMuPDF mupdf_modded
    ++ lib.optional enableDJVU djvulibre
    ++ lib.optional enableGOCR gocr
    ++ lib.optional enableTesseract tesseract_modded
    ++ lib.optional (enableLeptonica || enableTesseract) leptonica_modded;

  dontUseCmakeBuildDir = true;

  cmakeFlags = [ "-DCMAKE_C_FLAGS=-I${src}/include_mod" ];

  NIX_LDFLAGS = "-lpthread";

  installPhase = ''
    install -D -m 755 k2pdfopt $out/bin/k2pdfopt
  '';

  preFixup = lib.optionalString enableTesseract ''
    wrapProgram $out/bin/k2pdfopt --set-default TESSDATA_PREFIX ${tesseract5}/share/tessdata
  '';

  meta = with lib; {
    description = "Optimizes PDF/DJVU files for mobile e-readers (e.g. the Kindle) and smartphones";
    homepage = "http://www.willus.com/k2pdfopt";
    changelog = "https://www.willus.com/k2pdfopt/k2pdfopt_version.txt";
    license = licenses.gpl3;
    platforms = platforms.linux;
    maintainers = with maintainers; [
      bosu
      danielfullmer
    ];
  };
}
