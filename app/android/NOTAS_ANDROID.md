# Configuração Android

Rode `flutter create --platforms=android,ios .` dentro de `app/` para gerar o
restante do projeto nativo, depois aplique o que está abaixo. Os arquivos
Kotlin deste repositório substituem o `MainActivity.kt` gerado.

## android/app/build.gradle

```gradle
android {
    defaultConfig {
        minSdkVersion 24          // ARCore exige Android 7.0+
    }
}
dependencies {
    // Use a versão mais recente publicada em https://developers.google.com/ar
    implementation "com.google.ar:core:<versão>"
    implementation "androidx.core:core-ktx:1.13.1"
}
```

## android/app/src/main/AndroidManifest.xml

```xml
<uses-permission android:name="android.permission.CAMERA" />
<!-- ARCore opcional: o modo Laser funciona em qualquer aparelho -->
<uses-feature android:name="android.hardware.camera.ar" android:required="false" />
<uses-feature android:glEsVersion="0x00020000" android:required="true" />

<application ...>
    <meta-data android:name="com.google.ar.core" android:value="optional" />
</application>
```

`isSupported` retorna `false` em aparelhos fora da lista da Depth API; o
botão ToF/LiDAR fica desabilitado e o app segue só no modo Laser.
