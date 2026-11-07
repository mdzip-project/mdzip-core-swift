# Testing on a Mac, the iOS Simulator and an iPhone

The tests run the specification's fixtures (bundled with the tests) and the library's own checks. GitHub runs them on Linux, macOS and the iOS Simulator on every push (`.github/workflows/ci.yml`). This guide runs them yourself on a Mac, in the iOS Simulator, or on your own iPhone.

## 1. Set up the Mac (once)

1. Install **Xcode** from the Mac App Store (it's large, about 10 GB or more), open it once, and let it install its extra components. When it asks which platforms to add, include **iOS**.
2. Open **Terminal** (Applications → Utilities) and get the code:

   ```sh
   git clone https://github.com/mdzip-project/mdzip-core-swift.git
   cd mdzip-core-swift
   ```

   If macOS asks to install the command line developer tools, accept.

## 2. Run the tests on the Mac

```sh
swift test
```

The last lines should say `Executed 41 tests, with 1 test skipped and 0 failures`. (The skipped test writes sample archives only when `MDZIP_OUT` is set.)

## 3. Run the tests in the iOS Simulator

From Terminal, in the same folder:

```sh
xcodebuild -list
xcodebuild test -scheme MDZip-Package -destination 'platform=iOS Simulator,name=iPhone 16'
```

- Use the scheme `xcodebuild -list` shows: `MDZip-Package` if it's listed, otherwise `MDZip`.
- Use any iPhone simulator Xcode has. `xcrun simctl list devices available` lists them; replace `iPhone 16` with one of those names.

The output ends with `** TEST SUCCEEDED **` when everything passes.

Or in Xcode: **File → Open**, choose the `mdzip-core-swift` folder (Xcode opens `Package.swift`), pick the scheme and an iPhone simulator in the toolbar at the top, then **Product → Test** (⌘U). Results appear in the Test navigator (the diamond icon on the left).

## 4. Run the tests on your iPhone

1. Connect the iPhone to the Mac with a cable, unlock it and tap **Trust** when it asks to trust the computer.
2. In Xcode, add your Apple ID under **Xcode → Settings → Accounts** if it isn't there. A free Apple ID is enough for running tests on your own phone.
3. Open the package in Xcode as in step 3 and choose your iPhone as the destination in the toolbar.
4. iOS 16 and later: the first time, the iPhone asks you to turn on **Developer Mode** (**Settings → Privacy & Security → Developer Mode**). It restarts; confirm when it comes back.
5. **Product → Test** (⌘U). The first run takes a little longer while Xcode prepares the phone.

If Xcode can't sign the tests for the device (a "Signing for … requires a development team" message), the package needs a small host app to run on a device. Tell us, and we'll add one.

## 5. Reporting results

Give the device (Mac model, simulator name, or iPhone model) and the iOS or macOS version, and either "all passed" or the name and message of each failing test. In Xcode, right-click a failure in the Test navigator to copy it; in Terminal, copy the lines with `error:` or `failed`.
