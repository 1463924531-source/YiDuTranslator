# App state validation without Xcode

From the project directory run:

```sh
./Tests/Standalone/verify-store-state.sh
```

This uses the installed Swift compiler and live `AppStore.swift`, `AppSettings.swift`, `Models.swift` and `FavoritesStore.swift`. It does not require XCTest or additional dependencies. Network, keychain, permission, selection, clipboard, document and OCR boundaries are replaced with deterministic in-memory test doubles. The selection double records the synchronous WPS compatibility snapshot, keeps asynchronous reads pending until explicitly resumed, and checks cancellation only after the pending read finishes. A local `NSPasteboard` stand-in counts string reads and holds synthetic text; the checks never access the real macOS clipboard. The production store's private OCR entry point is made internal in the temporary compilation copy so its replacement/cancellation behavior can be exercised; source files are not edited.

The checks cover direction swapping, obsolete translation completion, changed-source explanations, OCR replacement and image freshness, document cancellation/restart and configuration changes, original text preservation, key-test completion after key deletion, and the absence of automatically persisted history. Shortcut checks cover delayed selection resolution before any result window or model request, forwarding the WPS compatibility switch, ignoring repeated shortcuts while one read is active, accepting a later shortcut after completion, opening manual input without selection when selection is disabled, and discarding delayed reads after clear, manual input edits or shutdown. Additional checks ensure that an active screenshot blocks a selection shortcut, and that paste during pending selection cleanup neither reads the clipboard nor replaces manual input; paste succeeds after cleanup. Temporary files and UserDefaults are removed after each run. No real API request, saved credential, document or permission prompt is involved.
