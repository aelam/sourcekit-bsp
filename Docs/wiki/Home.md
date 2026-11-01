# sourcekit-bsp Wiki

sourcekit-bsp is a Build Server Protocol server for Xcode projects. It supplies
project metadata and compiler arguments to SourceKit-LSP, and supports Xcode
compile, run, test, and debug requests from BSP clients.

These pages describe the current source tree. Older releases may provide fewer
features. Clients should inspect initialization and target capabilities.

- [[Getting started|Getting-Started]]: installation, executable selection, and editor setup.
- [[Build, run, test, and debug|Build-Run-Test-Debug]]: commands and simulator destinations.
- [[Indexing and paths|Indexing-and-Paths]]: preparation, background indexing, and DerivedData.
- [[Protocol support|Protocol-Support]]: methods, extensions, refresh, cancellation, and remaining work.
- [[Troubleshooting|Troubleshooting]]: connection, navigation, build, and test problems.

## Which component does what?

| Component | Role |
| --- | --- |
| sourcekit-bsp | Exposes Xcode targets, compiler settings, and build operations |
| SourceKit-LSP | Provides editor completion, diagnostics, definitions, and references |
| A BSP client, such as vscode-bsp | Provides target selection and build/run/test/debug controls |
| Xcode tools | Compile, link, install, launch, and execute tests |
| LLDB DAP | Handles debugger requests after BSP starts a debug session |

SourceKit-LSP and a build UI can use separate server connections. Configure both
with the intended executable and Xcode installation.
