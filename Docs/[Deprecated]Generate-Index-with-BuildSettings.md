# BSP Path Rewrite Guide for `buildSettingsForIndex` (Xcode projects)

This guide explains **which keys to rewrite** and **how to rewrite paths** from `buildSettingsForIndex` (aka `-showBuildSettingsForIndex`) so that the resulting `compileArguments` work reliably with SourceKit-LSP—**without** running a real build.

---

## Why rewriting is needed

`buildSettingsForIndex` does **not** honor `-derivedDataPath`, `SYMROOT`, or `OBJROOT`. It often emits paths under:

```
$(SRCROOT)/build/Debug-iphoneos/...
```

or similar. Those do not match where your products and intermediates actually live during a normal build (e.g. under DerivedData). Your BSP should therefore **rewrite** these paths to the correct roots.

---

## Anchors (read from normal mode)

Before rewriting, fetch *trusted* anchors from **normal** `xcodebuild` (not ForIndex):

```bash
xcodebuild   -project <Proj>.xcodeproj   -target  <Target>   -configuration Debug   -sdk iphonesimulator   -showBuildSettings -json > norm.json
```

Read at least:
- `SRCROOT`
- `BUILD_DIR` (or `BUILT_PRODUCTS_DIR` if you prefer a per-target dir)
- `OBJROOT`
- `SDKROOT`
- `EFFECTIVE_PLATFORM_NAME` (e.g. `-iphonesimulator` or `-iphoneos`)

> Use these anchors when transforming ForIndex paths.

---

## Keys to rewrite

### Must (directly affect `compileArguments`)
1. `swiftASTCommandArguments` (array)
2. `clangASTCommandArguments` (array)

Handle both of the following forms:

- **Flag + next token is a path**: `-I`, `-F`, `-iquote`, `-L`, `-isysroot`, `-isystem` → rewrite the **next** token.
- **`-Xcc` payloads**:
  - `-Xcc <path>`
  - `-Xcc -I <path>`, `-Xcc -F <path>`, `-Xcc -isysroot <path>`, `-Xcc -isystem <path>`
  - `-Xcc -include <path>`, `-Xcc -fmodule-map-file=<path>`

### Strongly recommended (keeps roots consistent)
3. `swiftASTBuiltProductsDir` (string)  
4. `clangASTBuiltProductsDir` (string)

### Optional / situational
5. `outputFilePath` (string; intermediates)  
6. `clangPrefixFilePath` (PCH; only if under `$(SRCROOT)/build/...` or contains `iPhoneOS.sdk`)  
7. `assetSymbolIndexPath` (usually leave as-is)

---

## Rewrite rules

Let `CFG ∈ {Debug, Release}`, `PLAT ∈ {iphoneos, iphonesimulator}`, and `TAIL` be the remainder of the path.

### A) Product directories (frameworks, libraries, etc.)

**Match**
```
$(SRCROOT)/build/CFG-iphoneos/TAIL
$(SRCROOT)/build/Products/CFG-iphoneos/TAIL
```

**Rewrite**
```
→ $(BUILD_DIR)/TAIL
```
> `BUILD_DIR` typically already includes `CFG$(EFFECTIVE_PLATFORM_NAME)`, e.g. `.../Build/Products/Debug-iphonesimulator`.

### B) Intermediate files (`.hmap`, `.o`, `*.build` directories)

**Match**
```
$(SRCROOT)/build/Pods.build/CFG-iphoneos/<Target>.build/TAIL
$(SRCROOT)/build/<Project>.build/CFG-iphoneos/<Target>.build/TAIL
```

**Rewrite**
```
→ $(OBJROOT)/Pods.build/CFG$(EFFECTIVE_PLATFORM_NAME)/<Target>.build/TAIL
→ $(OBJROOT)/<Project>.build/CFG$(EFFECTIVE_PLATFORM_NAME)/<Target>.build/TAIL
```

### C) SDK / sysroot

**Match**: any occurrence of `iPhoneOS.sdk` (including `-isysroot` arguments)  
**Rewrite**: replace `iPhoneOS.sdk` with `basename($(SDKROOT))` (e.g. `iPhoneSimulator.sdk`).  
Optionally change the entire pair to `-isysroot $(SDKROOT)`.

### D) Platform normalization

If `$(EFFECTIVE_PLATFORM_NAME) == -iphonesimulator` and a path still contains `iphoneos` suffixes, normalize:

```
Debug-iphoneos   → Debug-iphonesimulator
Release-iphoneos → Release-iphonesimulator
```
(And vice versa if building for device.)

---

## Validation & fallbacks

