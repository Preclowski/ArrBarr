import Testing

/// Suites that write process-wide switches (`AppCapabilities.isAppStore`, the Keychain probe override) nest here: `.serialized` runs them one after another, not only
/// their own tests, so one suite cannot flip a switch under the other's assertion.
@Suite(.serialized) struct ProcessGlobalsSuite {}
