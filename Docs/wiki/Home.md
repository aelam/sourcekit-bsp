# sourcekit-bsp Wiki

A BSP server for Xcode projects. These pages cover the current source tree.

- [[Getting started|Getting-Started]]: build and editor setup.
- [[Build, run, test, and debug|Build-Run-Test-Debug]]: commands and destinations.
- [[Indexing and paths|Indexing-and-Paths]]: preparation and DerivedData.
- [[Protocol support|Protocol-Support]]: methods, extensions, and limitations.
- [[Troubleshooting|Troubleshooting]]: connection, navigation, and build failures.

| Component | Role |
| --- | --- |
| sourcekit-bsp | Xcode targets, compiler settings, and build operations |
| SourceKit-LSP | Completion, diagnostics, definitions, and references |
| A BSP client, such as vscode-bsp | Target selection and build/run/test/debug controls |

SourceKit-LSP and a build UI can use separate BSP connections. Configure both
with the intended executable and Xcode installation.
