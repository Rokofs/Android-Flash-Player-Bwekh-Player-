Save games for AS3 files played in AIR (src/fp/SoPatch.as).

When an AS3 game is opened, the player points the game's references to
flash.net.SharedObject and flash.external.ExternalInterface at the classes in bwekh/
and adds their compiled code to the SWF. Saves go to
  <app storage>/saves-as3/<file name>/   (*.amf, cookies.amf)

The compiled code is stored in SoPatch.as (SHIMS, base64 of each class's DoABC tag body
after the flags and name). After changing bwekh/*.as:
  1. acompc (AIR SDK) -source-path tools/so-shim
       -include-classes bwekh.SharedObject bwekh.ExternalInterface -output shim.swc
  2. unzip library.swf from shim.swc, take the ABC of every DoABC (code 82) tag,
     base64 it and put it into SHIMS.
The classes must not use flash.filesystem types directly (they look them up at run time).
