# Known Issues

## iOS 27 beta — placeholder Home Screen icon on direct (cabled) development installs

On iOS 27 beta devices, an app installed directly from Xcode (development-signed,
cabled install) may show the correct app icon for a moment and then revert to the
default iOS placeholder grid icon on the Home Screen.

This is **not a project/asset problem**. It was isolated on the `85Blends Internal`
build with the following tests:

- Reverts even when the Internal configuration uses the production `AppIcon` asset
  (rules out the icon asset).
- Reverts even with a brand-new, never-installed bundle ID
  (`com.e85blends.app.ios.internal2`) — rules out the bundle ID / device icon cache.
- Simulator builds render the icon correctly — rules out the asset catalog,
  `Contents.json`, build settings, and signing inputs.
- The only on-device success is the App Store build, whose icons are re-rendered
  server-side during App Store / TestFlight processing.

**Cause:** iOS 27 beta SpringBoard / IconServices handling of development-signed
direct installs. Apple's server-side icon re-rendering never runs for a cabled
Xcode install.

**Guidance:** Use **TestFlight or App Store distribution** for reliable on-device
app-icon validation. Do **not** regenerate app icon assets in response to this
placeholder unless it also reproduces in a TestFlight or App Store build.
