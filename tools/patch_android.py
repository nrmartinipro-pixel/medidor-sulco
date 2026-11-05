"""Aplica as configurações do NOTAS_ANDROID.md no projeto gerado pelo `flutter create`.
Roda no GitHub Actions (ou localmente):  python tools/patch_android.py app
Funciona com build.gradle.kts (Flutter novo) e build.gradle (antigo)."""
import pathlib
import re
import sys

app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "app")
mod = app / "android" / "app"

# ---- gradle: minSdk 24 + dependências ARCore ----
kts, groovy = mod / "build.gradle.kts", mod / "build.gradle"
if kts.exists():
    g = kts.read_text()
    g = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 24", g)
    if "com.google.ar:core" not in g:
        g += ('\ndependencies {\n    implementation("com.google.ar:core:1.+")\n'
              '    implementation("androidx.core:core-ktx:1.13.1")\n}\n')
    kts.write_text(g)
elif groovy.exists():
    g = groovy.read_text()
    g = re.sub(r"minSdk(Version)?\s+[^\n]+", "minSdkVersion 24", g)
    if "com.google.ar:core" not in g:
        g += ("\ndependencies {\n    implementation 'com.google.ar:core:1.+'\n"
              "    implementation 'androidx.core:core-ktx:1.13.1'\n}\n")
    groovy.write_text(g)
else:
    sys.exit("build.gradle não encontrado: rode flutter create antes")

# ---- manifest: câmera + ARCore opcional ----
man = mod / "src" / "main" / "AndroidManifest.xml"
m = man.read_text()
if "android.permission.CAMERA" not in m:
    m = re.sub(r"(<manifest[^>]*>)", r'''\1
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-feature android:name="android.hardware.camera.ar" android:required="false" />
    <uses-feature android:glEsVersion="0x00020000" android:required="true" />''', m, count=1)
if "com.google.ar.core" not in m:
    m = re.sub(r"(<application[^>]*>)", r'''\1
        <meta-data android:name="com.google.ar.core" android:value="optional" />''', m, count=1)
m = re.sub(r'android:label="[^"]*"', 'android:label="Medidor de Sulco"', m, count=1)
man.write_text(m)
print("Android configurado:", kts if kts.exists() else groovy, man)