- **Standardize & de-duplicate**: after rewriting, absolutize paths and remove duplicates while preserving order.
- **Missing `.hmap`**: skip the `.hmap` or expand using directories listed in `HEADER_SEARCH_PATHS`.
- **Missing `-F` directories**: fall back to `BUILT_PRODUCTS_DIR` or `PODS_CONFIGURATION_BUILD_DIR` if available.
- **Module cache**: to stabilize clang/swift module caching, consider setting `CLANG_MODULE_CACHE_PATH=/tmp/ClangModuleCache` at runtime.

---

## Example (before → after)

**Before**
```
-Xcc /workspace/Example/build/Debug-iphoneos/ExampleFramework
-F   /workspace/Example/build/Debug-iphoneos/ExampleFramework
```

**After**
```
-Xcc $(BUILD_DIR)/ExampleFramework
-F   $(BUILD_DIR)/ExampleFramework
```
(Where `BUILD_DIR = .../Build/Products/Debug-iphonesimulator` from `norm.json`.)

---

## Swift reference implementation (minimal)

```swift
struct BuildSettings {
    let SRCROOT: String
    let BUILD_DIR: String      // or BUILT_PRODUCTS_DIR
    let OBJROOT: String
    let SDKROOT: String
    let EFFECTIVE_PLATFORM_NAME: String? // "-iphonesimulator" / "-iphoneos"
}

private func platformIsSim(_ S: BuildSettings) -> Bool {
    S.EFFECTIVE_PLATFORM_NAME?.contains("iphonesimulator") == true ||
    S.SDKROOT.lowercased().contains("iphonesimulator")
}

func rewriteCompileArguments(_ args: [String], anchors S: BuildSettings) -> [String] {
    var out: [String] = []
    var i = 0
    let expectsPath: Set<String> = ["-I","-F","-iquote","-L","-isysroot","-isystem"]

    while i < args.count {
        let tok = args[i]
        switch tok {
        case "-Xcc":
            out.append(tok)
            guard i + 1 < args.count else { break }
            let next = args[i+1]
            if expectsPath.contains(next), i + 2 < args.count {
                out.append(next)
                out.append(rewriteOne(args[i+2], S))
                i += 3; continue
            } else {
                out.append(rewriteOne(next, S))
                i += 2; continue
            }
        case _ where expectsPath.contains(tok):
            out.append(tok)
            if i + 1 < args.count { out.append(rewriteOne(args[i+1], S)) }
            i += 2; continue
        default:
            out.append(rewriteSDK(tok, S))
            i += 1
        }
    }

    // absolutize + dedup (preserve order)
    var seen = Set<String>(); var dedup: [String] = []
    for s in out {
        let abs = URL(fileURLWithPath: s).standardizedFileURL.path
        if !seen.contains(abs) { seen.insert(abs); dedup.append(abs) }
    }
    return dedup
}

private func rewriteOne(_ p: String, _ S: BuildSettings) -> String {
    var path = rewriteSDK(p, S)

    // A) Products: $(SRCROOT)/build/*-iphoneos/TAIL  →  $(BUILD_DIR)/TAIL
    if path.hasPrefix(S.SRCROOT + "/build/") {
        for needle in ["/build/Debug-iphoneos/", "/build/Release-iphoneos/",
                       "/build/Products/Debug-iphoneos/", "/build/Products/Release-iphoneos/"] {
            if let r = path.range(of: needle) {
                let tail = String(path[r.upperBound...])
                return URL(fileURLWithPath: S.BUILD_DIR).appendingPathComponent(tail).path
            }
        }
    }

    // B) Intermediates: map Pods.build / <Project>.build to OBJROOT (if you need it)
    if platformIsSim(S) {
        path = path.replacingOccurrences(of: "Debug-iphoneos", with: "Debug-iphonesimulator")
                   .replacingOccurrences(of: "Release-iphoneos", with: "Release-iphonesimulator")
    }
    return path
}

private func rewriteSDK(_ s: String, _ S: BuildSettings) -> String {
    let sdkName = URL(fileURLWithPath: S.SDKROOT).lastPathComponent
    if s.contains("iPhoneOS.sdk") { return s.replacingOccurrences(of: "iPhoneOS.sdk", with: sdkName) }
    return s
}
```

---

## Checklist

- [ ] Read anchors from **normal** `-showBuildSettings -json` (not ForIndex).  
- [ ] Rewrite `swiftASTCommandArguments` and `clangASTCommandArguments` (flags + `-Xcc`).  
- [ ] Normalize platform suffixes (`iphoneos` ↔︎ `iphonesimulator`).  
- [ ] Rewrite `swiftASTBuiltProductsDir` / `clangASTBuiltProductsDir`.  
- [ ] Validate paths, apply fallbacks, absolutize & de-duplicate.  
- [ ] Optionally set `CLANG_MODULE_CACHE_PATH` for stability.

---

If you share a small snippet of your **normal** `norm.json`, I can in-line the exact anchor values and produce a ready-to-run `RewriteConfig` for your project.