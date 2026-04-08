# Replace "export/ios/"  with the path where the android build is stored

chmod +x ./export/release/ios/upload-symbols
./export/release/ios/upload-symbols -gsp ./setup/GoogleService-Info.plist -p ios  ./export/release/ios/build/Release-iphoneos/PSliceEngine.app.dSYM