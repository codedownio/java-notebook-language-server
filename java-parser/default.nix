# The snippet classifier that java-notebook-language-server shells out to.
#
# Built from source rather than shipped as a release artifact, because it needs a JDK at
# runtime anyway: whoever packages this already has one, and the jar is a few kilobytes next to
# the JDK's hundreds of megabytes.
{ lib
, stdenvNoCC
, jdk
, makeWrapper
}:

stdenvNoCC.mkDerivation {
  pname = "java-parser";
  version = "0.1.0.0";

  src = ./src;

  nativeBuildInputs = [jdk makeWrapper];

  buildPhase = ''
    runHook preBuild

    mkdir -p classes
    javac -d classes JavaParser.java
    jar --create --file java-parser.jar --main-class JavaParser -C classes .

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/java
    cp java-parser.jar $out/share/java/

    # Only the public jdk.jshell API is used, so no --add-opens and no module path games.
    makeWrapper ${jdk}/bin/java $out/bin/java-parser \
      --add-flags "-jar $out/share/java/java-parser.jar"

    runHook postInstall
  '';

  meta = {
    description = "Splits a Java notebook document into JShell snippets and classifies them";
    homepage = "https://github.com/codedownio/java-notebook-language-server";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
    mainProgram = "java-parser";
  };
}
