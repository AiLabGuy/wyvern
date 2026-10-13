# Third-party licenses

The app icon (assets/icon: wyvern-icon.svg, wyvern-icon-small.svg and their PNG renders, bundled as AppIcon.icns) is licensed CC-BY-4.0 by Wyvern Browser contributors; no trademark rights are granted. Created with Grok. Provenance is in ASSETS.md and the full license text is in LICENSES/CC-BY-4.0.txt. See TRADEMARKS.md.

## SwiftTerm

SwiftTerm 1.11.2
https://github.com/migueldeicaza/SwiftTerm
commit b1262db5b6bea699a8260a8c66999436c508ca56
GitHub tag archive sha256 dd4bd355903a900c0af66095c6c8d3cb5ec94cc4e6358af6e4aac033fce351b7
https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v1.11.2.tar.gz

The SwiftTerm library is MIT, which is compatible with this project's MIT license. The full license text follows.

Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

SwiftTerm 1.11.2 does not depend on swift-png. That package is Apache-2.0 and is used by unreleased development versions for non-Apple builds only. If a later pin adds swift-png and the checkout ships a NOTICE file, copy that NOTICE into this file.
swift-argument-parser is Apache-2.0. SwiftTerm uses it only in a command-line target, so a build that links the SwiftTerm library does not link it.
swift-docc-plugin is a build-time plugin.
package-benchmark is Apache-2.0 and is not linked. It is used only by the SwiftTerm benchmark target.
SwiftTerm 1.11.2 contains no Metal shader files. The library product is linked. The command-line targets, the benchmark target, and the docc plugin are not.
SwiftTerm bundles no font. Wyvern Browser uses the system monospace font and does not bundle a font.

No resolved third-party pins were found. Package.swift declares SwiftTerm exactly 1.11.2.
