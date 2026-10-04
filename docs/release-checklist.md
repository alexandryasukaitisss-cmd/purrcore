# Before a stable binary release

- [x] Core suite: 52 tests and a local release build on Apple Silicon.
- [x] Pet import, persistence, reset and running toggle tested in the rendered app.
- [x] MacBook battery operation, discharge estimates and awake-time tracking confirmed by the owner on 2026-10-04.
- [x] Russian/English localization and named accessibility labels implemented. English settings inspected in the rendered app.
- [x] Battery retention defaults to indefinite storage; boundary and active-session behavior tested. The rendered confirmation and cancellation were checked in an isolated data directory.
- [ ] Verify retention apply and restart, both appearances, VoiceOver and system Reduce Motion in the rendered app.
- [ ] Run the prepared CI on the declared macOS and Intel runners.
- [ ] Benchmark CPU, memory and energy with default and imported animations.
- [ ] Sign with Developer ID Application, notarize and check installation on a clean Mac. An ad-hoc build is not notarized.
- [ ] Generate and import a new pet animation through an available Codex image tool. The prepared-frame import test does not verify fresh generation or animal resemblance.

No other pet artwork is required for the current version: users can import any pet.
