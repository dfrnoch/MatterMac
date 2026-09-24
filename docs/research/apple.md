# Apple toolchain research for MatterMac (Xcode 27.0 27A266a, Swift 6.4, MacOSX27.0.sdk, macOS 27.0 on an M1 Pro)

The experiments below used the local toolchain described in these notes, with isolated temporary test programs. They did not modify the application sources.

**Four problems to know about first:**
1. **Swift 6.4 compiler crash.** With `NonisolatedNonsendingByDefault` on (which Xcode's `SWIFT_APPROACHABLE_CONCURRENCY=YES` turns on), an `@objc` async method that takes a bridged value type crashes the compiler. `URLRequest` is one such type, so implementing the async `willPerformHTTPRedirection` delegate method crashes the build. Fix: mark the method `@concurrent`, or use the completion-handler variant (§5).
2. **AppKit isolation mistakes are only warnings.** Calling AppKit's `@MainActor` APIs from a nonisolated context gives a warning, not an error, even in Swift 6 mode. `-warnings-as-errors` and `-Werror ActorIsolatedCall` do not turn it into an error, so the build still succeeds (§1).
3. **No universal binary by default.** `xcodebuild` without `-destination` builds arm64 only, even in Release. Pass `-destination 'generic/platform=macOS'` to get arm64 + x86_64 (§3, §4).
4. **Hardened runtime is off in ad-hoc Debug builds.** Swift Build logs "Disabling hardened runtime with ad-hoc codesigning" for Debug. Release and archive builds keep it (§3).

## 1. SwiftPM and concurrency defaults

**Tools version**
- The highest supported `swift-tools-version` is **6.4**. `swift package init` writes `// swift-tools-version: 6.4`.
- A 6.5 manifest fails with: `error: package 'tv65' is using Swift tools version 6.5.0 but the installed version is 6.4.0`.
- `swift build --help` shows the default build system is now `swiftbuild`; `native` is marked deprecated.

**Manifest API (read from `…/pm/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface`)**

| API | Available from tools version |
|---|---|
| `swiftLanguageModes: [.v6]` (package level) | 6.0 (`swiftLanguageVersions` is deprecated) |
| `.swiftLanguageMode(.v6)` (per target) | 6.0 |
| `.enableUpcomingFeature(_:)`, `.enableExperimentalFeature(_:)` | 5.8 |
| `.strictMemorySafety()` | 6.2 |
| `.treatAllWarnings(as: .error)`, `.treatWarning(_:as:)` | 6.2 |
| `.defaultIsolation(MainActor.self)` (takes `MainActor.Type?`) | 6.2 |
| `.macOS(.v14)` | yes (`.v26` and `.v27` also exist) |

- macOS versions below 12 are deprecated in tools 6.4 ("macOS 12.0 is the oldest supported version").
- A package using all of the settings above with tools 6.4 and `platforms: [.macOS(.v14)]` builds and tests cleanly. SwiftPM passes `-swift-version 6 -enable-upcoming-feature … -strict-memory-safety -warnings-as-errors -target arm64-apple-macos14.0`.
- The same settings also build with tools 6.2, which is what the Xcode demo package uses.

**Upcoming features (from `swiftc -print-supported-features`)**
- Already on in Swift 6 mode (`enabled_in: 6`): StrictConcurrency, RegionBasedIsolation, InferSendableFromCaptures, DisableOutwardActorInference, GlobalActorIsolatedTypesUsability, IsolatedDefaultValues, GlobalConcurrency, DynamicActorIsolation, NonfrozenEnumExhaustivity, ConciseMagicFile, ForwardTrailingClosures, BareSlashRegexLiterals, DeprecateApplicationMain, ImportObjcForwardDeclarations, ImplicitOpenExistentials.
- Still opt-in (planned for Swift 7): NonisolatedNonsendingByDefault, InferIsolatedConformances, ExistentialAny, MemberImportVisibility, InternalImportsByDefault, ImmutableWeakCaptures.
- `StrictMemorySafety` is a separate optional feature (`-strict-memory-safety`).
- `ApproachableConcurrency` does not appear in that list. The `swift package init` template enables it anyway, and a `hasFeature` test shows it turns on **NonisolatedNonsendingByDefault + InferIsolatedConformances**.

**Default actor isolation**
- Package target: **nonisolated** (the `SWIFT_DEFAULT_ACTOR_ISOLATION` spec default is `nonisolated`).
- New Xcode 27 app target (from the templates and `IDEFoundation.framework/…/UntitledAppProjectPrototype`):
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (passed as `-default-isolation=MainActor`)
  - `SWIFT_APPROACHABLE_CONCURRENCY = YES`
  - `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
  - **`SWIFT_VERSION = 5.0`**: new projects still start in Swift 5 mode.
- I checked that `SWIFT_APPROACHABLE_CONCURRENCY=YES` alone still emits `-enable-upcoming-feature NonisolatedNonsendingByDefault` and `InferIsolatedConformances` when `SWIFT_VERSION=6.0`.
- `SWIFT_STRICT_CONCURRENCY` only applies in Swift 4/5 mode. With Swift 6 no flag is emitted; it is harmless but does nothing.

**`nonisolated(nonsending)` and `@concurrent`** both exist. Test program `/tmp/apple-research/iso/main.swift`, called from `@MainActor`, prints whether each function runs on the main thread:

| Flags | unannotated async | `nonisolated` async | `nonisolated(nonsending)` | `@concurrent` | nonisolated class method |
|---|---|---|---|---|---|
| `-swift-version 6` | false | false | true | false | false |
| `+ NonisolatedNonsendingByDefault` | **true** | **true** | true | false | **true** |
| `+ ApproachableConcurrency` | true | true | true | false | true |
| `-default-isolation MainActor` | true (MainActor) | false | true | false | false |

So in Swift 6.4, language mode 6, a nonisolated async function hops to the global executor unless the feature is on. With the feature on, it runs on the caller's actor.

**AppKit isolation gotcha.** In Swift 6 mode, calling `NSTextView(frame:)` from a nonisolated sync context is only a *warning* (`[#ActorIsolatedCall]`). Neither `-warnings-as-errors` nor `-Werror ActorIsolatedCall` escalates it (exit 0). The same call on a Swift-declared `@MainActor` type is an error. Use `.defaultIsolation(MainActor.self)` or explicit `@MainActor` on UI targets.

**Compiler crash (reproducible).**
```swift
final class P: NSObject { @objc func work(_ r: URLRequest) async -> Int { 1 } }
// swiftc -swift-version 6 -enable-upcoming-feature NonisolatedNonsendingByDefault → signal 5,
// "While silgen emitNativeToForeignThunk"
```
- Also crashes: the URLSessionTaskDelegate async `willPerformHTTPRedirection` and `willBeginDelayedRequest` methods, including with `-default-isolation MainActor` added.
- Does not crash: `needNewBodyStreamForTask` async, the auth-challenge async method, `@objc … async -> String?`.
- Fix: mark the method `@concurrent` (or `@MainActor`), or use the completion-handler variant.

## 2. Testing
- `import Testing` works under `swift test` for macOS packages (log shows "Testing Library Version: 2084", target arm64e-apple-macos14.0). `import XCTest` works too, even alongside Swift Testing in the same target.
- A test target importing AppKit that creates an `NSTextView` passes under `swift test`.
- Run a single test with `swift test --filter 'GreeterTests/greets'` (Swift Testing) or `--filter 'GreeterXCTests/testGreets'` (XCTest). Also available: `--skip`, `swift test list`, `--enable-/--disable-swift-testing`, `--enable-/--disable-xctest`, `--parallel`, `--xunit-output`.
- Through Xcode: `xcodebuild test -workspace … -scheme MatterMacDemo -only-testing:MatterKitTests` passed. The full scheme test passed too: 2 Swift Testing package tests plus the XCUITest.
- The UI test had to pass `-AppleLanguages (en)` because this Mac's language is `cs`.

## 3. Xcode project (most important deliverable)
- Xcode 27's own prototype uses **`objectVersion = 90`**, `preferredProjectObjectVersion = 90`, `LastUpgradeCheck = 2700` and `minimizedProjectReferenceProxies = 1`. It leaves out `buildActionMask`, `runOnlyForDeploymentPostprocessing` and `defaultConfigurationIsVisible`.
- `PBXFileSystemSynchronizedRootGroup` is supported. With objectVersion 77 the same project also builds. `xcodebuild` even accepted 100, so the command line does not check the upper bound.

**What I ran** (all exit 0):
- `xcodebuild -list`
- `-project … -scheme MatterMacDemo -configuration Debug build` and `… Release build`
- the same builds through `-workspace MatterMacDemo.xcworkspace`
- `-destination 'generic/platform=macOS'` (universal x86_64 + arm64)
- `archive`
- `test`: UI test and package tests passed

**`-showBuildSettings` (app target)**

| Setting | Debug | Release |
|---|---|---|
| `SWIFT_VERSION` / `EFFECTIVE_SWIFT_VERSION` | 6.0 / 6 (`SWIFT_VERSION=6` also gives 6) | same |
| `MACOSX_DEPLOYMENT_TARGET` | 14.0 | 14.0 |
| `ARCHS` / `ONLY_ACTIVE_ARCH` | arm64 / YES | arm64 x86_64 / NO |
| `ARCHS_STANDARD` | arm64 x86_64 | arm64 x86_64 |
| `ENABLE_HARDENED_RUNTIME` | **NO** (ad-hoc Debug override) | YES |
| `ENABLE_DEBUG_DYLIB` | YES | NO |
| `ENABLE_APP_SANDBOX` | YES | YES |
| `ENABLE_USER_SELECTED_FILES` | readwrite | readwrite |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | YES | YES |
| `GENERATE_INFOPLIST_FILE` | YES | YES |
| `DEAD_CODE_STRIPPING` | YES | YES |
| `CODE_SIGN_IDENTITY` | - | - |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | MainActor | MainActor |
| `SWIFT_UPCOMING_FEATURE_*` | YES | YES |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` | YES | YES |

The Swift command line contained `-swift-version 6 -default-isolation=MainActor -warnings-as-errors`, plus `-enable-upcoming-feature` for MemberImportVisibility, ExistentialAny, InferIsolatedConformances and NonisolatedNonsendingByDefault.

**Signing and entitlements (no .entitlements file needed)**
- The sandbox build settings generate the entitlements. `codesign -d --entitlements -` shows `app-sandbox`, `files.user-selected.read-write` and `network.client`.
- Debug and Release builds also get `get-task-allow`. The archive drops it and is signed `flags=0x10002(adhoc,runtime)`.
- The Release build is `flags=(adhoc,runtime)`; the ad-hoc Debug build has runtime off.
- The Info.plist has `LSMinimumSystemVersion 14.0`; Resources contain `AppIcon.icns`, `Assets.car`, `en.lproj` and `cs.lproj/Localizable.strings` compiled from the `.xcstrings` file.

**Destinations.** Without `-destination`, `xcodebuild` warns "Using the first of multiple matching destinations" (My Mac arm64 / My Mac x86_64 / Any Mac) and builds arm64 only, even in Release.

### Files (in `/tmp/apple-research/xc/`; all verified to build)
Layout:
```
MatterMacDemo.xcworkspace/contents.xcworkspacedata
MatterMacDemo.xcodeproj/project.pbxproj
MatterMacDemo.xcodeproj/xcshareddata/xcschemes/MatterMacDemo.xcscheme
MatterMacDemo/{MatterMacDemoApp.swift, ContentView.swift, Localizable.xcstrings, Assets.xcassets/…}
MatterMacDemoUITests/MatterMacDemoUITests.swift
Packages/MatterKit/{Package.swift, Sources/MatterKit/MatterKit.swift, Tests/MatterKitTests/MatterKitTests.swift}
```

`MatterMacDemo.xcodeproj/project.pbxproj`
```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 90;
	objects = {

/* Begin PBXBuildFile section */
		000000000000000000000032 /* MatterKit in Frameworks */ = {isa = PBXBuildFile; productRef = 000000000000000000000031 /* MatterKit */; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		000000000000000000000040 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 000000000000000000000000 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 000000000000000100000000;
			remoteInfo = MatterMacDemo;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
		000000000000000000000120 /* MatterMacDemo.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MatterMacDemo.app; sourceTree = BUILT_PRODUCTS_DIR; };
		000000000000000000000121 /* MatterMacDemoUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MatterMacDemoUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		000000000000000000000010 /* MatterMacDemo */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = MatterMacDemo;
			sourceTree = "<group>";
		};
		000000000000000000000011 /* MatterMacDemoUITests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = MatterMacDemoUITests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		000000000000000130000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
				000000000000000000000032 /* MatterKit in Frameworks */,
			);
		};
		000000000000000230000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		000000000000000000000001 = {
			isa = PBXGroup;
			children = (
				000000000000000000000010 /* MatterMacDemo */,
				000000000000000000000011 /* MatterMacDemoUITests */,
				000000000000000000000020 /* Products */,
			);
			sourceTree = "<group>";
		};
		000000000000000000000020 /* Products */ = {
			isa = PBXGroup;
			children = (
				000000000000000000000120 /* MatterMacDemo.app */,
				000000000000000000000121 /* MatterMacDemoUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		000000000000000100000000 /* MatterMacDemo */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000110000000 /* Build configuration list for PBXNativeTarget "MatterMacDemo" */;
			buildPhases = (
				000000000000000120000000 /* Sources */,
				000000000000000130000000 /* Frameworks */,
				000000000000000140000000 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000010 /* MatterMacDemo */,
			);
			name = MatterMacDemo;
			packageProductDependencies = (
				000000000000000000000031 /* MatterKit */,
			);
			productName = MatterMacDemo;
			productReference = 000000000000000000000120 /* MatterMacDemo.app */;
			productType = "com.apple.product-type.application";
		};
		000000000000000200000000 /* MatterMacDemoUITests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000210000000 /* Build configuration list for PBXNativeTarget "MatterMacDemoUITests" */;
			buildPhases = (
				000000000000000220000000 /* Sources */,
				000000000000000230000000 /* Frameworks */,
				000000000000000240000000 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				000000000000000000000041 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000011 /* MatterMacDemoUITests */,
			);
			name = MatterMacDemoUITests;
			productName = MatterMacDemoUITests;
			productReference = 000000000000000000000121 /* MatterMacDemoUITests.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		000000000000000000000000 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {
					000000000000000100000000 = {
						CreatedOnToolsVersion = 27.0;
					};
					000000000000000200000000 = {
						CreatedOnToolsVersion = 27.0;
						TestTargetID = 000000000000000100000000;
					};
				};
			};
			buildConfigurationList = 000000000000000010000000 /* Build configuration list for PBXProject "MatterMacDemo" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				cs,
				Base,
			);
			mainGroup = 000000000000000000000001;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				000000000000000000000030 /* XCLocalSwiftPackageReference "Packages/MatterKit" */,
			);
			preferredProjectObjectVersion = 90;
			productRefGroup = 000000000000000000000020 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				000000000000000100000000 /* MatterMacDemo */,
				000000000000000200000000 /* MatterMacDemoUITests */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		000000000000000140000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
		000000000000000240000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		000000000000000120000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
		000000000000000220000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		000000000000000000000041 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 000000000000000100000000 /* MatterMacDemo */;
			targetProxy = 000000000000000000000040 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		000000000000000011000000 /* Debug configuration for PBXProject "MatterMacDemo" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COPY_PHASE_STRIP = NO;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = dwarf;
				DEVELOPMENT_TEAM = "";
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_STRICT_CONCURRENCY = complete;
				SWIFT_VERSION = 6.0;
			};
			name = Debug;
		};
		000000000000000012000000 /* Release configuration for PBXProject "MatterMacDemo" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COPY_PHASE_STRIP = NO;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				DEVELOPMENT_TEAM = "";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = NO;
				SDKROOT = macosx;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_STRICT_CONCURRENCY = complete;
				SWIFT_VERSION = 6.0;
			};
			name = Release;
		};
		000000000000000111000000 /* Debug configuration for PBXNativeTarget "MatterMacDemo" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;
				ENABLE_PREVIEWS = YES;
				ENABLE_USER_SELECTED_FILES = readwrite;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.social-networking";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MatterMacDemo;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;
				SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY = YES;
				SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = YES;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES;
			};
			name = Debug;
		};
		000000000000000112000000 /* Release configuration for PBXNativeTarget "MatterMacDemo" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;
				ENABLE_PREVIEWS = YES;
				ENABLE_USER_SELECTED_FILES = readwrite;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.social-networking";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MatterMacDemo;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;
				SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY = YES;
				SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = YES;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES;
			};
			name = Release;
		};
		000000000000000211000000 /* Debug configuration for PBXNativeTarget "MatterMacDemoUITests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MatterMacDemoUITests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				STRING_CATALOG_GENERATE_SYMBOLS = NO;
				SWIFT_EMIT_LOC_STRINGS = NO;
				TEST_TARGET_NAME = MatterMacDemo;
			};
			name = Debug;
		};
		000000000000000212000000 /* Release configuration for PBXNativeTarget "MatterMacDemoUITests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 0.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MatterMacDemoUITests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				STRING_CATALOG_GENERATE_SYMBOLS = NO;
				SWIFT_EMIT_LOC_STRINGS = NO;
				TEST_TARGET_NAME = MatterMacDemo;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		000000000000000010000000 /* Build configuration list for PBXProject "MatterMacDemo" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000011000000 /* Debug configuration for PBXProject "MatterMacDemo" */,
				000000000000000012000000 /* Release configuration for PBXProject "MatterMacDemo" */,
			);
			defaultConfigurationName = Release;
		};
		000000000000000110000000 /* Build configuration list for PBXNativeTarget "MatterMacDemo" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000111000000 /* Debug configuration for PBXNativeTarget "MatterMacDemo" */,
				000000000000000112000000 /* Release configuration for PBXNativeTarget "MatterMacDemo" */,
			);
			defaultConfigurationName = Release;
		};
		000000000000000210000000 /* Build configuration list for PBXNativeTarget "MatterMacDemoUITests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000211000000 /* Debug configuration for PBXNativeTarget "MatterMacDemoUITests" */,
				000000000000000212000000 /* Release configuration for PBXNativeTarget "MatterMacDemoUITests" */,
			);
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		000000000000000000000030 /* XCLocalSwiftPackageReference "Packages/MatterKit" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/MatterKit;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		000000000000000000000031 /* MatterKit */ = {
			isa = XCSwiftPackageProductDependency;
			productName = MatterKit;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = 000000000000000000000000 /* Project object */;
}
```

`MatterMacDemo.xcodeproj/xcshareddata/xcschemes/MatterMacDemo.xcscheme`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      buildArchitectures = "Automatic">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000100000000"
               BuildableName = "MatterMacDemo.app"
               BlueprintName = "MatterMacDemo"
               ReferencedContainer = "container:MatterMacDemo.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "MatterKitTests"
               BuildableName = "MatterKitTests"
               BlueprintName = "MatterKitTests"
               ReferencedContainer = "container:Packages/MatterKit">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000200000000"
               BuildableName = "MatterMacDemoUITests.xctest"
               BlueprintName = "MatterMacDemoUITests"
               ReferencedContainer = "container:MatterMacDemo.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "YES"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "MatterMacDemo.app"
            BlueprintName = "MatterMacDemo"
            ReferencedContainer = "container:MatterMacDemo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "MatterMacDemo.app"
            BlueprintName = "MatterMacDemo"
            ReferencedContainer = "container:MatterMacDemo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

`MatterMacDemo.xcworkspace/contents.xcworkspacedata`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:MatterMacDemo.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:Packages/MatterKit">
   </FileRef>
</Workspace>
```

