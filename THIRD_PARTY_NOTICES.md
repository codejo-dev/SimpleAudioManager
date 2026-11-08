# Third-Party Notices

Simple Audio Manager is © 2026 codejo ([codejo.com](https://codejo.com)) and released under the [MIT License](LICENSE).
It uses the following open-source software. The full license texts ship inside the app (About page) and are kept in [`App/Resources/Licenses`](App/Resources/Licenses).

| Component | Author | Used for | License |
|---|---|---|---|
| [libASPL](https://github.com/gavv/libASPL) | Victor Gaydov and contributors | Foundation of the audio driver (`Vendor/libASPL`, compiled into the driver) | MIT, [text](App/Resources/Licenses/libASPL.txt) |
| └ Apple sample code in libASPL | Apple Inc. | Volume curve code (`VolumeCurve`, `VolumeRawPoint`, `VolumeDecibelPoint`) | Apple Sample Code License, [2012](App/Resources/Licenses/libASPL-Apple-2012.txt) and [2020](App/Resources/Licenses/libASPL-Apple-2020.txt) |
| [proxy-audio-device](https://github.com/briankendall/proxy-audio-device) | Brian Kendall | Design of the driver's clock servo (`Driver/Core/ClockServo.hpp`) | Unlicense (public domain), [text](App/Resources/Licenses/proxy-audio-device.txt) |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Yonas Kolb | Generates the Xcode project (build tool, not shipped) | MIT, [text](App/Resources/Licenses/XcodeGen.txt) |

Icons use Apple's SF Symbols, licensed by Apple for use on Apple platforms. The soundbar symbol is original to this project.
