// Expected result on the macOS 26 SDK: importing the module succeeds, but
// referring to its API fails because the declarations are unavailable on macOS.

import WiFiAware

let supportedFeatures = WACapabilities.supportedFeatures
print(supportedFeatures)

