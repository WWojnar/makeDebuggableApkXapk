# makeDebuggable

Patch Android packages so the app becomes debuggable by setting `android:debuggable="true"` in the binary `AndroidManifest.xml`.

The project supports:

- plain APK files
- extracted split-package directories
- XAPK files

The core implementation lives in `makeDebuggable.py`.

`make_xapk_debuggable.ps1` is a thin Windows/PowerShell wrapper around the Python pipeline. It does not maintain a separate patching implementation.

## Why this tool exists

Many existing Android tools can rebuild a manifest, but they often do a lot more work than needed. This project patches the binary manifest directly and keeps the rest of the APK as intact as possible.

That matters because it:

- minimizes package changes
- avoids unnecessary resource rebuilds
- works better with obfuscated apps
- avoids apktool-style manifest/resource round-trip issues in the normal path

## What it does

For a plain APK:

1. Patches the binary manifest.
2. Writes a new APK.
3. Runs `zipalign`.
4. Re-signs the APK with your chosen keystore.

For split APK / XAPK packages:

1. Detects the base APK.
2. Patches only the base APK manifest.
3. Re-signs every APK in the split set with the same certificate.
4. Produces an installable split set for `adb install-multiple`.

## Minimum Requirements

Required everywhere:

- Python 3
- `zipalign`
- `apksigner`
- a keystore for signing, or `keytool` if you want the PowerShell wrapper to generate one

Optional:

- PowerShell, if you want to use the Windows wrapper

Not required for the normal patching path:

- `apktool`
- Java, except when generating a keystore with `keytool`

## Python Usage

### Show help

```bash
python3 makeDebuggable.py --help
```

On Windows, if `python` is ambiguous, call the interpreter explicitly:

```powershell
& "C:\path\to\python.exe" .\makeDebuggable.py --help
```

### Patch a plain APK

```bash
python3 makeDebuggable.py apk input.apk output.apk keystore.jks alias password
```

If `zipalign` and `apksigner` are not already on `PATH`, pass them explicitly:

```bash
python3 makeDebuggable.py apk input.apk output.apk keystore.jks alias password \
  --zipalign /path/to/zipalign \
  --apksigner /path/to/apksigner
```

### Patch an extracted split-package directory

```bash
python3 makeDebuggable.py split input_dir output_dir keystore.jks alias password
```

If the base APK cannot be determined automatically, add:

```bash
--base-apk base.apk
```

### Patch an XAPK

```bash
python3 makeDebuggable.py xapk app.xapk output_dir keystore.jks alias password
```

### Patch only the binary manifest

```bash
python3 makeDebuggable.py xml AndroidManifest.xml AndroidManifest.patched.xml
```

## PowerShell Usage

`make_xapk_debuggable.ps1` is intended for Windows users who want a friendlier wrapper and local config file.

### 1. Create a local config

Copy:

- `makeDebuggable.config.example.psd1`

to:

- `makeDebuggable.config.psd1`

That local config is git-ignored and is where you should keep machine-specific paths and secrets.

Example config values:

```powershell
@{
    PythonPath = "C:\Users\you\AppData\Local\Programs\Python\Python310\python.exe"
    KeystorePath = "C:\path\to\debuggable.keystore"
    KeyAlias = "debuggable"
    KeystorePassword = "change-me"
    ZipalignPath = "C:\Android\build-tools\36.0.0\zipalign.exe"
    ApksignerPath = "C:\Android\build-tools\36.0.0\apksigner.bat"
    KeytoolPath = "C:\Program Files\Java\jdk-17\bin\keytool.exe"
}
```

### 2. Run the wrapper

For an APK:

```powershell
powershell -ExecutionPolicy Bypass -File .\make_xapk_debuggable.ps1 `
  -InputPath .\app.apk `
  -OutputPath .\app-debuggable.apk
```

For an extracted split-package directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\make_xapk_debuggable.ps1 `
  -InputPath .\xapk_extracted `
  -OutputPath .\signed_splits
```

For an XAPK:

```powershell
powershell -ExecutionPolicy Bypass -File .\make_xapk_debuggable.ps1 `
  -InputPath .\app.xapk `
  -OutputPath .\signed_splits
```

You can also override config values directly on the command line:

```powershell
powershell -ExecutionPolicy Bypass -File .\make_xapk_debuggable.ps1 `
  -InputPath .\app.xapk `
  -OutputPath .\signed_splits `
  -PythonPath "C:\Users\you\AppData\Local\Programs\Python\Python310\python.exe" `
  -KeystorePath "C:\path\to\debuggable.keystore"
```

## Installing the Result

### Plain APK

```bash
adb install output.apk
```

If the original app is already installed with a different signing key, uninstall it first:

```bash
adb uninstall com.example.app
adb install output.apk
```

### Split APK / XAPK output

Install all APKs together:

```bash
adb install-multiple output_dir/*.apk
```

On PowerShell, using file expansion is often easier than listing every split manually:

```powershell
$apks = Get-ChildItem .\signed_splits\*.apk | Sort-Object Name | ForEach-Object { $_.FullName }
adb install-multiple @apks
```

## Requirements Notes

### Signing matters

Android requires all APKs in a split install set to be signed with the same certificate.

That means:

- patch the base APK
- re-sign every split APK with the same keystore
- install the whole set together

### Existing installs

If the device already has the vendor-signed app installed, Android will reject your newly signed output. Uninstall the original package first unless you are signing with the same original certificate.

### Why PowerShell wraps Python

The binary manifest patcher is the hard part and already exists in Python. Reimplementing that byte-level logic in PowerShell would add complexity and risk without improving portability much.

So the design is:

- Python owns the patching logic
- PowerShell owns local configuration and Windows-friendly invocation

## Docker

You can still build and run the Python tool in Docker for single-APK workflows:

```bash
docker build -t makedebuggable --build-arg UID=`id -u` --build-arg GID=`id -g` .
docker run -it --rm -v $PWD:/home/makedebuggable -u makedebuggable makedebuggable ./keygen.sh
docker run -it --rm -v $PWD:/home/makedebuggable -u makedebuggable makedebuggable \
  ./makeDebuggable.py apk app.apk app-debuggable.apk debuggable.keystore debuggable pwpwpw
```

## Publishing / Local Secrets

Do not commit:

- your local `makeDebuggable.config.psd1`
- generated keystores you do not want to share
- generated APK outputs

The repository already ignores the local PowerShell config and common build artifacts.