`Packages/MatterKit/Package.swift`
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MatterKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MatterKit", targets: ["MatterKit"]),
    ],
    targets: [
        .target(
            name: "MatterKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(name: "MatterKitTests", dependencies: ["MatterKit"]),
    ],
    swiftLanguageModes: [.v6]
)
```

`Packages/MatterKit/Sources/MatterKit/MatterKit.swift`
```swift
import Foundation

public struct ServerInfo: Sendable, Equatable {
    public let host: String
    public init(host: String) { self.host = host }
    public var displayName: String { host.lowercased() }
}

func isMainThread() -> Bool { Thread.isMainThread }

/// nonisolated by default in a package target; with NonisolatedNonsendingByDefault
/// this async func runs on the caller's actor.
public func fetchNothing() async -> Bool { isMainThread() }
```

`Packages/MatterKit/Tests/MatterKitTests/MatterKitTests.swift`
```swift
import Testing
@testable import MatterKit

@Test func displayNameLowercases() {
    #expect(ServerInfo(host: "Chat.Example.COM").displayName == "chat.example.com")
}

@Test @MainActor func runsOnCallerActor() async {
    #expect(await fetchNothing())
}
```

`MatterMacDemo/MatterMacDemoApp.swift`
```swift
import AppKit
import SwiftUI
import MatterKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

