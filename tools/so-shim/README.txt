Save games for AS3 files played in AIR (src/fp/SoPatch.as).

When an AS3 game is opened, the player points the game's references to
flash.net.SharedObject and flash.external.ExternalInterface at the classes in bwekh/
and adds their compiled code to the SWF. A game that fails with #1009 because its main class uses "stage" in its constructor
is started again with those look-ups reading bwekh.appStage (the player's stage). Saves go to
  <app storage>/saves-as3/<file name>/   (*.amf, cookies.amf)

The compiled code is stored in SoPatch.as (SHIMS, base64 of each class's DoABC tag body
after the flags and name). After changing bwekh/*.as:
  1. acompc (AIR SDK) -source-path tools/so-shim
       -include-classes bwekh.SharedObject bwekh.ExternalInterface
       bwekh.MovieClipBase bwekh.SpriteBase
       bwekh.MovieClipPlain bwekh.SpritePlain bwekh.appStage -output shim.swc
  2. unzip library.swf from shim.swc, take the ABC of every DoABC (code 82) tag,
     base64 it and put it into SHIMS.
The classes must not use flash.filesystem types directly (they look them up at run time).

bwekh/Protos.as is not in SHIMS: it is compiled on its own (acompc ... -include-classes bwekh.Protos)
and its ABC, base64, is GameCoords.PROTOS. GameCoords puts it in front of a game's code when it renames
calls in it (localToGlobal, globalToLocal, hitTestPoint, appendBytes): a loaded game has its own copies of
the built-in classes, so the prototypes the renamed calls need are set from inside the game.
