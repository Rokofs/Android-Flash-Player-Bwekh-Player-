Text Layout Framework 1.0 (build 595) for Flash CS5 games with TLF text fields
==========================================================================

Flash Professional CS5 games with TLF text load the framework at start as a signed RSL:
http://fpdownload.adobe.com/pub/swz/tlf/1.0.0.595/textLayout_1.0.0.595.swz
(with a preloader class MainTimeline__Preloader__ / fl.rsl.RSLPreloader). That server is
gone or unreachable (and Android blocks plain http), so such games stayed blank.

src/fp/assets/textLayout_1.0.0.595.swf is that framework built from source:
Apache Flex TLF, branch 1.0 (https://github.com/apache/flex-tlf, BuildInfo.kBuildNumber "595"),
packages textLayout_core + textLayout_conversion + textLayout_edit, CONFIG::debug=false,
CONFIG::release=true. Sources: tools/tlf/src (Apache License 2.0, see src/LICENSE and NOTICE).
root/TlfAll.as references every public definition, so one SWF holds the whole framework.

build-tlf.ps1 compiles it with the AIR SDK's own compiler (amxmlc); tools/desktop/run.ps1 runs it
once (air-built.txt marks that) and it replaces the file in src/fp/assets. Build the APK after that.

The file shipped before that was made in the cloud with the Apache Royale compiler (one ABC block),
then fix_interfaces.py: Royale writes a class's interfaces as QNames, Flash/Flex compilers as
Multiname(name, [namespace]). A first build with one ABC block per class failed in AIR with
"#1034: cannot convert  to flashx.textLayout.compose.ISWFContext" (an object of a class not
accepted as its own interface).

The player (src/fp/TlfLibrary.as, PlayerScreen.prepareLibDomain) loads it into a domain the
game's domain is a child of, and changes "http://fpdownload..." in the game to "bwkh://..." (same
length) so the preloader fails at once instead of waiting on the network, then goes on with ours.
