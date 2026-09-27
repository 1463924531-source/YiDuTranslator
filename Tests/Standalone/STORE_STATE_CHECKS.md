# App state validation without Xcode

From the project directory run:

```sh
./Tests/Standalone/verify-store-state.sh
```

This uses the installed Swift compiler and live `AppStore.swift`, `AppSettings.swift`, `Models.swift` and `FavoritesStore.swift`. It does not require XCTest or additional dependencies. Only network, keychain, permission, document and OCR boundaries are replaced with deterministic in-memory test doubles. The production store's private OCR entry point is made internal in the temporary compilation copy so its replacement/cancellation behavior can be exercised; source files are not edited.

The checks cover direction swapping, obsolete translation completion, changed-source explanations, OCR replacement and image freshness, document cancellation/restart and configuration changes, original text preservation, key-test completion after key deletion, and the absence of automatically persisted history. Temporary files and UserDefaults are removed after each run. No real API request, saved credential, document or permission prompt is involved.
