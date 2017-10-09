{ mkDerivation, aeson, base, bytestring, containers, dependent-sum
, hashable, http-api-data, mtl, network, primitive, ref-tf, reflex
, reflex-basic-host, reflex-dom-core, servant, servant-server
, stdenv, stm, these, transformers, ttrie, wai, warp
}:
mkDerivation {
  pname = "servant-reflex-server";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base bytestring containers dependent-sum hashable
    http-api-data mtl network primitive ref-tf reflex reflex-basic-host
    servant servant-server stm ttrie wai
  ];
  executableHaskellDepends = [
    base containers dependent-sum hashable http-api-data mtl ref-tf
    reflex reflex-basic-host reflex-dom-core servant servant-server stm
    these transformers wai warp
  ];
  license = stdenv.lib.licenses.bsd3;
}
