<!-- What changes, and why. Link the issue: "Closes #…". -->

## Checklist

- [ ] `Scripts/build.sh --unsigned` builds; a signed build was run on a Mac (`Scripts/build.sh --install`) when the change touches HomeKit, TLS or pairing
- [ ] No token, pairing code or key is logged; tokens are kept only as their SHA-256
- [ ] The README says what changed for the API, the menu or the window
- [ ] Panel changes: the tabs were looked at in dark and light (`Scripts/test.sh /tmp/wingman-snapshots`, or the CI artifact)