@main
struct MatterMacDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(server: ServerInfo(host: "Chat.Example.com"))
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
```

`MatterMacDemo/ContentView.swift`
```swift
import AppKit
import SwiftUI
import MatterKit

// No @MainActor annotations anywhere: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor makes them implicit.
final class ComposerModel {
    var draft = ""
}

enum BuildFlags {
#if hasFeature(NonisolatedNonsendingByDefault)
    static let nonsending = true
#else
    static let nonsending = false
#endif
}

struct ContentView: View {
    let server: ServerInfo
    @State private var model = ComposerModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("welcome.title")                         // key from Localizable.xcstrings
            Text(verbatim: server.displayName)
            Text(verbatim: "nonisolated(nonsending) default: \(BuildFlags.nonsending)")
            ComposerTextView()
                .frame(height: 80)
        }
        .padding()
        .accessibilityIdentifier("root")
    }
}

struct ComposerTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.allowsUndo = true
        tv.isRichText = false
        tv.setAccessibilityIdentifier("composer")
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
```

`MatterMacDemoUITests/MatterMacDemoUITests.swift`
```swift
import XCTest

final class MatterMacDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsWelcome() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to MatterMac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["composer"].exists)
        app.terminate()
    }
}
```

`MatterMacDemo/Localizable.xcstrings`
```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "welcome.title" : {
      "extractionState" : "manual",
      "localizations" : {
        "cs" : { "stringUnit" : { "state" : "translated", "value" : "Vítejte v MatterMac" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Welcome to MatterMac" } }
      }
    }
  },
  "version" : "1.0"
}
```

`Assets.xcassets/Contents.json`
```json
{ "info" : { "author" : "xcode", "version" : 1 } }
```

`Assets.xcassets/AccentColor.colorset/Contents.json` (same as Xcode's prototype)
```json
{ "colors" : [ { "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 } }
```

`Assets.xcassets/AppIcon.appiconset/Contents.json`. The PNGs were made from one 1024px PNG with `sips -z`; actool built `AppIcon.icns` with no warnings.
```json
{"images":[
 {"filename":"icon_16x16.png","idiom":"mac","scale":"1x","size":"16x16"},
 {"filename":"icon_16x16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},
 {"filename":"icon_32x32.png","idiom":"mac","scale":"1x","size":"32x32"},
 {"filename":"icon_32x32@2x.png","idiom":"mac","scale":"2x","size":"32x32"},
 {"filename":"icon_128x128.png","idiom":"mac","scale":"1x","size":"128x128"},
 {"filename":"icon_128x128@2x.png","idiom":"mac","scale":"2x","size":"128x128"},
 {"filename":"icon_256x256.png","idiom":"mac","scale":"1x","size":"256x256"},
 {"filename":"icon_256x256@2x.png","idiom":"mac","scale":"2x","size":"256x256"},
 {"filename":"icon_512x512.png","idiom":"mac","scale":"1x","size":"512x512"},
 {"filename":"icon_512x512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}],
 "info":{"author":"xcode","version":1}}
```

## 4. x86_64 and deployment target 14.0
- The macOS entry in `SDKSettings.json` says:
  - `MinimumDeploymentTarget` 12.0
  - `RecommendedDeploymentTarget` **14.0**
  - `ValidDeploymentTargets` includes 14.0–14.6
  - `Archs` include `x86_64`, `x86_64h`, `arm64`, `arm64e`
- `ARCHS_STANDARD` is still `arm64 x86_64`.
- `swiftc -swift-version 6 -target x86_64-apple-macos14.0` produced an x86_64 binary (`minos 14.0`, `sdk 27.0`) that runs under Rosetta here.
- The archive with `-destination 'generic/platform=macOS'` is a universal binary (x86_64 + arm64).

## 5. URLSession (runtime results from `/tmp/apple-research/net/net.swift` against a local Bun server)

**`.ephemeral` defaults**
- `urlCache`: in-memory, 512000 bytes memory / 0 disk
- `httpCookieStorage` and `urlCredentialStorage`: private instances (not `.shared`)
- `httpShouldSetCookies` true; cookie accept policy 2 (`.onlyFromMainDocumentDomain`)
- `requestCachePolicy` `.useProtocolCachePolicy`; `httpMaximumConnectionsPerHost` 6; `waitsForConnectivity` false
- Timeouts 60 s (request) / 604800 s (resource); TLS minimum 1.2 (raw value 771)
- `.default` config uses `HTTPCookieStorage.shared`

**Cookies**
- `HTTPCookieStorage()` compiles, but after `setCookie` its `cookies` returned **nil**. Don't use it as an in-memory store.
- Safest setup, all settable: `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, `urlCache = nil`, `urlCredentialStorage = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`.
- With that setup a server `Set-Cookie` was not sent back. Plain `.ephemeral` did send `sess=abc` back.
- Per the header, `sharedCookieStorage(forGroupContainerIdentifier:)` returns "a cookie storage with a persistent store" (on disk).

**Redirects**
- The async delegate method is `func urlSession(_:task:willPerformHTTPRedirection:newRequest:) async -> URLRequest?`. Returning nil gives the 302 response itself.
- It must be `@concurrent` because of the compiler crash in §1.
- Per-task delegates work: `data(for:delegate:)` (macOS 12+), and `task.delegate`.
- **Authorization is stripped on every followed redirect, even same-host 307.** Custom headers such as `X-Custom` are kept.

**Other APIs**
- `bytes(for:)` / `AsyncBytes` is available from macOS 12 and `.lines` streamed as expected.
- `upload(for:fromFile:)` sent `Content-Length` (not chunked) and **streams from the file, it does not copy it**. Truncating the file mid-upload failed with "The network connection was lost."
- `uploadTask(withStreamedRequest:)` plus async `urlSession(_:needNewBodyStreamForTask:) async -> InputStream?` works: 12345 bytes sent, status 200. The `from offset` variant needs macOS 14.
- `download(for:)` returns `$TMPDIR/CFNetworkDownload_*.tmp`, and the file still existed a second later. You must move or delete it yourself.

**WebSocket (`URLSessionWebSocketTask`)**
- `maximumMessageSize` defaults to **1048576**. Exactly 1 MiB was received; 1 MiB + 1 byte failed with `NSPOSIXErrorDomain 40 "Message too long"`, the task completed and `closeCode` stayed 0.
- Changing the limit worked whether set before or after `resume`.
- Available: `send(_:) async throws`, `receive() async throws`, `sendPing(pongReceiveHandler:)` (pong ok).
- A server close gave `closeCode` 4000 with reason "bye".
- `cancel(with: .normalClosure, reason:)` left `closeCode` 1000.
- Delegate protocols are `Sendable` (`URLSessionDelegate : NSObjectProtocol, Sendable`), so delegate state needs `OSAllocatedUnfairLock`. `Mutex` requires macOS 15.

## 6. NSTextView
- **TextKit 2 by default:** `NSTextView(frame:)` and `scrollableTextView()` both have `textLayoutManager != nil` (checked on the macOS 27 runtime).
- `NSTextView(usingTextLayoutManager: false)` gives TextKit 1. Touching `.layoutManager` permanently falls back to TextKit 1.
- **Defaults:** `allowsUndo=false`, `isRichText=true`, `usesFindBar=false`, `isIncrementalSearchingEnabled=false`, continuous spell check off, grammar on, auto-correct off, quote/dash substitution off, text replacement on, link and data detection off, `smartInsertDelete` on, `isAutomaticTextCompletionEnabled` true, `inlinePredictionType .default`.
- **Availability:** `inlinePredictionType` macOS 14.0; `writingToolsBehavior` and `mathExpressionCompletionType` macOS 15.0.
- **Undo:** `undoManager` is the window's; `levelsOfUndo` defaults to 0 (unlimited). With `levelsOfUndo=3`, only 3 of 5 undo groups were undoable.
- **Key bindings** (`StandardKeyBinding.dict`, confirmed with real posted events):
  - Return and Shift-Return → `insertNewline:`; only `NSApp.currentEvent` shows the shift flag
  - Option-Return → `insertNewlineIgnoringFieldEditor:`
  - Ctrl-Return → `insertLineBreak:`
  - Cmd-Return → `noop:`
  - Esc → `cancelOperation:`; Option-Esc → `complete:`
- **Intercepting Return without breaking IME:** override `doCommand(by:)` or use the delegate's `textView(_:doCommandBy:)`, which is called from inside super's `doCommand`. Don't override `keyDown` without calling super: the input method must see the key first. `setMarkedText` makes `hasMarkedText()` true and `markedRange()` returns the range. Also guard with `!hasMarkedText()`.
- **Completion popup:** it is the private class `NSTextViewCompletionWindow`; override `insertCompletion(_:forPartialWordRange:movement:isFinal:)` to track it. I could not keep the popup open in the synthetic test, so how Return behaves while it is showing is **unverified**. A custom mention popup is safer.
- **Autosave:** NSTextView has none without NSDocument; the app must persist drafts itself.

## 7. NSTableView
- `style` (macOS 11+) options are `.automatic`, `.fullWidth`, `.inset`, `.sourceList` and `.plain`; `.plain` gives `effectiveStyle` plain.
- `usesAutomaticRowHeights` defaults to false. With `tableView(_:heightOfRow:)`, heights are only re-queried after `noteHeightOfRows(withIndexesChanged:)`; the header says `reloadData(forRowIndexes:columnIndexes:)` does not re-query heights. Verified: after the call, the row became 300 pt.
- **Keeping the scroll position on prepend (verified):**
  - Before: `anchorRow = row(at: clip.bounds.minY+1)` and `offset = clip.bounds.minY - rect(ofRow:anchorRow).minY`.
  - Then `insertRows(at:0..<n, withAnimation: [])`.
  - Then `clip.scroll(to: (0, rect(ofRow: anchorRow+n).minY + offset))` and `scrollView.reflectScrolledClipView(clip)`.
  - Without the fix the top row drifted from 250 to 276; with it the anchor was restored exactly (offset 0).
- **Cost of 1000 attributed-text cells, `-O`:**

| Approach | Time |
|---|---|
| `NSTextField(labelWithAttributedString:)` + `isSelectable` + `fittingSize` | 49 ms |
| `NSAttributedString.boundingRect` | 139 ms |
| `NSTextView` (TextKit 2) + `ensureLayout` | 481 ms |

## 8. Markdown with `AttributedString(markdown:)`
- **`.full` intents:** `header 1`, `paragraph`, `blockQuote`, `listItem n < unorderedList/orderedList` (nested), `codeBlock 'swift'`, `table` with column alignments / `tableHeaderRow` / `tableRow n` / `tableCell n`, `thematicBreak`.
- **Inline intents:** bold 2, italic 1, code 4, strikethrough 32, soft break 64. Links go in `.link`, images in `.imageURL`. Bare URLs and `www.` are auto-linked.
- **HTML is never interpreted.** Tags stay as literal text marked `inlineHTML` (256) or `blockHTML` (512). Don't auto-load `imageURL`.
- **Every link scheme is kept**, including `javascript:`, `file:`, `data:` and custom schemes. You need your own allowlist.
- `.inlineOnlyPreservingWhitespace` treats block syntax (including code fences) as plain text or inline code.
- An unterminated link does not throw, even with `.throwError`.
- **Performance:** cost scales with the number of runs, about 11 µs per run.

| Input | Time |
|---|---|
| Typical 8 KB | 10.7 ms (`.full`) / 5.8 ms (inline) |
| 64 KB of alternating `*a` | 375 ms |
| 96 KB of `**a** ` | 370 ms |
| Deep nesting / 16k brackets or backticks | ≤ 16 ms |

  Parse off the main thread and cap input length.
- `AttributedString`, `MarkdownParsingOptions` and `PresentationIntent` are `Sendable` (checked at compile time).

## 9. Image I/O
- **Sendability:** `CGImage` is `@unchecked Sendable` (macOS 10.9+), as are `CGColorSpace` and `CGImageSource.Status`. `CGImageSource` and `CGContext` are not.
- **8000×6000 JPEG with EXIF orientation 6:** `CGImageSourceCopyPropertiesAtIndex` returned width/height/orientation in 1.9 ms with +0.14 MB footprint, without decoding.
- `CreateThumbnailFromImageAlways` + `ThumbnailMaxPixelSize 1024` + `CreateThumbnailWithTransform` + `ShouldCacheImmediately` gave **768×1024** in 96 ms, +2 MB. Without the transform option it was 1024×768.
- `IfAbsent` with no max size returned the full 8000×6000 image.
- **Decompression-bomb check:** a 1.7 MB PNG claims 20000×20000, and the properties call reports that before decoding. The 512 px thumbnail took 274 ms and +4.8 MB.
- `kCGImageSourceDecodeRequest` needs macOS 14.

## 10. ASWebAuthenticationSession (from the headers)
- `init(url:callback:completionHandler:)` needs **macOS 14.4**. So does `additionalHeaderFields`.
- `Callback.customScheme(_:)` and `Callback.https(host:path:)` are also 14.4. For https, the host must be associated with the app through associated domains (webcredentials).
- The old `init(url:callbackURLScheme:completionHandler:)` is deprecated; use it on 14.0–14.3.
- `prefersEphemeralWebBrowserSession` defaults to NO (macOS 10.15+) and must be set before `start()`.
- `presentationContextProvider` is required, or the session fails with `.presentationContextNotProvided` (2). The protocol is `@MainActor`.
- Other error codes: `.canceledLogin` = 1, `.presentationContextInvalid` = 3.
- `start()` can only be called once; `canStart` is available from 10.15.4.

## 11. Window restoration
- **SwiftUI API:** `.restorationBehavior(.disabled)` is **macOS 15.0+** (`SceneRestorationBehavior`). On 14, set `window.isRestorable = false`; SwiftUI's `AppKitWindow` defaults to `isRestorable=true`. You can also set `NSQuitAlwaysKeepsWindows=false`; it is already 0 globally on this Mac.
- **Saved state test:** a sandboxed build ran in four modes (default, keep, keep + isRestorable=false, nokeep), with runs up to 12 s. No `…savedState` directory was created, either during the run or after a normal quit.
- SwiftUI *does* write `"NSWindow Frame SwiftUI.WindowGroup<…>"` into the container's preferences plist. That is frame autosave, not restoration.
- **Launch-argument gotcha:** a bare trailing argument (for example `mode=x`) is treated as a file to open, and no window is created.
- `applicationShouldTerminate` is called through `@NSApplicationDelegateAdaptor` when `NSApp.terminate` runs. Return `.terminateCancel` or `.terminateLater` to warn about an unsent draft.

## 12. Measurement
- **Signposts and logging:** `OSSignposter(subsystem:category:.pointsOfInterest)` provides `beginInterval`, `endInterval`, `emitEvent` and `withIntervalSignpost`. Send only counts or ids; `Logger` supports `privacy: .private`.
- **`task_info` phys_footprint works from Swift 6 with no unsafe flags.** Under `-strict-memory-safety` it needs `unsafe` markers; this version compiles clean with `-warnings-as-errors`:
```swift
let kr = withUnsafeMutablePointer(to: &info) {
    unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
}
```
- **Tools present:** `/usr/bin/footprint` (`-p <pid>`), `vmmap --summary`, `heap`, `leaks`, `sample`, `xctrace` (templates include Time Profiler, Allocations, Leaks, Swift Concurrency, SwiftUI, Power Profiler, Activity Monitor).
- **Idle demo app:** footprint 31 MB (peak 37 MB), confirmed by both `footprint` and `vmmap`. `top -l 4 -s 2 -pid <pid> -stats pid,cpu,mem,idlew,power` showed 0.0% CPU and 0 idle wakeups. `ps -o %cpu` gives a decayed average (0.0).
- `powermetrics` needs sudo, and a password is required on this Mac.

Everything is in `/tmp/apple-research/`; logs are in `xc-debug.log`, `xc-release.log`, `test-all.log` and `archive.log`:
- `iso/`: isolation program
- `pkg/`: SwiftPM strict-settings package
- `xc/`: Xcode demo
- `crash/`: compiler-crash reproductions
- `net/`: URLSession tests
- `tv/`: NSTextView tests
- `tbl/`: NSTableView tests
- `md/`: Markdown tests
- `img/`: Image I/O tests
- `sp/`: signposts and `task_info`
- `xc-restore/`: restoration test
